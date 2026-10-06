#!/usr/bin/env bats
# bats file_tags=github-mcp,write-tools,review
bats_require_minimum_version 1.11.0

load 'test_helper/common_setup'

setup() {
    log() { :; }
    GH_DEFAULT_REPO="shopware/shopware"
    GH_TOOLING_CONFIG_FILE=""
    source "${GH_LIB_DIR}/common.sh"
    source "${GH_LIB_DIR}/review_write.sh"

    GH_ARGS_FILE="${BATS_TEST_TMPDIR}/gh_args"
    GH_STDIN_FILE="${BATS_TEST_TMPDIR}/gh_stdin"
    : > "${GH_ARGS_FILE}"
    : > "${GH_STDIN_FILE}"

    # gh stub: appends each invocation's args on a new line, captures stdin for
    # --input calls, and dispatches a canned head.sha for the commit_id fetch.
    gh() {
        printf '%s\n' "$*" >> "${GH_ARGS_FILE}"
        # One file per call, one NUL-terminated record per argument, so a test
        # can tell one argument from several that join to the same text.
        local call_n
        call_n=$(find "${BATS_TEST_TMPDIR}" -maxdepth 1 -name 'gh_argv.*' | wc -l | tr -d ' ')
        printf '%s\0' "$@" > "${BATS_TEST_TMPDIR}/gh_argv.$((call_n + 1))"
        if [[ "$*" == *"--input"* ]]; then
            cat > "${GH_STDIN_FILE}"
        fi
        if [[ "$*" == *"head.sha"* ]]; then
            printf '%s\n' "${GH_STUB_HEAD_SHA:-0123456789abcdef0123456789abcdef01234567}"
            return 0
        fi
        # comment_edit's calls, told apart by what the argv names. Each kind has
        # its own stdout, stderr, and exit code: GH_STUB_<KIND>_OUTPUT/_STDERR/_EXIT.
        local kind="" get_re='^api repos/[^ ]+/comments/[0-9]+$'
        if [[ "$*" == *"reviews(states: [PENDING]"* ]]; then
            kind=LOOKUP
        elif [[ "$*" == *"updatePullRequestReviewComment"* ]]; then
            kind=MUTATION
        elif [[ "$*" == *" -X PATCH "* || "$*" == *" -X PUT "* ]]; then
            kind=WRITE
        elif [[ "$*" =~ ${get_re} ]]; then
            kind=GET
        fi
        if [[ -n "${kind}" ]]; then
            local out_var="GH_STUB_${kind}_OUTPUT" err_var="GH_STUB_${kind}_STDERR" exit_var="GH_STUB_${kind}_EXIT"
            [[ -n "${!err_var:-}" ]] && printf '%s\n' "${!err_var}" >&2
            if [[ "${kind}" == WRITE && -n "${GH_STUB_APPLY_JQ:-}" ]]; then
                # Behave like real gh: run the --jq filter over the canned response.
                local arg filter="" prev=""
                for arg in "$@"; do
                    [[ "${prev}" == "--jq" ]] && filter="${arg}"
                    prev="${arg}"
                done
                printf '%s' "${!out_var}" | jq -r "${filter}"
                return $?
            fi
            [[ -n "${!out_var:-}" ]] && printf '%s\n' "${!out_var}"
            return "${!exit_var:-0}"
        fi
        gh_stub_respond
    }
    reset_gh_stub
    local kind
    for kind in GET WRITE LOOKUP MUTATION; do
        printf -v "GH_STUB_${kind}_OUTPUT" '%s' ""
        printf -v "GH_STUB_${kind}_STDERR" '%s' ""
        printf -v "GH_STUB_${kind}_EXIT" '%s' 0
    done
    GH_STUB_HEAD_SHA="0123456789abcdef0123456789abcdef01234567"
}

assert_gh_args_contain() {
    local expected="$1"
    [[ -f "${GH_ARGS_FILE}" ]] || fail "gh was not called"
    grep -qF -- "$expected" "${GH_ARGS_FILE}" || fail "Expected gh args to contain '$expected', got: $(cat "${GH_ARGS_FILE}")"
}

assert_gh_stdin_contain() {
    local expected="$1"
    [[ -f "${GH_STDIN_FILE}" ]] || fail "gh stdin was not captured"
    grep -qF -- "$expected" "${GH_STDIN_FILE}" || fail "Expected gh stdin to contain '$expected', got: $(cat "${GH_STDIN_FILE}")"
}

# ============================================================================
# pr_review_submit — simple path (no inline comments → gh pr review)
# ============================================================================

@test "pr_review_submit requires number" {
    run tool_pr_review_submit '{"event": "approve"}'
    assert_failure
    assert_output --partial "number is required"
}

@test "pr_review_submit rejects invalid event" {
    run tool_pr_review_submit '{"number": 100, "event": "invalid"}'
    assert_failure
    assert_output --partial "event must be one of"
}

@test "pr_review_submit request_changes requires body" {
    run tool_pr_review_submit '{"number": 100, "event": "request_changes"}'
    assert_failure
    assert_output --partial "body is required"
}

@test "pr_review_submit approve (no comments) uses gh pr review --approve" {
    run tool_pr_review_submit '{"number": 100, "event": "approve"}'
    assert_success
    assert_gh_args_contain "pr review 100"
    assert_gh_args_contain "--approve"
}

@test "pr_review_submit request_changes (no comments) uses --request-changes with body" {
    run tool_pr_review_submit '{"number": 100, "event": "request_changes", "body": "Please fix the bug."}'
    assert_success
    assert_gh_args_contain "pr review 100"
    assert_gh_args_contain "--request-changes"
    assert_gh_args_contain "Please fix the bug."
}

@test "pr_review_submit comment is the default event" {
    run tool_pr_review_submit '{"number": 100, "body": "Looks good overall."}'
    assert_success
    assert_gh_args_contain "pr review 100"
    assert_gh_args_contain "--comment"
}

# ============================================================================
# pr_review_submit — batched path (with inline comments → /pulls/N/reviews)
# ============================================================================

@test "pr_review_submit with comments posts to reviews endpoint via stdin" {
    GH_STUB_OUTPUT='{"id": 99}'
    run tool_pr_review_submit '{
        "number": 100,
        "event": "comment",
        "body": "Overall LGTM, a few notes.",
        "comments": [
            {"path": "src/Foo.php", "line": 42, "body": "nit: rename"},
            {"path": "src/Bar.php", "line": 10, "body": "suggestion here", "side": "RIGHT"}
        ]
    }'
    assert_success
    assert_gh_args_contain "api repos/shopware/shopware/pulls/100/reviews"
    assert_gh_args_contain "-X POST"
    assert_gh_args_contain "--input -"
    assert_gh_stdin_contain '"event": "COMMENT"'
    assert_gh_stdin_contain '"src/Foo.php"'
    assert_gh_stdin_contain '"src/Bar.php"'
    assert_gh_stdin_contain '"line": 42'
}

