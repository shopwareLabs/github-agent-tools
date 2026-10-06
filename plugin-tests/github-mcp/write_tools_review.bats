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
        # Runaway guard: a looping lookup ends here instead of hanging the suite.
        # The page-limit test makes 51 calls.
        if [[ "${call_n}" -ge 60 ]]; then
            echo "stub: more than 60 gh calls" >&2
            return 99
        fi
        if [[ "$*" == *"--input"* ]]; then
            cat > "${GH_STDIN_FILE}"
        fi
        if [[ "$*" == *"head.sha"* ]]; then
            printf '%s\n' "${GH_STUB_HEAD_SHA:-0123456789abcdef0123456789abcdef01234567}"
            return 0
        fi
        # comment_edit's calls, told apart by what the argv names. Each kind has
        # its own stdout, stderr, and exit code: GH_STUB_<KIND>_OUTPUT/_STDERR/_EXIT.
        # A page fetch of a pending review's comments is keyed by the cursor it
        # sends, so each page has its own canned answer: GH_STUB_PAGE_<cursor>_*.
        local kind="" get_re='^api repos/[^ ]+/(comments|reviews)/[0-9]+$'
        # shellcheck disable=SC2016  # literal GraphQL text ($reviewId), not a shell variable
        if [[ "$*" == *"reviews(states: [PENDING]"* ]]; then
            kind=LOOKUP
        elif [[ "$*" == *"... on Comment { viewerDidAuthor }"* ]]; then
            kind=AUTHOR
        elif [[ "$*" == *'node(id: $reviewId)'* ]]; then
            local arg cursor=""
            for arg in "$@"; do
                [[ "${arg}" == cursor=* ]] && cursor="${arg#cursor=}"
            done
            kind="PAGE_${cursor}"
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
    for kind in GET WRITE LOOKUP MUTATION AUTHOR; do
        printf -v "GH_STUB_${kind}_OUTPUT" '%s' ""
        printf -v "GH_STUB_${kind}_STDERR" '%s' ""
        printf -v "GH_STUB_${kind}_EXIT" '%s' 0
    done
    GH_STUB_AUTHOR_OUTPUT="${AUTHOR_YES}"
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

PENDING_MATCH='{"data":{"repository":{"pullRequest":{"reviews":{"nodes":[{"comments":{"nodes":[{"id":"PRRC_other","fullDatabaseId":"4000"},{"id":"PRRC_node5551","fullDatabaseId":"5551"}],"pageInfo":{"hasNextPage":false}}}]}}}}}'
PENDING_BIG='{"data":{"repository":{"pullRequest":{"reviews":{"nodes":[{"comments":{"nodes":[{"id":"PRRC_near","fullDatabaseId":"4195291200"},{"id":"PRRC_big","fullDatabaseId":"4195291201"}],"pageInfo":{"hasNextPage":false}}}]}}}}}'
PENDING_PAGED='{"data":{"repository":{"pullRequest":{"reviews":{"nodes":[{"id":"PRR_mine","comments":{"nodes":[{"id":"PRRC_a","fullDatabaseId":"1"}],"pageInfo":{"hasNextPage":true,"endCursor":"CUR1"}}}]}}}}}'
PAGE_MORE='{"data":{"node":{"comments":{"nodes":[{"id":"PRRC_b","fullDatabaseId":"2"}],"pageInfo":{"hasNextPage":true,"endCursor":"CUR2"}}}}}'
PAGE_LAST_MATCH='{"data":{"node":{"comments":{"nodes":[{"id":"PRRC_node5551","fullDatabaseId":"5551"}],"pageInfo":{"hasNextPage":false,"endCursor":"CURLAST"}}}}}'
PAGE_LAST_NO_MATCH='{"data":{"node":{"comments":{"nodes":[{"id":"PRRC_c","fullDatabaseId":"3"}],"pageInfo":{"hasNextPage":false,"endCursor":"CURLAST"}}}}}'
AUTHOR_YES='{"data":{"node":{"viewerDidAuthor":true}}}'
AUTHOR_NO='{"data":{"node":{"viewerDidAuthor":false}}}'
# The author query's argv, up to the node ID that follows it.
# shellcheck disable=SC2016  # literal GraphQL text, not a shell variable
AUTHOR_CALL='api graphql -f query=query($id: ID!) { node(id: $id) { ... on Comment { viewerDidAuthor } } } -f id='
# A text no failure message may repeat: it stands for a comment body.
BODY_MARKER="SECRET-BODY-TEXT"
MUTATION_OK='{"data":{"updatePullRequestReviewComment":{"pullRequestReviewComment":{"url":"https://github.com/shopware/shopware/pull/100#discussion_r5551"}}}}'

# The GET answer for a comment that belongs to issue or PR N, written by $2
# (default "me"; the login only names the author in a refusal) and carrying a
# body, so a test can tell whether a failure repeats the comment.
stub_get_issue() {
    GH_STUB_GET_OUTPUT=$(jq -cn --arg u "https://api.github.com/repos/shopware/shopware/issues/$1" --arg l "${2:-me}" --arg b "${BODY_MARKER}" '{id: 1, node_id: "IC_node1", issue_url: $u, user: {login: $l}, body: $b}')
}

stub_get_pull() {
    GH_STUB_GET_OUTPUT=$(jq -cn --arg u "https://api.github.com/repos/shopware/shopware/pulls/$1" --arg l "${2:-me}" --arg b "${BODY_MARKER}" '{id: 1, node_id: "PRRC_node1", pull_request_url: $u, user: {login: $l}, body: $b}')
}