@test "pr_review_submit with suppress_errors returns no error text when the head SHA lookup fails" {
    gh() {
        printf '%s\n' "gh: Not Found (HTTP 404)" >&2
        return 1
    }
    run tool_pr_review_submit '{
        "number": 100,
        "comments": [{"path": "x.php", "line": 1, "body": "n"}],
        "suppress_errors": true
    }'
    assert_failure
    assert_output ""
}

@test "pr_review_submit with comments auto-fetches commit_id from PR head" {
    GH_STUB_HEAD_SHA="feedfacefeedfacefeedfacefeedfacefeedface"
    GH_STUB_OUTPUT='{"id": 99}'
    run tool_pr_review_submit '{
        "number": 100,
        "comments": [{"path": "x.php", "line": 1, "body": "n"}]
    }'
    assert_success
    assert_gh_args_contain "api repos/shopware/shopware/pulls/100 --jq .head.sha"
    assert_gh_stdin_contain '"commit_id": "feedfacefeedfacefeedfacefeedfacefeedface"'
}

@test "pr_review_submit with explicit commit_id skips auto-fetch" {
    GH_STUB_OUTPUT='{"id": 99}'
    run tool_pr_review_submit '{
        "number": 100,
        "commit_id": "abc1234abc1234abc1234abc1234abc1234abcd",
        "comments": [{"path": "x.php", "line": 1, "body": "n"}]
    }'
    assert_success
    run grep -c "head.sha" "${GH_ARGS_FILE}"
    assert_output "0"
}

@test "pr_review_submit uppercases event for REST API body" {
    GH_STUB_OUTPUT='{"id": 99}'
    run tool_pr_review_submit '{
        "number": 100,
        "event": "request_changes",
        "body": "Needs work",
        "comments": [{"path": "x.php", "line": 1, "body": "n"}]
    }'
    assert_success
    assert_gh_stdin_contain '"event": "REQUEST_CHANGES"'
}

@test "pr_review_submit omits empty top-level body from REST request" {
    GH_STUB_OUTPUT='{"id": 99}'
    run tool_pr_review_submit '{
        "number": 100,
        "comments": [{"path": "x.php", "line": 1, "body": "n"}]
    }'
    assert_success
    run jq -e 'has("body") | not' "${GH_STDIN_FILE}"
    assert_success
}

# Shared helper for the "comments[] item must have path/line/body" guard.
_assert_rejects_incomplete_comment() {
    local payload="$1"
    run tool_pr_review_submit "${payload}"
    assert_failure
    assert_output --partial "each item in comments requires path, line, and body"
}

@test "pr_review_submit rejects comment missing path" {
    _assert_rejects_incomplete_comment '{"number": 100, "comments": [{"line": 1, "body": "n"}]}'
}

@test "pr_review_submit rejects comment missing line" {
    _assert_rejects_incomplete_comment '{"number": 100, "comments": [{"path": "x.php", "body": "n"}]}'
}

@test "pr_review_submit rejects comment missing body" {
    _assert_rejects_incomplete_comment '{"number": 100, "comments": [{"path": "x.php", "line": 1}]}'
}

# ============================================================================
# pr_comment
# ============================================================================

@test "pr_comment requires number" {
    run tool_pr_comment '{"body": "hello"}'
    assert_failure
    assert_output --partial "number is required"
}

@test "pr_comment requires body" {
    run tool_pr_comment '{"number": 100}'
    assert_failure
    assert_output --partial "body is required"
}

@test "pr_comment posts conversation comment" {
    GH_STUB_OUTPUT="https://github.com/shopware/shopware/pull/100#issuecomment-999"
    run tool_pr_comment '{"number": 100, "body": "Great work!"}'
    assert_success
    assert_gh_args_contain "pr comment 100"
    assert_gh_args_contain "Great work!"
}

# ============================================================================
# pr_review_reply
# ============================================================================

@test "pr_review_reply requires number" {
    run tool_pr_review_reply '{"comment_id": 5, "body": "done"}'
    assert_failure
    assert_output --partial "number is required"
}

@test "pr_review_reply requires comment_id" {
    run tool_pr_review_reply '{"number": 100, "body": "done"}'
    assert_failure
    assert_output --partial "comment_id is required"
}

@test "pr_review_reply requires body" {
    run tool_pr_review_reply '{"number": 100, "comment_id": 5}'
    assert_failure
    assert_output --partial "body is required"
}

@test "pr_review_reply posts to replies endpoint" {
    GH_STUB_OUTPUT='{"id": 1001}'
    run tool_pr_review_reply '{"number": 100, "comment_id": 5, "body": "Addressed, thanks!"}'
    assert_success
    assert_gh_args_contain "api repos/shopware/shopware/pulls/100/comments/5/replies"
    assert_gh_args_contain "-X POST"
    assert_gh_args_contain "-f body=Addressed, thanks!"
}


# ============================================================================
# comment_edit
# ============================================================================

NOT_FOUND_STDERR="gh: Not Found (HTTP 404)"
SERVER_ERROR_STDERR="gh: Internal Server Error (HTTP 500)"
WARNING_STDERR="warning: a new gh release is available"

PENDING_NONE='{"data":{"repository":{"pullRequest":{"reviews":{"pageInfo":{"hasNextPage":false},"nodes":[]}}}}}'
PENDING_MATCH='{"data":{"repository":{"pullRequest":{"reviews":{"pageInfo":{"hasNextPage":false},"nodes":[{"viewerDidAuthor":true,"comments":{"nodes":[{"id":"PRRC_other","fullDatabaseId":"4000"},{"id":"PRRC_node5551","fullDatabaseId":"5551"}],"pageInfo":{"hasNextPage":false}}}]}}}}}'
PENDING_BIG='{"data":{"repository":{"pullRequest":{"reviews":{"pageInfo":{"hasNextPage":false},"nodes":[{"viewerDidAuthor":true,"comments":{"nodes":[{"id":"PRRC_near","fullDatabaseId":"4195291200"},{"id":"PRRC_big","fullDatabaseId":"4195291201"}],"pageInfo":{"hasNextPage":false}}}]}}}}}'
PENDING_FULL_PAGE='{"data":{"repository":{"pullRequest":{"reviews":{"pageInfo":{"hasNextPage":false},"nodes":[{"viewerDidAuthor":true,"comments":{"nodes":[{"id":"PRRC_a","fullDatabaseId":"1"}],"pageInfo":{"hasNextPage":true}}}]}}}}}'
MUTATION_OK='{"data":{"updatePullRequestReviewComment":{"pullRequestReviewComment":{"url":"https://github.com/shopware/shopware/pull/100#discussion_r5551"}}}}'

# The GET answer for a comment that belongs to issue or PR N.
stub_get_issue() {
    GH_STUB_GET_OUTPUT=$(jq -cn --arg u "https://api.github.com/repos/shopware/shopware/issues/$1" '{id: 1, issue_url: $u}')
}

stub_get_pull() {
    GH_STUB_GET_OUTPUT=$(jq -cn --arg u "https://api.github.com/repos/shopware/shopware/pulls/$1" '{id: 1, pull_request_url: $u}')
}

# gh must not have run: the rejection happens before any API call.
assert_gh_not_called() {
    [[ ! -s "${GH_ARGS_FILE}" ]] || fail "Expected no gh call, got: $(cat "${GH_ARGS_FILE}")"
}

# The one gh invocation, compared whole: endpoint, method, body field, and jq filter.
assert_gh_args_equal() {
    local expected="$1" actual
    actual=$(cat "${GH_ARGS_FILE}")
    [[ "${actual}" == "${expected}" ]] || fail "Expected gh args '${expected}', got: '${actual}'"
}

# The last gh invocation, compared whole.
assert_gh_last_args_equal() {
    local expected="$1" actual
    actual=$(tail -n 1 "${GH_ARGS_FILE}")
    [[ "${actual}" == "${expected}" ]] || fail "Expected last gh args '${expected}', got: '${actual}'"
}

# The Nth gh invocation, compared whole.
assert_gh_call_equal() {
    local n="$1" expected="$2" actual
    actual=$(sed -n "${n}p" "${GH_ARGS_FILE}")
    [[ "${actual}" == "${expected}" ]] || fail "Expected gh call ${n} to be '${expected}', got: '${actual}'"
}

assert_gh_last_args_contain_all() {
    local last needle
    last=$(tail -n 1 "${GH_ARGS_FILE}")
    for needle in "$@"; do
        [[ "${last}" == *"${needle}"* ]] || fail "Expected last gh call to contain '${needle}', got: ${last}"
    done
}

# The Nth gh invocation contains every given text.
assert_gh_call_contains_all() {
    local n="$1" call needle
    shift
    call=$(sed -n "${n}p" "${GH_ARGS_FILE}")
    for needle in "$@"; do
        [[ "${call}" == *"${needle}"* ]] || fail "Expected gh call ${n} to contain '${needle}', got: ${call}"
    done
}

# Exactly N gh calls ran.
assert_gh_call_count() {
    local expected="$1" actual
    actual=$(wc -l < "${GH_ARGS_FILE}" | tr -d ' ')
    [[ "${actual}" -eq "${expected}" ]] || fail "Expected ${expected} gh call(s), got ${actual}: $(cat "${GH_ARGS_FILE}")"
}

# No PATCH or PUT was sent.
assert_no_rest_write() {
    ! grep -q -- " -X " "${GH_ARGS_FILE}" || fail "Expected no REST write, got: $(cat "${GH_ARGS_FILE}")"
}

assert_no_graphql_call() {
    ! grep -q -- "graphql" "${GH_ARGS_FILE}" || fail "Expected no GraphQL call, got: $(cat "${GH_ARGS_FILE}")"
}

# A failed call reports through an error message that starts with "Error:".
assert_error_output() {
    assert_output --regexp '^Error:'
}

# ---- issue and PR conversation comments ------------------------------------

@test "comment_edit reads an issue comment, then patches it when it belongs to the issue in the URL" {
    stub_get_issue 7
    GH_STUB_WRITE_OUTPUT="https://github.com/shopware/shopware/issues/7#issuecomment-9001"
    run tool_comment_edit '{"url": "shopware/shopware/issues/7#issuecomment-9001", "body": "New text"}'
    assert_success
    assert_output "https://github.com/shopware/shopware/issues/7#issuecomment-9001"
    assert_gh_call_count 2
    assert_gh_call_equal 1 "api repos/shopware/shopware/issues/comments/9001"
    assert_gh_call_equal 2 "api repos/shopware/shopware/issues/comments/9001 -X PATCH -f body=New text --jq .html_url // empty"
}

@test "comment_edit patches a PR conversation comment through the issues comments endpoint" {
    stub_get_issue 100
    GH_STUB_WRITE_OUTPUT="https://example/c"
    run tool_comment_edit '{"url": "https://github.com/shopware/shopware/pull/100#issuecomment-9002", "body": "New text"}'
    assert_success
    assert_gh_call_equal 1 "api repos/shopware/shopware/issues/comments/9002"
    assert_gh_call_equal 2 "api repos/shopware/shopware/issues/comments/9002 -X PATCH -f body=New text --jq .html_url // empty"
}

@test "comment_edit refuses to edit a conversation comment that belongs to another issue or PR" {
    stub_get_issue 8
    GH_STUB_WRITE_OUTPUT="https://example/c"
    run tool_comment_edit '{"url": "shopware/shopware/issues/7#issuecomment-9001", "body": "x"}'
    assert_failure
    assert_error_output
    assert_output --partial "#8"
    assert_output --partial "#7"
    assert_gh_call_count 1
    assert_no_rest_write
}

@test "comment_edit does not treat an issue number that merely ends in the URL's number as a match" {
    stub_get_issue 17
    run tool_comment_edit '{"url": "shopware/shopware/issues/7#issuecomment-9001", "body": "x"}'
    assert_failure
    assert_error_output
    assert_no_rest_write
}

@test "comment_edit refuses an issue comment whose issue_url ends in a trailing slash, with no write" {
    GH_STUB_GET_OUTPUT='{"id":1,"issue_url":"https://api.github.com/repos/shopware/shopware/issues/7/"}'
    GH_STUB_WRITE_OUTPUT="https://example/c"
    run tool_comment_edit '{"url": "shopware/shopware/issues/7#issuecomment-9001", "body": "x"}'
    assert_failure
    assert_error_output
    assert_gh_call_count 1
    assert_no_rest_write
}

@test "comment_edit refuses an inline comment whose pull_request_url ends in a trailing slash, with no write" {
    GH_STUB_GET_OUTPUT='{"id":1,"pull_request_url":"https://api.github.com/repos/shopware/shopware/pulls/100/"}'
    GH_STUB_WRITE_OUTPUT="https://example/c"
    run tool_comment_edit '{"url": "https://github.com/shopware/shopware/pull/100#discussion_r5551", "body": "x"}'
    assert_failure
    assert_error_output
    assert_gh_call_count 1
    assert_no_rest_write
}