# The author query was not sent.
assert_no_author_query() {
    ! grep -qF -- "... on Comment { viewerDidAuthor }" "${GH_ARGS_FILE}" || fail "Expected no author query, got: $(cat "${GH_ARGS_FILE}")"
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

# The edit mutation was not sent.
assert_no_mutation() {
    ! grep -q -- "updatePullRequestReviewComment" "${GH_ARGS_FILE}" || fail "Expected no mutation, got: $(cat "${GH_ARGS_FILE}")"
}

# No GraphQL call other than the author query: no pending-review lookup or mutation.
assert_no_graphql_call() {
    ! grep -- "graphql" "${GH_ARGS_FILE}" | grep -qvF -- "... on Comment { viewerDidAuthor }" || fail "Expected no GraphQL call, got: $(cat "${GH_ARGS_FILE}")"
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
    assert_gh_call_count 3
    assert_gh_call_equal 1 "api repos/shopware/shopware/issues/comments/9001"
    assert_gh_call_equal 2 "${AUTHOR_CALL}IC_node1"
    assert_gh_call_equal 3 "api repos/shopware/shopware/issues/comments/9001 -X PATCH -f body=New text --jq .html_url // empty"
}

@test "comment_edit patches a PR conversation comment through the issues comments endpoint" {
    stub_get_issue 100
    GH_STUB_WRITE_OUTPUT="https://example/c"
    run tool_comment_edit '{"url": "https://github.com/shopware/shopware/pull/100#issuecomment-9002", "body": "New text"}'
    assert_success
    assert_gh_call_equal 1 "api repos/shopware/shopware/issues/comments/9002"
    assert_gh_call_equal 3 "api repos/shopware/shopware/issues/comments/9002 -X PATCH -f body=New text --jq .html_url // empty"
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

@test "comment_edit names the failed read and keeps gh's exit status when the read fails with no output" {
    GH_STUB_GET_EXIT=3
    run tool_comment_edit '{"url": "shopware/shopware/issues/7#issuecomment-9001", "body": "x"}'
    assert_failure 3
    assert_error_output
    assert_output --partial "GET repos/shopware/shopware/issues/comments/9001 failed: gh failed with exit 3 and no output"
    assert_gh_call_count 1
    assert_no_rest_write
}

@test "comment_edit fails when the read of a conversation comment names no issue, without repeating the comment, and does not patch" {
    GH_STUB_GET_OUTPUT=$(jq -cn --arg b "${BODY_MARKER}" '{id: 9001, body: $b}')
    run tool_comment_edit '{"url": "shopware/shopware/issues/7#issuecomment-9001", "body": "x"}'
    assert_failure
    assert_error_output
    assert_output --partial "GET repos/shopware/shopware/issues/comments/9001 returned no issue_url"
    refute_output --partial "${BODY_MARKER}"
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
    assert_gh_call_count 3
    assert_gh_call_equal 1 "api repos/shopware/shopware/pulls/comments/5551"
    assert_gh_call_equal 3 "api repos/shopware/shopware/pulls/comments/5551 -X PATCH -f body=New text --jq .html_url // empty"
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
    assert_gh_call_count 3
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

@test "comment_edit fails when the 404 comment is not in the pending review, with no mutation or write" {
    GH_STUB_GET_EXIT=1
    GH_STUB_GET_STDERR="${NOT_FOUND_STDERR}"
    GH_STUB_LOOKUP_OUTPUT="${PENDING_MATCH}"
    run tool_comment_edit '{"url": "https://github.com/shopware/shopware/pull/100#discussion_r9999", "body": "x"}'
    assert_failure
    assert_error_output
    assert_output --partial "GET repos/shopware/shopware/pulls/comments/9999 returned 404"
    assert_output --partial "pending-review lookup on PR 100: no matching comment"
    assert_gh_call_count 2
    assert_no_rest_write
    assert_no_mutation
}

@test "comment_edit finds the comment on the second page of a large pending review and edits it with that node id" {
    GH_STUB_GET_EXIT=1
    GH_STUB_GET_STDERR="${NOT_FOUND_STDERR}"
    GH_STUB_LOOKUP_OUTPUT="${PENDING_PAGED}"
    GH_STUB_PAGE_CUR1_OUTPUT="${PAGE_LAST_MATCH}"
    GH_STUB_MUTATION_OUTPUT="${MUTATION_OK}"
    run tool_comment_edit '{"url": "https://github.com/shopware/shopware/pull/100#discussion_r5551", "body": "New text"}'
    assert_success
    assert_output "https://github.com/shopware/shopware/pull/100#discussion_r5551"
    assert_gh_call_count 4
    assert_gh_call_contains_all 3 "-f reviewId=PRR_mine" "-f cursor=CUR1"
    assert_gh_last_args_contain_all "updatePullRequestReviewComment" "-f id=PRRC_node5551" "-f body=New text"
    assert_no_rest_write
}

@test "comment_edit follows each page's cursor until the comment turns up on the third page" {
    GH_STUB_GET_EXIT=1
    GH_STUB_GET_STDERR="${NOT_FOUND_STDERR}"
    GH_STUB_LOOKUP_OUTPUT="${PENDING_PAGED}"
    GH_STUB_PAGE_CUR1_OUTPUT="${PAGE_MORE}"
    GH_STUB_PAGE_CUR2_OUTPUT="${PAGE_LAST_MATCH}"
    GH_STUB_MUTATION_OUTPUT="${MUTATION_OK}"
    run tool_comment_edit '{"url": "https://github.com/shopware/shopware/pull/100#discussion_r5551", "body": "x"}'
    assert_success
    assert_gh_call_count 5
    assert_gh_call_contains_all 3 "-f reviewId=PRR_mine" "-f cursor=CUR1"
    assert_gh_call_contains_all 4 "-f reviewId=PRR_mine" "-f cursor=CUR2"
    assert_gh_last_args_contain_all "-f id=PRRC_node5551"
}

@test "comment_edit fails with the 404 and no matching comment when no page of a large pending review holds it" {
    GH_STUB_GET_EXIT=1
    GH_STUB_GET_STDERR="${NOT_FOUND_STDERR}"
    GH_STUB_LOOKUP_OUTPUT="${PENDING_PAGED}"
    GH_STUB_PAGE_CUR1_OUTPUT="${PAGE_LAST_NO_MATCH}"
    run tool_comment_edit '{"url": "https://github.com/shopware/shopware/pull/100#discussion_r5551", "body": "x"}'
    assert_failure
    assert_error_output
    assert_output --partial "returned 404"
    assert_output --partial "pending-review lookup on PR 100: no matching comment"
    assert_gh_call_count 3
    assert_no_rest_write
    assert_no_mutation
}

@test "comment_edit stops at the page limit when every page reports more, with no mutation" {
    GH_STUB_GET_EXIT=1
    GH_STUB_GET_STDERR="${NOT_FOUND_STDERR}"
    GH_STUB_LOOKUP_OUTPUT="${PENDING_PAGED}"
    GH_STUB_PAGE_CUR1_OUTPUT='{"data":{"node":{"comments":{"nodes":[{"id":"PRRC_b","fullDatabaseId":"2"}],"pageInfo":{"hasNextPage":true,"endCursor":"CUR1"}}}}}'
    run tool_comment_edit '{"url": "https://github.com/shopware/shopware/pull/100#discussion_r5551", "body": "x"}'
    assert_failure
    assert_error_output
    assert_output --partial "pending-review lookup on PR 100: reached the limit of 50 comment pages without finding comment 5551"
    assert_gh_call_count 51
    assert_no_rest_write
    assert_no_mutation
}

@test "comment_edit fails and sends no mutation when the second page of comments cannot be read" {
    GH_STUB_GET_EXIT=1
    GH_STUB_GET_STDERR="${NOT_FOUND_STDERR}"
    GH_STUB_LOOKUP_OUTPUT="${PENDING_PAGED}"
    GH_STUB_PAGE_CUR1_EXIT=7
    GH_STUB_PAGE_CUR1_STDERR="gh: Bad Gateway (HTTP 502)"
    run tool_comment_edit '{"url": "https://github.com/shopware/shopware/pull/100#discussion_r5551", "body": "x"}'
    assert_failure 7
    assert_error_output
    assert_output --partial "returned 404"
    assert_output --partial "Bad Gateway (HTTP 502)"
    assert_gh_call_count 3
    assert_no_rest_write
    assert_no_mutation
}

@test "comment_edit fails and sends no mutation when the second page lacks the expected data, without repeating the page" {
    GH_STUB_GET_EXIT=1
    GH_STUB_GET_STDERR="${NOT_FOUND_STDERR}"
    GH_STUB_LOOKUP_OUTPUT="${PENDING_PAGED}"
    local answer
    for answer in '{"data":{"node":null}}' \
                  '{"data":{"node":{"comments":"SECRET-BODY-TEXT"}}}' \
                  '{"data":"SECRET-BODY-TEXT"}'; do
        GH_STUB_PAGE_CUR1_OUTPUT="${answer}"
        : > "${GH_ARGS_FILE}"
        run tool_comment_edit '{"url": "https://github.com/shopware/shopware/pull/100#discussion_r5551", "body": "x"}'
        [[ "${status}" -ne 0 ]] || fail "Expected the answer ${answer} to fail"
        assert_error_output
        assert_output --partial "pending-review lookup on PR 100: unexpected response from GitHub for comment page 2 of your pending review"
        refute_output --partial "${BODY_MARKER}"
        assert_gh_call_count 3
        assert_no_mutation
    done
}

@test "comment_edit edits a matching pending-review comment even when the review has further pages" {
    GH_STUB_GET_EXIT=1
    GH_STUB_GET_STDERR="${NOT_FOUND_STDERR}"
    GH_STUB_LOOKUP_OUTPUT='{"data":{"repository":{"pullRequest":{"reviews":{"nodes":[{"comments":{"nodes":[{"id":"PRRC_node5551","fullDatabaseId":"5551"}],"pageInfo":{"hasNextPage":true}}}]}}}}}'
    GH_STUB_MUTATION_OUTPUT="${MUTATION_OK}"
    run tool_comment_edit '{"url": "https://github.com/shopware/shopware/pull/100#discussion_r5551", "body": "x"}'
    assert_success
    assert_gh_call_count 3
}

@test "comment_edit searches every returned pending review and edits the match from the second one" {
    GH_STUB_GET_EXIT=1
    GH_STUB_GET_STDERR="${NOT_FOUND_STDERR}"
    GH_STUB_LOOKUP_OUTPUT='{"data":{"repository":{"pullRequest":{"reviews":{"nodes":[{"comments":{"nodes":[{"id":"PRRC_theirs","fullDatabaseId":"4000"}],"pageInfo":{"hasNextPage":false}}},{"comments":{"nodes":[{"id":"PRRC_mine","fullDatabaseId":"5551"}],"pageInfo":{"hasNextPage":false}}}]}}}}}'
    GH_STUB_MUTATION_OUTPUT="${MUTATION_OK}"
    run tool_comment_edit '{"url": "https://github.com/shopware/shopware/pull/100#discussion_r5551", "body": "x"}'
    assert_success
    assert_gh_call_count 3
    assert_gh_last_args_contain_all "-f id=PRRC_mine"
}

@test "comment_edit fails when the pending-review lookup exits non-zero, with gh's message and no mutation" {
    GH_STUB_GET_EXIT=1
    GH_STUB_GET_STDERR="${NOT_FOUND_STDERR}"
    GH_STUB_LOOKUP_EXIT=1
    GH_STUB_LOOKUP_STDERR="gh: Could not resolve to a Repository"
    run tool_comment_edit '{"url": "https://github.com/shopware/shopware/pull/100#discussion_r5551", "body": "x"}'
    assert_failure
    assert_error_output
    assert_output --partial "GET repos/shopware/shopware/pulls/comments/5551 returned 404 (not found, or no access to the repository)"
    assert_output --partial "pending-review lookup on PR 100: gh: Could not resolve to a Repository"
    assert_gh_call_count 2
    assert_no_rest_write
}

@test "comment_edit states the 404 and the GraphQL message when the lookup answers a Could not resolve error" {
    GH_STUB_GET_EXIT=1
    GH_STUB_GET_STDERR="${NOT_FOUND_STDERR}"
    GH_STUB_LOOKUP_OUTPUT='{"errors":[{"type":"NOT_FOUND","message":"Could not resolve to a Repository with the name shopware/shopware."}],"data":{"repository":null}}'
    run tool_comment_edit '{"url": "https://github.com/shopware/shopware/pull/100#discussion_r5551", "body": "x"}'
    assert_failure
    assert_error_output
    assert_output --partial "returned 404 (not found, or no access to the repository)"
    assert_output --partial "Could not resolve to a Repository"
    assert_gh_call_count 2
    assert_no_mutation
}

@test "comment_edit fails when the lookup succeeds with no output" {
    GH_STUB_GET_EXIT=1
    GH_STUB_GET_STDERR="${NOT_FOUND_STDERR}"
    GH_STUB_LOOKUP_OUTPUT=""
    run tool_comment_edit '{"url": "https://github.com/shopware/shopware/pull/100#discussion_r5551", "body": "x"}'
    assert_failure
    assert_error_output
    assert_output --partial "pending-review lookup on PR 100: GitHub returned no output"
    assert_gh_call_count 2
}

@test "comment_edit names the failed call and keeps gh's exit status when the lookup fails with no output" {
    GH_STUB_GET_EXIT=1
    GH_STUB_GET_STDERR="${NOT_FOUND_STDERR}"
    GH_STUB_LOOKUP_EXIT=5
    run tool_comment_edit '{"url": "https://github.com/shopware/shopware/pull/100#discussion_r5551", "body": "x"}'
    assert_failure 5
    assert_error_output
    assert_output --partial "pending-review lookup on PR 100: gh failed with exit 5 and no output"
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

@test "comment_edit fails when the lookup response lacks the expected data, without repeating the response" {
    GH_STUB_GET_EXIT=1
    GH_STUB_GET_STDERR="${NOT_FOUND_STDERR}"
    local answer
    for answer in '{"data":{"repository":{"pullRequest":null}}}' \
                  '{"data":{"repository":{"pullRequest":"SECRET-BODY-TEXT"}}}' \
                  '{"data":"SECRET-BODY-TEXT"}'; do
        GH_STUB_LOOKUP_OUTPUT="${answer}"
        : > "${GH_ARGS_FILE}"
        run tool_comment_edit '{"url": "https://github.com/shopware/shopware/pull/100#discussion_r5551", "body": "x"}'
        [[ "${status}" -ne 0 ]] || fail "Expected the answer ${answer} to fail"
        assert_error_output
        assert_output --partial "pending-review lookup on PR 100: unexpected response from GitHub for the pending reviews"
        refute_output --partial "${BODY_MARKER}"
        assert_gh_call_count 2
    done
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
    assert_output --partial "GET repos/shopware/shopware/pulls/comments/5551 returned 404 (not found, or no access to the repository); pending-review comment edit failed"
    assert_gh_call_count 3
    assert_no_rest_write
}

@test "comment_edit fails when the mutation response holds no url" {
    GH_STUB_GET_EXIT=1
    GH_STUB_GET_STDERR="${NOT_FOUND_STDERR}"
    GH_STUB_LOOKUP_OUTPUT="${PENDING_MATCH}"
    local answer
    for answer in '{"data":{"updatePullRequestReviewComment":{"pullRequestReviewComment":{"url":null}}}}' \
                  '{"data":{"updatePullRequestReviewComment":"oops"}}'; do
        GH_STUB_MUTATION_OUTPUT="${answer}"
        run tool_comment_edit '{"url": "https://github.com/shopware/shopware/pull/100#discussion_r5551", "body": "x"}'
        [[ "${status}" -ne 0 ]] || fail "Expected the answer ${answer} to fail"
        assert_error_output
        assert_output --partial "GET repos/shopware/shopware/pulls/comments/5551 returned 404 (not found, or no access to the repository); the pending-review edit was sent and GitHub reported success but returned no URL, so the comment may already hold the new body"
    done
}

@test "comment_edit names the failed call and keeps gh's exit status when the mutation fails with no output" {
    GH_STUB_GET_EXIT=1
    GH_STUB_GET_STDERR="${NOT_FOUND_STDERR}"
    GH_STUB_LOOKUP_OUTPUT="${PENDING_MATCH}"
    GH_STUB_MUTATION_EXIT=4
    run tool_comment_edit '{"url": "https://github.com/shopware/shopware/pull/100#discussion_r5551", "body": "x"}'
    assert_failure 4
    assert_error_output
    assert_output --partial "pending-review comment edit failed: gh failed with exit 4 and no output"
    assert_output --partial "GET repos/shopware/shopware/pulls/comments/5551 returned 404 (not found, or no access to the repository); pending-review comment edit failed"
}

# ---- review summary body ------------------------------------------------------

@test "comment_edit reads a review summary, then puts the body on the PR's reviews endpoint" {
    GH_STUB_GET_OUTPUT='{"id":777,"node_id":"PRR_node777","user":{"login":"me"}}'
    GH_STUB_WRITE_OUTPUT="https://example/c"
    run tool_comment_edit '{"url": "https://github.com/shopware/shopware/pull/100#pullrequestreview-777", "body": "New summary"}'
    assert_success
    assert_gh_call_count 3
    assert_gh_call_equal 1 "api repos/shopware/shopware/pulls/100/reviews/777"
    assert_gh_call_equal 3 "api repos/shopware/shopware/pulls/100/reviews/777 -X PUT -f body=New summary --jq .html_url // empty"
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
    GH_STUB_GET_OUTPUT='{"id":777,"node_id":"PRR_node777","user":{"login":"me"}}'
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

# ---- author guard -------------------------------------------------------------

@test "comment_edit asks GitHub about the node id of the comment it read, for each kind, before it writes" {
    GH_STUB_WRITE_OUTPUT="https://example/c"
    local row kind_url node
    for row in "shopware/shopware/issues/7#issuecomment-9001|IC_node1" \
               "https://github.com/shopware/shopware/pull/100#discussion_r5551|PRRC_node1" \
               "https://github.com/shopware/shopware/pull/100#pullrequestreview-777|PRR_node777"; do
        kind_url="${row%%|*}"
        node="${row##*|}"
        case "${node}" in
            IC_*)   stub_get_issue 7 ;;
            PRRC_*) stub_get_pull 100 ;;
            *)      GH_STUB_GET_OUTPUT='{"id":777,"node_id":"PRR_node777","user":{"login":"me"}}' ;;
        esac
        : > "${GH_ARGS_FILE}"
        run tool_comment_edit "{\"url\": \"${kind_url}\", \"body\": \"x\"}"
        [[ "${status}" -eq 0 ]] || fail "Expected '${kind_url}' to be edited, got: ${output}"
        assert_gh_call_count 3
        assert_gh_call_equal 2 "${AUTHOR_CALL}${node}"
    done
}

@test "comment_edit refuses another author's conversation comment by default, naming the author, with no write" {
    stub_get_issue 7 "octocat"
    GH_STUB_AUTHOR_OUTPUT="${AUTHOR_NO}"
    GH_STUB_WRITE_OUTPUT="https://example/c"
    local json
    for json in '{"url": "shopware/shopware/issues/7#issuecomment-9001", "body": "x"}' \
                '{"url": "shopware/shopware/issues/7#issuecomment-9001", "body": "x", "allow_other_author": false}'; do
        : > "${GH_ARGS_FILE}"
        run tool_comment_edit "${json}"
        assert_failure
        assert_error_output
        assert_output --partial "written by octocat"
        assert_output --partial "allow_other_author: true"
        refute_output --partial "${BODY_MARKER}"
        assert_gh_call_count 2
        assert_no_rest_write
    done
}

@test "comment_edit refuses another author's inline comment by default, with no write" {
    stub_get_pull 100 "octocat"
    GH_STUB_AUTHOR_OUTPUT="${AUTHOR_NO}"
    GH_STUB_WRITE_OUTPUT="https://example/c"
    run tool_comment_edit '{"url": "https://github.com/shopware/shopware/pull/100#discussion_r5551", "body": "x"}'
    assert_failure
    assert_error_output
    assert_output --partial "written by octocat"
    assert_no_rest_write
}

@test "comment_edit refuses another author's review summary by default, with no PUT" {
    GH_STUB_GET_OUTPUT='{"id":777,"node_id":"PRR_node777","user":{"login":"octocat"}}'
    GH_STUB_AUTHOR_OUTPUT="${AUTHOR_NO}"
    GH_STUB_WRITE_OUTPUT="https://example/c"
    run tool_comment_edit '{"url": "https://github.com/shopware/shopware/pull/100#pullrequestreview-777", "body": "x"}'
    assert_failure
    assert_error_output
    assert_output --partial "written by octocat"
    assert_output --partial "allow_other_author: true"
    assert_gh_call_equal 1 "api repos/shopware/shopware/pulls/100/reviews/777"
    assert_gh_call_equal 2 "${AUTHOR_CALL}PRR_node777"
    assert_no_rest_write
}

@test "comment_edit names a deleted user when the comment has no author and GitHub says the caller did not write it" {
    GH_STUB_GET_OUTPUT='{"id":1,"node_id":"IC_node1","issue_url":"https://api.github.com/repos/shopware/shopware/issues/7","user":null}'
    GH_STUB_AUTHOR_OUTPUT="${AUTHOR_NO}"
    GH_STUB_WRITE_OUTPUT="https://example/c"
    run tool_comment_edit '{"url": "shopware/shopware/issues/7#issuecomment-9001", "body": "x"}'
    assert_failure
    assert_error_output
    assert_output --partial "written by a deleted user"
    assert_output --partial "allow_other_author: true"
    assert_no_rest_write
}

@test "comment_edit edits another author's comment when allow_other_author is true, without asking GitHub who wrote it" {
    stub_get_issue 7 "octocat"
    GH_STUB_AUTHOR_OUTPUT="${AUTHOR_NO}"
    GH_STUB_WRITE_OUTPUT="https://example/c"
    run tool_comment_edit '{"url": "shopware/shopware/issues/7#issuecomment-9001", "body": "x", "allow_other_author": true}'
    assert_success
    assert_output "https://example/c"
    assert_gh_call_count 2
    assert_no_author_query
}

@test "comment_edit edits another author's review summary when allow_other_author is true" {
    GH_STUB_GET_OUTPUT='{"id":777,"user":{"login":"octocat"}}'
    GH_STUB_AUTHOR_OUTPUT="${AUTHOR_NO}"
    GH_STUB_WRITE_OUTPUT="https://example/c"
    run tool_comment_edit '{"url": "https://github.com/shopware/shopware/pull/100#pullrequestreview-777", "body": "x", "allow_other_author": true}'
    assert_success
    assert_gh_call_count 2
    assert_gh_call_equal 2 "api repos/shopware/shopware/pulls/100/reviews/777 -X PUT -f body=x --jq .html_url // empty"
    assert_no_author_query
}

@test "comment_edit fails when the review summary cannot be read, with no PUT" {
    GH_STUB_GET_EXIT=1
    GH_STUB_GET_STDERR="${NOT_FOUND_STDERR}"
    run tool_comment_edit '{"url": "https://github.com/shopware/shopware/pull/100#pullrequestreview-777", "body": "x", "allow_other_author": true}'
    assert_failure
    assert_error_output
    assert_output --partial "GET repos/shopware/shopware/pulls/100/reviews/777 failed"
    assert_gh_call_count 1
    assert_no_rest_write
}

@test "comment_edit fails with no write when the author query exits non-zero" {
    stub_get_issue 7
    GH_STUB_AUTHOR_EXIT=1
    GH_STUB_AUTHOR_STDERR="gh: Bad credentials (HTTP 401)"
    GH_STUB_WRITE_OUTPUT="https://example/c"
    run tool_comment_edit '{"url": "shopware/shopware/issues/7#issuecomment-9001", "body": "x"}'
    assert_failure
    assert_error_output
    assert_output --partial "Bad credentials"
    assert_gh_call_count 2
    assert_no_rest_write
}

@test "comment_edit refuses with no write when the author answer is anything but true" {
    stub_get_issue 7
    GH_STUB_WRITE_OUTPUT="https://example/c"
    local answer
    for answer in '{"data":{"node":null}}' \
                  '{"data":{"node":{}}}' \
                  '{"data":{"node":{"viewerDidAuthor":null}}}' \
                  '{"data":{"node":{"viewerDidAuthor":"true"}}}' \
                  '{"data":{"node":"oops"}}'; do
        GH_STUB_AUTHOR_OUTPUT="${answer}"
        : > "${GH_ARGS_FILE}"
        run tool_comment_edit '{"url": "shopware/shopware/issues/7#issuecomment-9001", "body": "x"}'
        [[ "${status}" -ne 0 ]] || fail "Expected the answer ${answer} to fail"
        assert_error_output
        assert_output --partial "written by me, not by you"
        assert_output --partial "allow_other_author: true"
        assert_gh_call_count 2
        assert_no_rest_write
    done
}

@test "comment_edit fails with no write and no author query when the comment read has no node_id, unless allow_other_author is true" {
    GH_STUB_GET_OUTPUT=$(jq -cn --arg b "${BODY_MARKER}" '{id: 1, issue_url: "https://api.github.com/repos/shopware/shopware/issues/7", user: {login: "me"}, body: $b}')
    GH_STUB_WRITE_OUTPUT="https://example/c"
    run tool_comment_edit '{"url": "shopware/shopware/issues/7#issuecomment-9001", "body": "x"}'
    assert_failure
    assert_error_output
    assert_output --partial "Error: comment_edit: unexpected response from GitHub for GET repos/shopware/shopware/issues/comments/9001"
    refute_output --partial "${BODY_MARKER}"
    assert_gh_call_count 1
    assert_no_rest_write

    : > "${GH_ARGS_FILE}"
    run tool_comment_edit '{"url": "shopware/shopware/issues/7#issuecomment-9001", "body": "x", "allow_other_author": true}'
    assert_success
}

@test "comment_edit does not ask who wrote a comment in the caller's own pending review" {
    GH_STUB_GET_EXIT=1
    GH_STUB_GET_STDERR="${NOT_FOUND_STDERR}"
    GH_STUB_LOOKUP_OUTPUT="${PENDING_MATCH}"
    GH_STUB_MUTATION_OUTPUT="${MUTATION_OK}"
    run tool_comment_edit '{"url": "https://github.com/shopware/shopware/pull/100#discussion_r5551", "body": "x"}'
    assert_success
    assert_no_author_query
}

# ---- URL handling -----------------------------------------------------------------

@test "comment_edit takes the repository from the URL, not from the default repo" {
    GH_STUB_GET_OUTPUT='{"id":1,"node_id":"IC_node1","issue_url":"https://api.github.com/repos/other-org/other.repo/issues/7","user":{"login":"me"}}'
    GH_STUB_WRITE_OUTPUT="https://example/c"
    run tool_comment_edit '{"url": "other-org/other.repo/issues/7#issuecomment-1", "body": "x"}'
    assert_success
    assert_gh_call_equal 1 "api repos/other-org/other.repo/issues/comments/1"
    assert_gh_call_equal 3 "api repos/other-org/other.repo/issues/comments/1 -X PATCH -f body=x --jq .html_url // empty"
}

@test "comment_edit reaches the expected first gh call for each accepted URL form" {
    local sha40="0123456789abcdef0123456789abcdef01234567"
    GH_STUB_GET_OUTPUT='{"id":1,"node_id":"IC_node1","issue_url":"https://api.github.com/repos/shopware/shopware/issues/100","pull_request_url":"https://api.github.com/repos/shopware/shopware/pulls/100","user":{"login":"me"}}'
    GH_STUB_WRITE_OUTPUT="https://example/c"
    local row u endpoint
    for row in \
        "http://github.com/shopware/shopware/issues/7#issuecomment-3|repos/shopware/shopware/issues/comments/3" \
        "https://www.github.com/shopware/shopware/issues/7#issuecomment-3|repos/shopware/shopware/issues/comments/3" \
        "https://GitHub.com/Shopware/Shopware/issues/7#issuecomment-3|repos/Shopware/Shopware/issues/comments/3" \
        "HTTPS://github.com/Shopware/Shopware/issues/7#issuecomment-3|repos/Shopware/Shopware/issues/comments/3" \
        "http://GITHUB.COM/Shopware/Shopware/issues/7#issuecomment-3|repos/Shopware/Shopware/issues/comments/3" \
        "https://WWW.GitHub.com/Shopware/Shopware/issues/7#issuecomment-3|repos/Shopware/Shopware/issues/comments/3" \
        "https://www.GITHUB.com/Shopware/Shopware/issues/7#issuecomment-3|repos/Shopware/Shopware/issues/comments/3" \
        "shopware/shopware/issues/100?notification_referrer_id=NT_x#issuecomment-3|repos/shopware/shopware/issues/comments/3" \
        "https://github.com/shopware/shopware/pull/100?notification_referrer_id=NT_x#issuecomment-3|repos/shopware/shopware/issues/comments/3" \
        "shopware/shopware/pull/100?notification_referrer_id=NT_x#discussion_r5551|repos/shopware/shopware/pulls/comments/5551" \
        "shopware/shopware/pull/100/files#r5552|repos/shopware/shopware/pulls/comments/5552" \
        "shopware/shopware/pull/100/changes#r5553|repos/shopware/shopware/pulls/comments/5553" \
        "shopware/shopware/pull/100/files?w=1#r5552|repos/shopware/shopware/pulls/comments/5552" \
        "shopware/shopware/pull/100/files/${sha40}..${sha40}#r5553|repos/shopware/shopware/pulls/comments/5553" \
        "shopware/shopware/pull/100/files/abc1234..def5678#r5554|repos/shopware/shopware/pulls/comments/5554" \
        "shopware/shopware/pull/100/files/${sha40}#r5558|repos/shopware/shopware/pulls/comments/5558" \
        "shopware/shopware/pull/100/files/abc1234#r5559|repos/shopware/shopware/pulls/comments/5559" \
        "shopware/shopware/pull/100/changes/${sha40}#r5560|repos/shopware/shopware/pulls/comments/5560" \
        "shopware/shopware/pull/100/changes/abc1234#r5561|repos/shopware/shopware/pulls/comments/5561" \
        "shopware/shopware/pull/100/changes/${sha40}..${sha40}#r5562|repos/shopware/shopware/pulls/comments/5562" \
        "shopware/shopware/pull/100/changes/abc1234..def5678#r5563|repos/shopware/shopware/pulls/comments/5563" \
        "shopware/shopware/pull/100/changes/abc1234..def5678?w=1#r5564|repos/shopware/shopware/pulls/comments/5564" \
        "shopware/shopware/pull/100/commits/${sha40}#r5555|repos/shopware/shopware/pulls/comments/5555" \
        "shopware/shopware/pull/100/commits/abc1234#r5556|repos/shopware/shopware/pulls/comments/5556" \
        "shopware/shopware/pull/100/commits/${sha40}?notification_referrer_id=NT_x#r5557|repos/shopware/shopware/pulls/comments/5557" \
        "shopware/shopware/pull/100?notification_referrer_id=NT_x#pullrequestreview-777|repos/shopware/shopware/pulls/100/reviews/777"; do
        u="${row%%|*}"
        endpoint="${row##*|}"
        : > "${GH_ARGS_FILE}"
        run tool_comment_edit "{\"url\": \"${u}\", \"body\": \"x\"}"
        assert_gh_call_equal 1 "api ${endpoint}"
    done
}

@test "comment_edit rejects an anchor that does not fit the kind or suffix of the URL, before any gh call" {
    local u
    for u in "https://github.com/shopware/shopware/pull/100" \
             "https://github.com/shopware/shopware/pull/100#event-5" \
             "https://github.com/shopware/shopware/pull/100#issuecomment-abc" \
             "https://github.com/shopware/shopware/pull/abc#issuecomment-5" \
             "https://github.com/shopware/shopware/pull/100#pullrequestreview-" \
             "https://github.com/shopware/shopware/issues/7#discussion_r5" \
             "https://github.com/shopware/shopware/issues/7/files#r5" \
             "https://github.com/shopware/shopware/issues/7#pullrequestreview-5" \
             "https://github.com/shopware/shopware/pull/100#r5" \
             "https://github.com/shopware/shopware/pull/100/files#discussion_r5" \
             "https://github.com/shopware/shopware/pull/100/files#pullrequestreview-5" \
             "https://github.com/shopware/shopware/pull/100/commits#issuecomment-5"; do
        run tool_comment_edit "{\"url\": \"${u}\", \"body\": \"x\"}"
        [[ "${status}" -ne 0 ]] || fail "Expected '${u}' to be rejected"
        [[ "${output}" == "Error: url must be "* ]] || fail "Expected the form error for '${u}', got: ${output}"
    done
    assert_gh_not_called
}

@test "comment_edit rejects a malformed sha segment, a misplaced query string, and a sha form on an issues URL before any gh call" {
    local sha41="0123456789abcdef0123456789abcdef012345678"
    local u
    for u in "shopware/shopware/pull/100/commits/abc123#r5" \
             "shopware/shopware/pull/100/commits/xyz1234#r5" \
             "shopware/shopware/pull/100/commits/${sha41}#r5" \
             "shopware/shopware/pull/100/commits/abc1234..def5678#r5" \
             "shopware/shopware/pull/100/commits/abc1234/files#r5" \
             "shopware/shopware/pull/100/files/abc123#r5" \
             "shopware/shopware/pull/100/files/${sha41}#r5" \
             "shopware/shopware/pull/100/files/abc1234#discussion_r5" \
             "shopware/shopware/pull/100/files/abc1234/files#r5" \
             "shopware/shopware/pull/100/changes/abc123#r5" \
             "shopware/shopware/pull/100/changes/xyz1234#r5" \
             "shopware/shopware/pull/100/changes/${sha41}#r5" \
             "shopware/shopware/pull/100/changes/abc1234..#r5" \
             "shopware/shopware/pull/100/changes/abc1234..def567#r5" \
             "shopware/shopware/pull/100/changes/abc1234...def5678#r5" \
             "shopware/shopware/pull/100/changes/abc1234#issuecomment-5" \
             "shopware/shopware/pull/100/changes/abc1234#pullrequestreview-5" \
             "shopware/shopware/issues/100/changes/abc1234#r5" \
             "shopware/shopware/issues/100/files/abc1234#r5" \
             "shopware/shopware/pull/100/files/abc1234..#r5" \
             "shopware/shopware/pull/100/files/abc1234..def567#r5" \
             "shopware/shopware/pull/100/files/abc1234...def5678#r5" \
             "shopware/shopware/pull/100/files/${sha41}..abc1234#r5" \
             "shopware/shopware/pull/100/commits/abc1234#issuecomment-5" \
             "shopware/shopware/issues/100/commits/abc1234#r5" \
             "shopware/shopware/pull/100/commits/abc1234#r5?x=1" \
             "shopware/shopware/pull/100?x=1"; do
        run tool_comment_edit "{\"url\": \"${u}\", \"body\": \"x\"}"
        [[ "${status}" -ne 0 ]] || fail "Expected '${u}' to be rejected"
        [[ "${output}" == "Error: url must be "* ]] || fail "Expected the form error for '${u}', got: ${output}"
    done
    assert_gh_not_called
}

@test "comment_edit rejects a host that only starts with github.com, in any case, before any gh call" {
    local prefix
    for prefix in "https://GitHub.com.example.org/" "https://WWW.github.com.example.org/" "https://github.community/" "https://gist.github.com/"; do
        run tool_comment_edit "{\"url\": \"${prefix}shopware/shopware/issues/7#issuecomment-3\", \"body\": \"x\"}"
        [[ "${status}" -ne 0 ]] || fail "Expected '${prefix}' to be rejected"
        assert_output --partial "must be a github.com URL"
    done
    assert_gh_not_called
}

@test "comment_edit accepts an owner with an underscore and reaches gh" {
    GH_STUB_GET_OUTPUT='{"id":1,"node_id":"IC_node1","issue_url":"https://api.github.com/repos/mona_octocorp/repo/issues/7","user":{"login":"me"}}'
    GH_STUB_WRITE_OUTPUT="https://example/c"
    run tool_comment_edit '{"url": "mona_octocorp/repo/issues/7#issuecomment-1", "body": "x"}'
    assert_success
    assert_output "https://example/c"
    assert_gh_call_equal 1 "api repos/mona_octocorp/repo/issues/comments/1"
    assert_gh_call_equal 3 "api repos/mona_octocorp/repo/issues/comments/1 -X PATCH -f body=x --jq .html_url // empty"
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
    assert_output --partial "PATCH repos/shopware/shopware/issues/comments/3 failed: gh failed with exit 3 and no output"
}

@test "comment_edit fails with a message when the PATCH succeeds with no output" {
    stub_get_issue 7
    GH_STUB_WRITE_OUTPUT=""
    run tool_comment_edit '{"url": "shopware/shopware/issues/7#issuecomment-3", "body": "x"}'
    assert_failure
    assert_error_output
    assert_output --partial "was sent and GitHub reported success but returned no URL, so the comment may already hold the new body"
}

@test "comment_edit fails when the PATCH response has no html_url field" {
    stub_get_issue 7
    GH_STUB_APPLY_JQ=1
    GH_STUB_WRITE_OUTPUT='{"id":3,"body":"x"}'
    run tool_comment_edit '{"url": "shopware/shopware/issues/7#issuecomment-3", "body": "x"}'
    assert_failure
    assert_error_output
    assert_output --partial "was sent and GitHub reported success but returned no URL, so the comment may already hold the new body"
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