@test "comment_edit fails with gh's message when the conversation comment does not exist, and does not patch" {
    GH_STUB_GET_EXIT=1
    GH_STUB_GET_STDERR="${NOT_FOUND_STDERR}"
    run tool_comment_edit '{"url": "shopware/shopware/issues/7#issuecomment-9001", "body": "x"}'
    assert_failure
    assert_error_output
    assert_output --partial "Not Found (HTTP 404)"
    assert_gh_call_count 1
    assert_no_rest_write
    assert_no_graphql_call
}

@test "comment_edit fails when the read of a conversation comment names no issue, and does not patch" {
    GH_STUB_GET_OUTPUT='{"id":9001}'
    run tool_comment_edit '{"url": "shopware/shopware/issues/7#issuecomment-9001", "body": "x"}'
    assert_failure
    assert_error_output
    assert_gh_call_count 1
    assert_no_rest_write
}

# ---- inline review comments: submitted ---------------------------------------

@test "comment_edit patches an inline review comment from a discussion_r anchor with no GraphQL call" {
    stub_get_pull 100
    GH_STUB_WRITE_OUTPUT="https://example/c"
    run tool_comment_edit '{"url": "https://github.com/shopware/shopware/pull/100#discussion_r5551", "body": "New text"}'
    assert_success
    assert_output "https://example/c"
    assert_gh_call_count 2
    assert_gh_call_equal 1 "api repos/shopware/shopware/pulls/comments/5551"
    assert_gh_call_equal 2 "api repos/shopware/shopware/pulls/comments/5551 -X PATCH -f body=New text --jq .html_url // empty"
    assert_no_graphql_call
}

@test "comment_edit patches an inline review comment from an r anchor on /files" {
    stub_get_pull 100
    GH_STUB_WRITE_OUTPUT="https://example/c"
    run tool_comment_edit '{"url": "shopware/shopware/pull/100/files#r5552", "body": "New text"}'
    assert_success
    assert_gh_last_args_equal "api repos/shopware/shopware/pulls/comments/5552 -X PATCH -f body=New text --jq .html_url // empty"
    assert_no_graphql_call
}

@test "comment_edit patches an inline review comment from an r anchor on /changes" {
    stub_get_pull 100
    GH_STUB_WRITE_OUTPUT="https://example/c"
    run tool_comment_edit '{"url": "shopware/shopware/pull/100/changes#r5553", "body": "New text"}'
    assert_success
    assert_gh_last_args_equal "api repos/shopware/shopware/pulls/comments/5553 -X PATCH -f body=New text --jq .html_url // empty"
    assert_no_graphql_call
}

@test "comment_edit refuses to edit an inline comment that belongs to another PR, with no write and no lookup" {
    stub_get_pull 101
    GH_STUB_WRITE_OUTPUT="https://example/c"
    run tool_comment_edit '{"url": "https://github.com/shopware/shopware/pull/100#discussion_r5551", "body": "x"}'
    assert_failure
    assert_error_output
    assert_output --partial "#101"
    assert_output --partial "#100"
    assert_gh_call_count 1
    assert_no_rest_write
    assert_no_graphql_call
}

@test "comment_edit does not fall back to the pending-review lookup when the PATCH of a submitted comment fails" {
    stub_get_pull 100
    GH_STUB_WRITE_EXIT=1
    GH_STUB_WRITE_STDERR="${NOT_FOUND_STDERR}"
    run tool_comment_edit '{"url": "https://github.com/shopware/shopware/pull/100#discussion_r5551", "body": "x"}'
    assert_failure
    assert_error_output
    assert_output --partial "PATCH repos/shopware/shopware/pulls/comments/5551 failed"
    assert_gh_call_count 2
    assert_no_graphql_call
}

@test "comment_edit fails without a lookup or write when reading the inline comment fails with a server error" {
    GH_STUB_GET_EXIT=1
    GH_STUB_GET_STDERR="${SERVER_ERROR_STDERR}"
    run tool_comment_edit '{"url": "https://github.com/shopware/shopware/pull/100#discussion_r5551", "body": "x"}'
    assert_failure
    assert_error_output
    assert_output --partial "Internal Server Error (HTTP 500)"
    assert_gh_call_count 1
    assert_no_rest_write
    assert_no_graphql_call
}

# ---- inline review comments: pending review ---------------------------------

@test "comment_edit finds a comment in the pending review after a 404 and edits it with the mutation" {
    GH_STUB_GET_EXIT=1
    GH_STUB_GET_STDERR="${NOT_FOUND_STDERR}"
    GH_STUB_LOOKUP_OUTPUT="${PENDING_MATCH}"
    GH_STUB_MUTATION_OUTPUT="${MUTATION_OK}"
    run tool_comment_edit '{"url": "https://github.com/shopware/shopware/pull/100#discussion_r5551", "body": "New text"}'
    assert_success
    assert_output "https://github.com/shopware/shopware/pull/100#discussion_r5551"
    assert_gh_call_count 3
    assert_gh_call_equal 1 "api repos/shopware/shopware/pulls/comments/5551"
    assert_gh_call_contains_all 2 "-f owner=shopware -f name=shopware -F number=100"
    assert_gh_last_args_contain_all "updatePullRequestReviewComment" "-f id=PRRC_node5551" "-f body=New text"
    assert_no_rest_write
}

@test "comment_edit matches a pending-review comment on a database id above 32 bits, given as a string" {
    GH_STUB_GET_EXIT=1
    GH_STUB_GET_STDERR="${NOT_FOUND_STDERR}"
    GH_STUB_LOOKUP_OUTPUT="${PENDING_BIG}"
    GH_STUB_MUTATION_OUTPUT="${MUTATION_OK}"
    run tool_comment_edit '{"url": "shopware/shopware/pull/100/files#r4195291201", "body": "x"}'
    assert_success
    assert_gh_call_count 3
    assert_gh_last_args_contain_all "-f id=PRRC_big"
    assert_no_rest_write
}

@test "comment_edit asks GitHub for fullDatabaseId, the field that holds an id above 32 bits" {
    GH_STUB_GET_EXIT=1
    GH_STUB_GET_STDERR="${NOT_FOUND_STDERR}"
    GH_STUB_LOOKUP_OUTPUT="${PENDING_NONE}"
    run tool_comment_edit '{"url": "https://github.com/shopware/shopware/pull/100#discussion_r5551", "body": "x"}'
    assert_failure
    assert_gh_call_contains_all 2 "nodes { id fullDatabaseId }"
}

@test "comment_edit fails when the 404 comment is not in the pending review, with no mutation or write" {
    GH_STUB_GET_EXIT=1
    GH_STUB_GET_STDERR="${NOT_FOUND_STDERR}"
    GH_STUB_LOOKUP_OUTPUT="${PENDING_MATCH}"
    run tool_comment_edit '{"url": "https://github.com/shopware/shopware/pull/100#discussion_r9999", "body": "x"}'
    assert_failure
    assert_error_output
    assert_output --partial "not a submitted review comment"
    assert_output --partial "pending review on PR 100"
    assert_gh_call_count 2
    assert_no_rest_write
}

@test "comment_edit fails when the 404 comment is not found and the caller has no pending review" {
    GH_STUB_GET_EXIT=1
    GH_STUB_GET_STDERR="${NOT_FOUND_STDERR}"
    GH_STUB_LOOKUP_OUTPUT="${PENDING_NONE}"
    run tool_comment_edit '{"url": "https://github.com/shopware/shopware/pull/100#discussion_r5551", "body": "x"}'
    assert_failure
    assert_error_output
    assert_gh_call_count 2
    assert_no_rest_write
}

@test "comment_edit fails when the 404 comment is not on the first page of a large pending review" {
    GH_STUB_GET_EXIT=1
    GH_STUB_GET_STDERR="${NOT_FOUND_STDERR}"
    GH_STUB_LOOKUP_OUTPUT="${PENDING_FULL_PAGE}"
    run tool_comment_edit '{"url": "https://github.com/shopware/shopware/pull/100#discussion_r5551", "body": "x"}'
    assert_failure
    assert_error_output
    assert_output --partial "more than 100 comments"
    assert_gh_call_count 2
    assert_no_rest_write
}

@test "comment_edit edits a matching pending-review comment even when the review has further pages" {
    GH_STUB_GET_EXIT=1
    GH_STUB_GET_STDERR="${NOT_FOUND_STDERR}"
    GH_STUB_LOOKUP_OUTPUT='{"data":{"repository":{"pullRequest":{"reviews":{"pageInfo":{"hasNextPage":false},"nodes":[{"viewerDidAuthor":true,"comments":{"nodes":[{"id":"PRRC_node5551","fullDatabaseId":"5551"}],"pageInfo":{"hasNextPage":true}}}]}}}}}'
    GH_STUB_MUTATION_OUTPUT="${MUTATION_OK}"
    run tool_comment_edit '{"url": "https://github.com/shopware/shopware/pull/100#discussion_r5551", "body": "x"}'
    assert_success
    assert_gh_call_count 3
}

@test "comment_edit ignores a match in another author's pending review when the caller's own review lacks it" {
    GH_STUB_GET_EXIT=1
    GH_STUB_GET_STDERR="${NOT_FOUND_STDERR}"
    GH_STUB_LOOKUP_OUTPUT='{"data":{"repository":{"pullRequest":{"reviews":{"pageInfo":{"hasNextPage":false},"nodes":[{"viewerDidAuthor":false,"comments":{"nodes":[{"id":"PRRC_theirs","fullDatabaseId":"5551"}],"pageInfo":{"hasNextPage":false}}},{"viewerDidAuthor":true,"comments":{"nodes":[{"id":"PRRC_mine","fullDatabaseId":"4000"}],"pageInfo":{"hasNextPage":false}}}]}}}}}'
    run tool_comment_edit '{"url": "https://github.com/shopware/shopware/pull/100#discussion_r5551", "body": "x"}'
    assert_failure
    assert_error_output
    assert_output --partial "not in your pending review"
    assert_gh_call_count 2
    assert_no_rest_write
}

@test "comment_edit edits with the node id from the caller's review when it is not the first pending review" {
    GH_STUB_GET_EXIT=1
    GH_STUB_GET_STDERR="${NOT_FOUND_STDERR}"
    GH_STUB_LOOKUP_OUTPUT='{"data":{"repository":{"pullRequest":{"reviews":{"pageInfo":{"hasNextPage":false},"nodes":[{"viewerDidAuthor":false,"comments":{"nodes":[{"id":"PRRC_theirs","fullDatabaseId":"4000"}],"pageInfo":{"hasNextPage":false}}},{"viewerDidAuthor":true,"comments":{"nodes":[{"id":"PRRC_mine","fullDatabaseId":"5551"}],"pageInfo":{"hasNextPage":false}}}]}}}}}'
    GH_STUB_MUTATION_OUTPUT="${MUTATION_OK}"
    run tool_comment_edit '{"url": "https://github.com/shopware/shopware/pull/100#discussion_r5551", "body": "x"}'
    assert_success
    assert_gh_call_count 3
    assert_gh_last_args_contain_all "-f id=PRRC_mine"
}

@test "comment_edit fails when no pending review belongs to the caller, even if another's holds the comment" {
    GH_STUB_GET_EXIT=1
    GH_STUB_GET_STDERR="${NOT_FOUND_STDERR}"
    GH_STUB_LOOKUP_OUTPUT='{"data":{"repository":{"pullRequest":{"reviews":{"pageInfo":{"hasNextPage":false},"nodes":[{"viewerDidAuthor":false,"comments":{"nodes":[{"id":"PRRC_theirs","fullDatabaseId":"5551"}],"pageInfo":{"hasNextPage":false}}}]}}}}}'
    run tool_comment_edit '{"url": "https://github.com/shopware/shopware/pull/100#discussion_r5551", "body": "x"}'
    assert_failure
    assert_error_output
    assert_output --partial "not in your pending review"
    assert_gh_call_count 2
    assert_no_rest_write
}

@test "comment_edit fails when the caller's review is not among more than 100 pending reviews" {
    GH_STUB_GET_EXIT=1
    GH_STUB_GET_STDERR="${NOT_FOUND_STDERR}"
    GH_STUB_LOOKUP_OUTPUT='{"data":{"repository":{"pullRequest":{"reviews":{"pageInfo":{"hasNextPage":true},"nodes":[{"viewerDidAuthor":false,"comments":{"nodes":[],"pageInfo":{"hasNextPage":false}}}]}}}}}'
    run tool_comment_edit '{"url": "https://github.com/shopware/shopware/pull/100#discussion_r5551", "body": "x"}'
    assert_failure
    assert_error_output
    assert_output --partial "more than 100 pending reviews"
    assert_gh_call_count 2
    assert_no_rest_write
}

@test "comment_edit asks GitHub for up to 100 pending reviews with their viewerDidAuthor flag" {
    GH_STUB_GET_EXIT=1
    GH_STUB_GET_STDERR="${NOT_FOUND_STDERR}"
    GH_STUB_LOOKUP_OUTPUT="${PENDING_NONE}"
    run tool_comment_edit '{"url": "https://github.com/shopware/shopware/pull/100#discussion_r5551", "body": "x"}'
    assert_failure
    assert_gh_call_contains_all 2 "reviews(states: [PENDING], first: 100) { pageInfo { hasNextPage } nodes { viewerDidAuthor comments"
}

@test "comment_edit fails when the pending-review lookup exits non-zero, with gh's message and no mutation" {
    GH_STUB_GET_EXIT=1
    GH_STUB_GET_STDERR="${NOT_FOUND_STDERR}"
    GH_STUB_LOOKUP_EXIT=1
    GH_STUB_LOOKUP_STDERR="gh: Could not resolve to a Repository"
    run tool_comment_edit '{"url": "https://github.com/shopware/shopware/pull/100#discussion_r5551", "body": "x"}'
    assert_failure
    assert_error_output
    assert_output --partial "pending-review lookup failed"
    assert_output --partial "Could not resolve to a Repository"
    assert_gh_call_count 2
    assert_no_rest_write
}

@test "comment_edit fails when the lookup response carries GraphQL errors" {
    GH_STUB_GET_EXIT=1
    GH_STUB_GET_STDERR="${NOT_FOUND_STDERR}"
    GH_STUB_LOOKUP_OUTPUT='{"errors":[{"message":"Something broke"}],"data":null}'
    run tool_comment_edit '{"url": "https://github.com/shopware/shopware/pull/100#discussion_r5551", "body": "x"}'
    assert_failure
    assert_error_output
    assert_output --partial "Something broke"
    assert_gh_call_count 2
}

@test "comment_edit fails when the lookup succeeds with no output" {
    GH_STUB_GET_EXIT=1
    GH_STUB_GET_STDERR="${NOT_FOUND_STDERR}"
    GH_STUB_LOOKUP_OUTPUT=""
    run tool_comment_edit '{"url": "https://github.com/shopware/shopware/pull/100#discussion_r5551", "body": "x"}'
    assert_failure
    assert_error_output
    assert_output --partial "pending-review lookup failed: GitHub returned no output"
    assert_gh_call_count 2
}

@test "comment_edit names the failed call and keeps gh's exit status when the lookup fails with no output" {
    GH_STUB_GET_EXIT=1
    GH_STUB_GET_STDERR="${NOT_FOUND_STDERR}"
    GH_STUB_LOOKUP_EXIT=5
    run tool_comment_edit '{"url": "https://github.com/shopware/shopware/pull/100#discussion_r5551", "body": "x"}'
    assert_failure 5
    assert_error_output
    assert_output --partial "gh api graphql failed with exit 5 and no output"
}

@test "comment_edit fails when the lookup output is not JSON" {
    GH_STUB_GET_EXIT=1
    GH_STUB_GET_STDERR="${NOT_FOUND_STDERR}"
    GH_STUB_LOOKUP_OUTPUT="<html>bad gateway</html>"
    run tool_comment_edit '{"url": "https://github.com/shopware/shopware/pull/100#discussion_r5551", "body": "x"}'
    assert_failure
    assert_error_output
    assert_output --partial "unparseable response"
    assert_gh_call_count 2
}

@test "comment_edit fails when the lookup response has no pull request" {
    GH_STUB_GET_EXIT=1
    GH_STUB_GET_STDERR="${NOT_FOUND_STDERR}"
    GH_STUB_LOOKUP_OUTPUT='{"data":{"repository":{"pullRequest":null}}}'
    run tool_comment_edit '{"url": "https://github.com/shopware/shopware/pull/100#discussion_r5551", "body": "x"}'
    assert_failure
    assert_error_output
    assert_output --partial "no pull request data"
    assert_gh_call_count 2
}

@test "comment_edit fails with gh's message when the mutation exits non-zero, with no REST write" {
    GH_STUB_GET_EXIT=1
    GH_STUB_GET_STDERR="${NOT_FOUND_STDERR}"
    GH_STUB_LOOKUP_OUTPUT="${PENDING_MATCH}"
    GH_STUB_MUTATION_EXIT=1
    GH_STUB_MUTATION_STDERR="gh: Resource not accessible"
    run tool_comment_edit '{"url": "https://github.com/shopware/shopware/pull/100#discussion_r5551", "body": "x"}'
    assert_failure
    assert_error_output
    assert_output --partial "Resource not accessible"
    assert_gh_call_count 3
    assert_no_rest_write
}

@test "comment_edit fails when the mutation response carries errors" {
    GH_STUB_GET_EXIT=1
    GH_STUB_GET_STDERR="${NOT_FOUND_STDERR}"
    GH_STUB_LOOKUP_OUTPUT="${PENDING_MATCH}"
    GH_STUB_MUTATION_OUTPUT='{"errors":[{"message":"Body cannot be blank"}]}'
    run tool_comment_edit '{"url": "https://github.com/shopware/shopware/pull/100#discussion_r5551", "body": "x"}'
    assert_failure
    assert_error_output
    assert_output --partial "Body cannot be blank"
    assert_no_rest_write
}

@test "comment_edit fails when the mutation succeeds with no output" {
    GH_STUB_GET_EXIT=1
    GH_STUB_GET_STDERR="${NOT_FOUND_STDERR}"
    GH_STUB_LOOKUP_OUTPUT="${PENDING_MATCH}"
    GH_STUB_MUTATION_OUTPUT=""
    run tool_comment_edit '{"url": "https://github.com/shopware/shopware/pull/100#discussion_r5551", "body": "x"}'
    assert_failure
    assert_error_output
    assert_output --partial "pending-review comment edit failed"
}

@test "comment_edit fails when the mutation response has a null url" {
    GH_STUB_GET_EXIT=1
    GH_STUB_GET_STDERR="${NOT_FOUND_STDERR}"
    GH_STUB_LOOKUP_OUTPUT="${PENDING_MATCH}"
    GH_STUB_MUTATION_OUTPUT='{"data":{"updatePullRequestReviewComment":{"pullRequestReviewComment":{"url":null}}}}'
    run tool_comment_edit '{"url": "https://github.com/shopware/shopware/pull/100#discussion_r5551", "body": "x"}'
    assert_failure
    assert_error_output
    assert_output --partial "no URL for the edited comment"
}

@test "comment_edit names the failed call and keeps gh's exit status when the mutation fails with no output" {
    GH_STUB_GET_EXIT=1
    GH_STUB_GET_STDERR="${NOT_FOUND_STDERR}"
    GH_STUB_LOOKUP_OUTPUT="${PENDING_MATCH}"
    GH_STUB_MUTATION_EXIT=4
    run tool_comment_edit '{"url": "https://github.com/shopware/shopware/pull/100#discussion_r5551", "body": "x"}'
    assert_failure 4
    assert_error_output
    assert_output --partial "gh api graphql failed with exit 4 and no output"
}

# ---- review summary body ------------------------------------------------------

@test "comment_edit puts a review body with PUT on the PR's reviews endpoint without reading it first" {
    GH_STUB_WRITE_OUTPUT="https://example/c"
    run tool_comment_edit '{"url": "https://github.com/shopware/shopware/pull/100#pullrequestreview-777", "body": "New summary"}'
    assert_success
    assert_gh_args_equal "api repos/shopware/shopware/pulls/100/reviews/777 -X PUT -f body=New summary --jq .html_url // empty"
}

# ---- stderr warnings on successful calls -------------------------------------

@test "comment_edit returns the clean URL when a successful read and PATCH each print a warning on stderr" {
    stub_get_issue 7
    GH_STUB_GET_STDERR="${WARNING_STDERR}"
    GH_STUB_WRITE_STDERR="${WARNING_STDERR}"
    GH_STUB_WRITE_OUTPUT="https://github.com/shopware/shopware/issues/7#issuecomment-9001"
    run --separate-stderr tool_comment_edit '{"url": "shopware/shopware/issues/7#issuecomment-9001", "body": "x"}'
    assert_success
    assert_output "https://github.com/shopware/shopware/issues/7#issuecomment-9001"
}

@test "comment_edit returns the clean URL when a successful review PUT prints a warning on stderr" {
    GH_STUB_WRITE_STDERR="${WARNING_STDERR}"
    GH_STUB_WRITE_OUTPUT="https://example/review"
    run --separate-stderr tool_comment_edit '{"url": "https://github.com/shopware/shopware/pull/100#pullrequestreview-777", "body": "x"}'
    assert_success
    assert_output "https://example/review"
}

@test "comment_edit returns the clean URL when a successful lookup and mutation each print a warning on stderr" {
    GH_STUB_GET_EXIT=1
    GH_STUB_GET_STDERR="${NOT_FOUND_STDERR}"
    GH_STUB_LOOKUP_OUTPUT="${PENDING_MATCH}"
    GH_STUB_LOOKUP_STDERR="${WARNING_STDERR}"
    GH_STUB_MUTATION_OUTPUT="${MUTATION_OK}"
    GH_STUB_MUTATION_STDERR="${WARNING_STDERR}"
    run --separate-stderr tool_comment_edit '{"url": "https://github.com/shopware/shopware/pull/100#discussion_r5551", "body": "x"}'
    assert_success
    assert_output "https://github.com/shopware/shopware/pull/100#discussion_r5551"
}

# ---- URL handling -----------------------------------------------------------------

@test "comment_edit takes the repository from the URL, not from the default repo" {
    GH_STUB_GET_OUTPUT='{"id":1,"issue_url":"https://api.github.com/repos/other-org/other.repo/issues/7"}'
    GH_STUB_WRITE_OUTPUT="https://example/c"
    run tool_comment_edit '{"url": "other-org/other.repo/issues/7#issuecomment-1", "body": "x"}'
    assert_success
    assert_gh_call_equal 1 "api repos/other-org/other.repo/issues/comments/1"
    assert_gh_call_equal 2 "api repos/other-org/other.repo/issues/comments/1 -X PATCH -f body=x --jq .html_url // empty"
}

@test "comment_edit strips the http and www.github.com prefixes" {
    stub_get_issue 7
    GH_STUB_WRITE_OUTPUT="https://example/c"
    local prefix
    for prefix in "http://github.com/" "https://www.github.com/"; do
        : > "${GH_ARGS_FILE}"
        run tool_comment_edit "{\"url\": \"${prefix}shopware/shopware/issues/7#issuecomment-3\", \"body\": \"x\"}"
        assert_success
        assert_gh_last_args_equal "api repos/shopware/shopware/issues/comments/3 -X PATCH -f body=x --jq .html_url // empty"
    done
}

@test "comment_edit requires url" {
    run tool_comment_edit '{"body": "x"}'
    assert_failure
    assert_output --partial "url is required"
    assert_gh_not_called
}

@test "comment_edit requires body" {
    run tool_comment_edit '{"url": "shopware/shopware/issues/7#issuecomment-3"}'
    assert_failure
    assert_output --partial "body is required"
    assert_gh_not_called
}

@test "comment_edit rejects a URL on another host" {
    run tool_comment_edit '{"url": "https://ghe.example.com/shopware/shopware/pull/1#issuecomment-5", "body": "x"}'
    assert_failure
    assert_error_output
    assert_output --partial "must be a github.com URL"
    assert_gh_not_called
}

@test "comment_edit rejects a bare host that is not github.com" {
    run tool_comment_edit '{"url": "ghe.example.com/shopware/pull/1#issuecomment-5", "body": "x"}'
    assert_failure
    assert_error_output
    assert_output --partial "url must be"
    assert_gh_not_called
}

@test "comment_edit rejects a URL without an anchor" {
    run tool_comment_edit '{"url": "https://github.com/shopware/shopware/pull/100", "body": "x"}'
    assert_failure
    assert_output --partial "url must be"
    assert_gh_not_called
}

@test "comment_edit rejects an unknown anchor" {
    run tool_comment_edit '{"url": "https://github.com/shopware/shopware/pull/100#event-5", "body": "x"}'
    assert_failure
    assert_output --partial "url must be"
    assert_gh_not_called
}

@test "comment_edit rejects a non-numeric comment ID" {
    run tool_comment_edit '{"url": "https://github.com/shopware/shopware/pull/100#issuecomment-abc", "body": "x"}'
    assert_failure
    assert_output --partial "url must be"
    assert_gh_not_called
}

@test "comment_edit rejects a non-numeric issue or PR number" {
    run tool_comment_edit '{"url": "https://github.com/shopware/shopware/pull/abc#issuecomment-5", "body": "x"}'
    assert_failure
    assert_output --partial "url must be"
    assert_gh_not_called
}

@test "comment_edit rejects a review-comment anchor on an issues URL" {
    run tool_comment_edit '{"url": "https://github.com/shopware/shopware/issues/7#discussion_r5", "body": "x"}'
    assert_failure
    assert_output --partial "url must be"
    assert_gh_not_called
}

@test "comment_edit rejects an r anchor on an issues/N/files URL" {
    run tool_comment_edit '{"url": "https://github.com/shopware/shopware/issues/7/files#r5", "body": "x"}'
    assert_failure
    assert_output --partial "url must be"
    assert_gh_not_called
}

@test "comment_edit rejects a review anchor on an issues URL" {
    run tool_comment_edit '{"url": "https://github.com/shopware/shopware/issues/7#pullrequestreview-5", "body": "x"}'
    assert_failure
    assert_output --partial "url must be"
    assert_gh_not_called
}

@test "comment_edit rejects an r anchor without /files or /changes" {
    run tool_comment_edit '{"url": "https://github.com/shopware/shopware/pull/100#r5", "body": "x"}'
    assert_failure
    assert_output --partial "url must be"
    assert_gh_not_called
}

@test "comment_edit rejects a discussion_r anchor on a /files URL" {
    run tool_comment_edit '{"url": "https://github.com/shopware/shopware/pull/100/files#discussion_r5", "body": "x"}'
    assert_failure
    assert_output --partial "url must be"
    assert_gh_not_called
}

@test "comment_edit rejects a review anchor on a /files URL" {
    run tool_comment_edit '{"url": "https://github.com/shopware/shopware/pull/100/files#pullrequestreview-5", "body": "x"}'
    assert_failure
    assert_output --partial "url must be"
    assert_gh_not_called
}

@test "comment_edit rejects a non-numeric review ID" {
    run tool_comment_edit '{"url": "https://github.com/shopware/shopware/pull/100#pullrequestreview-", "body": "x"}'
    assert_failure
    assert_output --partial "url must be"
    assert_gh_not_called
}

@test "comment_edit rejects extra path segments" {
    run tool_comment_edit '{"url": "https://github.com/shopware/shopware/pull/100/commits#issuecomment-5", "body": "x"}'
    assert_failure
    assert_output --partial "url must be"
    assert_gh_not_called
}

@test "comment_edit rejects a repository name ending in .git" {
    run tool_comment_edit '{"url": "owner/repo.git/issues/1#issuecomment-2", "body": "x"}'
    assert_failure
    assert_output --partial "url must be"
    assert_gh_not_called
}

@test "comment_edit rejects a repository named .." {
    run tool_comment_edit '{"url": "shopware/../issues/7#issuecomment-5", "body": "x"}'
    assert_failure
    assert_output --partial "url must be"
    assert_gh_not_called
}

# ---- the edit request's result ------------------------------------------------

@test "comment_edit fails with the call named and gh's message when the PATCH fails" {
    stub_get_issue 7
    GH_STUB_WRITE_EXIT=1
    GH_STUB_WRITE_OUTPUT='{"message":"Validation Failed"}'
    GH_STUB_WRITE_STDERR="gh: Validation Failed (HTTP 422)"
    run tool_comment_edit '{"url": "shopware/shopware/issues/7#issuecomment-5", "body": "x"}'
    assert_failure
    assert_error_output
    assert_output --partial "PATCH repos/shopware/shopware/issues/comments/5 failed: gh: Validation Failed (HTTP 422)"
}

@test "comment_edit names the failed call and keeps gh's exit status when the PATCH fails with no output" {
    stub_get_issue 7
    GH_STUB_WRITE_EXIT=3
    run tool_comment_edit '{"url": "shopware/shopware/issues/7#issuecomment-3", "body": "x"}'
    assert_failure 3
    assert_error_output
    assert_output --partial "PATCH repos/shopware/shopware/issues/comments/3 failed: gh exited with status 3 and no output"
}

@test "comment_edit fails with a message when the PATCH succeeds with no output" {
    stub_get_issue 7
    GH_STUB_WRITE_OUTPUT=""
    run tool_comment_edit '{"url": "shopware/shopware/issues/7#issuecomment-3", "body": "x"}'
    assert_failure
    assert_error_output
    assert_output --partial "no URL for the edited comment"
}

@test "comment_edit fails when the PATCH response has no html_url field" {
    stub_get_issue 7
    GH_STUB_APPLY_JQ=1
    GH_STUB_WRITE_OUTPUT='{"id":3,"body":"x"}'
    run tool_comment_edit '{"url": "shopware/shopware/issues/7#issuecomment-3", "body": "x"}'
    assert_failure
    assert_error_output
    assert_output --partial "no URL for the edited comment"
    refute_output --partial "null"
}

@test "comment_edit returns html_url from the PATCH response when the stub applies the filter" {
    stub_get_issue 7
    GH_STUB_APPLY_JQ=1
    GH_STUB_WRITE_OUTPUT='{"id":3,"html_url":"https://example/c"}'
    run tool_comment_edit '{"url": "shopware/shopware/issues/7#issuecomment-3", "body": "x"}'
    assert_success
    assert_output "https://example/c"
}

# ---- argv integrity ---------------------------------------------------------------

# Every argument of the last gh call, one array element each.
read_gh_argv() {
    local n
    n=$(find "${BATS_TEST_TMPDIR}" -maxdepth 1 -name 'gh_argv.*' | wc -l | tr -d ' ')
    GH_ARGV=()
    local a
    while IFS= read -r -d '' a; do
        GH_ARGV+=("$a")
    done < "${BATS_TEST_TMPDIR}/gh_argv.${n}"
}

# Exactly one argument equals the expected text.
assert_one_argv_equal() {
    local expected="$1" arg count=0
    for arg in "${GH_ARGV[@]}"; do
        [[ "${arg}" == "${expected}" ]] && count=$((count + 1))
    done
    [[ ${count} -eq 1 ]] || fail "Expected exactly one argument equal to '${expected}', found ${count} in: $(printf '[%s] ' "${GH_ARGV[@]}")"
}

TRICKY_BODY=$'-leading dash, two words a=b @file.txt "double" \'single\'\nsecond line'

@test "comment_edit passes a body with special characters as one -f argument" {
    stub_get_issue 7
    GH_STUB_WRITE_OUTPUT="https://example/c"
    # shellcheck disable=SC2016 # the body's $(x) must stay literal
    run tool_comment_edit '{"url": "shopware/shopware/issues/7#issuecomment-3", "body": "a=b \"quoted\" $(x)"}'
    assert_success
    # shellcheck disable=SC2016
    assert_gh_last_args_equal 'api repos/shopware/shopware/issues/comments/3 -X PATCH -f body=a=b "quoted" $(x) --jq .html_url // empty'
}

@test "comment_edit passes a body with a newline, spaces, =, @, quotes, and a leading dash as exactly one REST argument" {
    stub_get_issue 7
    GH_STUB_WRITE_OUTPUT="https://example/c"
    local json
    json=$(jq -cn --arg b "${TRICKY_BODY}" '{url: "shopware/shopware/issues/7#issuecomment-3", body: $b}')
    run tool_comment_edit "${json}"
    assert_success
    read_gh_argv
    assert_one_argv_equal "body=${TRICKY_BODY}"
}

@test "comment_edit passes the same body as exactly one argument to the GraphQL mutation" {
    GH_STUB_GET_EXIT=1
    GH_STUB_GET_STDERR="${NOT_FOUND_STDERR}"
    GH_STUB_LOOKUP_OUTPUT="${PENDING_MATCH}"
    GH_STUB_MUTATION_OUTPUT="${MUTATION_OK}"
    local json
    json=$(jq -cn --arg b "${TRICKY_BODY}" '{url: "https://github.com/shopware/shopware/pull/100#discussion_r5551", body: $b}')
    run tool_comment_edit "${json}"
    assert_success
    assert_no_rest_write
    read_gh_argv
    assert_one_argv_equal "body=${TRICKY_BODY}"
}
