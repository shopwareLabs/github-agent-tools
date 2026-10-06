#!/usr/bin/env bash
# Review write tools for gh-tooling MCP server (write operations)
# Tools: pr_review_submit, pr_comment, pr_review_reply, comment_edit

# Submit a review on a pull request, optionally with inline comments.
#
# Two execution paths:
#   A. No comments          → `gh pr review <num> --approve|--request-changes|--comment [--body ...]`
#   B. With inline comments → `gh api repos/.../pulls/<num>/reviews -X POST --input -`
#      (commit_id auto-fetched from PR head if not provided)
tool_pr_review_submit() {
    local args="$1"

    local number event body commit_id comments_json repo suppress_errors fallback
    number=$(echo "${args}" | jq -r '.number // empty')
    event=$(echo "${args}" | jq -r '.event // "comment"')
    body=$(echo "${args}" | jq -r '.body // empty')
    commit_id=$(echo "${args}" | jq -r '.commit_id // empty')
    comments_json=$(echo "${args}" | jq -c '.comments // []')
    repo=$(echo "${args}" | jq -r '.repo // empty')
    suppress_errors=$(echo "${args}" | jq -r '.suppress_errors // false')
    fallback=$(echo "${args}" | jq -r '.fallback // empty')

    if [[ -z "${number}" ]]; then
        echo "Error: number is required for pr_review_submit"
        return 1
    fi
    _gh_validate_number "${number}" "number" || return 1

    if [[ "${event}" != "approve" && "${event}" != "request_changes" && "${event}" != "comment" ]]; then
        echo "Error: event must be one of: approve, request_changes, comment"
        return 1
    fi

    if [[ "${event}" == "request_changes" && -z "${body}" ]]; then
        echo "Error: body is required when event is request_changes"
        return 1
    fi

    local effective_repo
    effective_repo=$(_gh_resolve_repo "${repo}")

    local comments_count
    comments_count=$(echo "${comments_json}" | jq 'length')

    # Path A: no inline comments → plain `gh pr review` submit.
    if [[ "${comments_count}" -eq 0 ]]; then
        local -a cmd=("gh" "pr" "review" "${number}")
        case "${event}" in
            approve)         cmd+=("--approve") ;;
            request_changes) cmd+=("--request-changes") ;;
            comment)         cmd+=("--comment") ;;
        esac
        [[ -n "${body}" ]] && cmd+=("--body" "${body}")
        if [[ -n "${effective_repo}" ]]; then
            _gh_validate_repo "${effective_repo}" || return 1
            cmd+=("--repo" "${effective_repo}")
        fi

        log "INFO" "pr_review_submit (simple): ${cmd[*]}"
        local __raw __exit=0
        if [[ "${suppress_errors}" == "true" ]]; then
            __raw=$("${cmd[@]}" 2>/dev/null) || __exit=$?
        else
            __raw=$("${cmd[@]}" 2>&1) || __exit=$?
        fi
        if [[ ${__exit} -ne 0 ]]; then
            [[ -n "${fallback}" ]] && { echo "${fallback}"; return 0; }
            [[ "${suppress_errors}" == "true" ]] || echo "${__raw}"; return ${__exit}
        fi
        echo "${__raw}"
        return 0
    fi

    # Path B: inline comments → REST reviews endpoint with JSON body on stdin.
    _gh_require_repo "${effective_repo}" || return 1
    _gh_validate_repo "${effective_repo}" || return 1

    # Validate each comment item has path, line, body.
    local invalid
    invalid=$(echo "${comments_json}" | jq -r '
        [.[] | select((.path // "") == "" or (.line // null) == null or (.body // "") == "")] | length
    ')
    if [[ "${invalid}" -gt 0 ]]; then
        echo "Error: each item in comments requires path, line, and body"
        return 1
    fi

    # Auto-fetch head SHA if commit_id not provided.
    if [[ -z "${commit_id}" ]]; then
        local fetch_raw fetch_err fetch_exit=0
        _gh_capture_split fetch_raw fetch_err \
            gh api "repos/${effective_repo}/pulls/${number}" --jq '.head.sha' || fetch_exit=$?
        if [[ ${fetch_exit} -ne 0 ]]; then
            [[ -n "${fallback}" ]] && { echo "${fallback}"; return 0; }
            [[ "${suppress_errors}" == "true" ]] || echo "Error: failed to fetch commit_id for PR ${number}: ${fetch_err:-${fetch_raw}}"
            return 1
        fi
        commit_id="${fetch_raw}"
    fi
    _gh_validate_sha "${commit_id}" || return 1

    local event_upper
    case "${event}" in
        approve)         event_upper="APPROVE" ;;
        request_changes) event_upper="REQUEST_CHANGES" ;;
        comment)         event_upper="COMMENT" ;;
    esac

    local review_body
    review_body=$(jq -n \
        --arg commit_id "${commit_id}" \
        --arg event "${event_upper}" \
        --arg body "${body}" \
        --argjson comments "${comments_json}" \
        '{commit_id: $commit_id, event: $event, body: $body, comments: $comments}
         | if .body == "" then del(.body) else . end')

    local -a cmd=("gh" "api" "repos/${effective_repo}/pulls/${number}/reviews" "-X" "POST" "--input" "-")

    log "INFO" "pr_review_submit (batched): ${cmd[*]}"
    local __raw __exit=0
    if [[ "${suppress_errors}" == "true" ]]; then
        __raw=$(printf '%s' "${review_body}" | "${cmd[@]}" 2>/dev/null) || __exit=$?
    else
        __raw=$(printf '%s' "${review_body}" | "${cmd[@]}" 2>&1) || __exit=$?
    fi
    if [[ ${__exit} -ne 0 ]]; then
        [[ -n "${fallback}" ]] && { echo "${fallback}"; return 0; }
        [[ "${suppress_errors}" == "true" ]] || echo "${__raw}"; return ${__exit}
    fi
    echo "${__raw}"
}

# Add a general comment to a pull request.
# Maps to: gh pr comment <number> --body ... [--repo ...]
tool_pr_comment() {
    local args="$1"

    local number body repo suppress_errors fallback
    number=$(echo "${args}" | jq -r '.number // empty')
    body=$(echo "${args}" | jq -r '.body // empty')
    repo=$(echo "${args}" | jq -r '.repo // empty')
    suppress_errors=$(echo "${args}" | jq -r '.suppress_errors // false')
    fallback=$(echo "${args}" | jq -r '.fallback // empty')

    if [[ -z "${number}" ]]; then
        echo "Error: number is required for pr_comment"
        return 1
    fi
    _gh_validate_number "${number}" "number" || return 1

    if [[ -z "${body}" ]]; then
        echo "Error: body is required for pr_comment"
        return 1
    fi

    local effective_repo
    effective_repo=$(_gh_resolve_repo "${repo}")

    local -a cmd=("gh" "pr" "comment" "${number}" "--body" "${body}")

    if [[ -n "${effective_repo}" ]]; then
        _gh_validate_repo "${effective_repo}" || return 1
        cmd+=("--repo" "${effective_repo}")
    fi

    log "INFO" "pr_comment: ${cmd[*]}"
    local __raw __exit=0
    if [[ "${suppress_errors}" == "true" ]]; then
        __raw=$("${cmd[@]}" 2>/dev/null) || __exit=$?
    else
        __raw=$("${cmd[@]}" 2>&1) || __exit=$?
    fi
    if [[ ${__exit} -ne 0 ]]; then
        [[ -n "${fallback}" ]] && { echo "${fallback}"; return 0; }
        [[ "${suppress_errors}" == "true" ]] || echo "${__raw}"; return ${__exit}
    fi
    echo "${__raw}"
}

# Reply to an existing review comment thread.
# Maps to: POST /repos/{owner}/{repo}/pulls/{number}/comments/{comment_id}/replies
tool_pr_review_reply() {
    local args="$1"

    local number comment_id body repo suppress_errors fallback
    number=$(echo "${args}" | jq -r '.number // empty')
    comment_id=$(echo "${args}" | jq -r '.comment_id // empty')
    body=$(echo "${args}" | jq -r '.body // empty')
    repo=$(echo "${args}" | jq -r '.repo // empty')
    suppress_errors=$(echo "${args}" | jq -r '.suppress_errors // false')
    fallback=$(echo "${args}" | jq -r '.fallback // empty')

    if [[ -z "${number}" ]]; then
        echo "Error: number is required for pr_review_reply"
        return 1
    fi
    _gh_validate_number "${number}" "number" || return 1

    if [[ -z "${comment_id}" ]]; then
        echo "Error: comment_id is required for pr_review_reply"
        return 1
    fi
    _gh_validate_number "${comment_id}" "comment_id" || return 1

    if [[ -z "${body}" ]]; then
        echo "Error: body is required for pr_review_reply"
        return 1
    fi

    local effective_repo
    effective_repo=$(_gh_resolve_repo "${repo}")
    _gh_require_repo "${effective_repo}" || return 1
    _gh_validate_repo "${effective_repo}" || return 1

    local endpoint="repos/${effective_repo}/pulls/${number}/comments/${comment_id}/replies"
    local -a cmd=("gh" "api" "${endpoint}" "-X" "POST" "-f" "body=${body}")

    log "INFO" "pr_review_reply: ${cmd[*]}"
    local __raw __exit=0
    if [[ "${suppress_errors}" == "true" ]]; then
        __raw=$("${cmd[@]}" 2>/dev/null) || __exit=$?
    else
        __raw=$("${cmd[@]}" 2>&1) || __exit=$?
    fi
    if [[ ${__exit} -ne 0 ]]; then
        [[ -n "${fallback}" ]] && { echo "${fallback}"; return 0; }
        [[ "${suppress_errors}" == "true" ]] || echo "${__raw}"; return ${__exit}
    fi
    echo "${__raw}"
}

#######################################
# Run one gh command for comment_edit and hand back stdout, stderr, and the
# exit status. Every gh call of the tool goes through here, so a failed call
# is described one way. stdout and stderr stay apart, so a warning on a
# successful call never joins the value.
# Arguments:
#   $1 name of the caller's variable that receives stdout on success and the
#      problem text on failure,
#   $2 name of the caller's variable that receives stderr,
#   $3... the gh command and its arguments.
# Outputs:
#   Nothing on stdout; the results go to the variables named by $1 and $2.
# Returns:
#   0 on success; otherwise gh's exit status. The problem text is gh's
#   stderr, else its stdout (gh api prints an HTTP error's JSON body there),
#   else "gh failed with exit N and no output".
#######################################
_comment_edit_gh() {
    local __ceh_var="$1" __ceh_err_var="$2"
    shift 2
    local __ceh_out __ceh_err __ceh_exit=0

    _gh_capture_split __ceh_out __ceh_err "$@" || __ceh_exit=$?
    printf -v "${__ceh_err_var}" '%s' "${__ceh_err}"
    if [[ ${__ceh_exit} -ne 0 ]]; then
        printf -v "${__ceh_var}" '%s' "${__ceh_err:-${__ceh_out:-gh failed with exit ${__ceh_exit} and no output}}"
        return "${__ceh_exit}"
    fi
    printf -v "${__ceh_var}" '%s' "${__ceh_out}"
}

#######################################
# Run one gh api graphql call for comment_edit and classify the result. On top
# of _comment_edit_gh, an empty stdout, an `errors` field, or stdout that is
# not JSON each count as a failure. stdout alone is parsed; stderr only
# explains a failed call, so a warning on a successful call never fails it.
# Arguments:
#   $1 name of the caller's variable that receives the result,
#   $2... the gh command and its arguments.
# Outputs:
#   Nothing on stdout; the result goes to the variable named by $1.
# Returns:
#   0 with the response JSON in the variable. Otherwise gh's exit status (1
#   when gh exited 0) with the problem text in the variable.
#######################################
_comment_edit_graphql() {
    local __ceg_var="$1"
    shift
    local __ceg_out __ceg_err __ceg_exit=0 __ceg_problem=""

    _comment_edit_gh __ceg_out __ceg_err "$@" || __ceg_exit=$?
    if [[ ${__ceg_exit} -ne 0 ]]; then
        __ceg_problem="${__ceg_out}"
    elif [[ -z "${__ceg_out}" ]]; then
        __ceg_problem="GitHub returned no output"
    elif ! __ceg_problem=$(printf '%s' "${__ceg_out}" | jq -r 'if (.errors // empty) then "GraphQL errors: \(.errors | tostring)" else empty end' 2>/dev/null); then
        __ceg_problem="unparseable response: ${__ceg_out}"
    fi

    if [[ -n "${__ceg_problem}" ]]; then
        [[ ${__ceg_exit} -ne 0 ]] || __ceg_exit=1
        printf -v "${__ceg_var}" '%s' "${__ceg_problem}"
        return "${__ceg_exit}"
    fi
    printf -v "${__ceg_var}" '%s' "${__ceg_out}"
}

#######################################
# Find a comment in the pending reviews of a PR and return its GraphQL node ID.
# Every pending review the lookup returns is searched; GitHub refuses to edit
# another user's comment, and that refusal comes back as the mutation's error.
# The first 100 comments of each review come with the lookup. When none of them
# matches, the comments of the first review with more are read page by page,
# up to 50 pages in all (5,000 comments). A page that reports more but gives no
# cursor counts as the last one. fullDatabaseId is a BigInt that GitHub
# serializes as a string. One jq program reads each response and prints
# "found", a tab, and the node ID; or "more", a tab, the cursor, and (lookup
# only) a tab and the review ID; or "end". A response without the nodes the
# program iterates makes jq fail.
# Arguments:
#   $1 name of the caller's variable that receives the result,
#   $2 repository in owner/repo format,
#   $3 PR number,
#   $4 database ID of the comment.
# Outputs:
#   Nothing on stdout; the result goes to the variable named by $1.
# Returns:
#   0 with the node ID in the variable. Otherwise gh's exit status, or 1 when
#   the failure did not come from a gh exit, with the problem text in the
#   variable.
#######################################
_comment_edit_find_pending() {
    local __cfp_var="$1" __cfp_repo="$2" __cfp_number="$3" __cfp_id="$4"
    local __cfp_resp __cfp_row __cfp_exit=0 __cfp_page=1 __cfp_max_pages=50
    local kind value review_id

    # shellcheck disable=SC2016  # jq variable ($id), not a shell var
    local lookup_jq='
        .data.repository.pullRequest.reviews.nodes as $reviews
        | ([$reviews[] | .comments.nodes[] | select(.fullDatabaseId == $id) | .id][0]) as $found
        | ([$reviews[] | select(.comments.pageInfo.hasNextPage == true and .comments.pageInfo.endCursor != null)][0]) as $more
        | if $found then "found\t\($found)"
          elif $more then "more\t\($more.comments.pageInfo.endCursor)\t\($more.id)"
          else "end" end'
    # shellcheck disable=SC2016  # jq variable ($id), not a shell var
    local page_jq='
        .data.node.comments as $c
        | ([$c.nodes[] | select(.fullDatabaseId == $id) | .id][0]) as $found
        | if $found then "found\t\($found)"
          elif $c.pageInfo.hasNextPage == true and $c.pageInfo.endCursor != null then "more\t\($c.pageInfo.endCursor)"
          else "end" end'

    _comment_edit_graphql __cfp_resp gh api graphql \
        -f "query=query(\$owner: String!, \$name: String!, \$number: Int!) { repository(owner: \$owner, name: \$name) { pullRequest(number: \$number) { reviews(states: [PENDING], first: 100) { nodes { id comments(first: 100) { nodes { id fullDatabaseId } pageInfo { hasNextPage endCursor } } } } } } }" \
        -f "owner=${__cfp_repo%%/*}" -f "name=${__cfp_repo##*/}" -F "number=${__cfp_number}" || __cfp_exit=$?
    if [[ ${__cfp_exit} -ne 0 ]]; then
        printf -v "${__cfp_var}" '%s' "${__cfp_resp}"
        return "${__cfp_exit}"
    fi
    if ! __cfp_row=$(printf '%s' "${__cfp_resp}" | jq -r --arg id "${__cfp_id}" "${lookup_jq}" 2>/dev/null); then
        printf -v "${__cfp_var}" '%s' "unexpected response from GitHub for the pending reviews"
        return 1
    fi
    IFS=$'\t' read -r kind value review_id <<< "${__cfp_row}"

    while [[ "${kind}" == "more" ]]; do
        if [[ ${__cfp_page} -ge ${__cfp_max_pages} ]]; then
            printf -v "${__cfp_var}" '%s' "reached the limit of ${__cfp_max_pages} comment pages without finding comment ${__cfp_id}"
            return 1
        fi
        __cfp_page=$((__cfp_page + 1))
        log "INFO" "comment_edit: next page of comments in pending review ${review_id}"
        __cfp_exit=0
        _comment_edit_graphql __cfp_resp gh api graphql \
            -f "query=query(\$reviewId: ID!, \$cursor: String!) { node(id: \$reviewId) { ... on PullRequestReview { comments(first: 100, after: \$cursor) { nodes { id fullDatabaseId } pageInfo { hasNextPage endCursor } } } } }" \
            -f "reviewId=${review_id}" -f "cursor=${value}" || __cfp_exit=$?
        if [[ ${__cfp_exit} -ne 0 ]]; then
            printf -v "${__cfp_var}" '%s' "reading the next comments of your pending review failed: ${__cfp_resp}"
            return "${__cfp_exit}"
        fi
        if ! __cfp_row=$(printf '%s' "${__cfp_resp}" | jq -r --arg id "${__cfp_id}" "${page_jq}" 2>/dev/null); then
            printf -v "${__cfp_var}" '%s' "unexpected response from GitHub for comment page ${__cfp_page} of your pending review"
            return 1
        fi
        IFS=$'\t' read -r kind value <<< "${__cfp_row}"
    done

    if [[ "${kind}" != "found" ]]; then
        printf -v "${__cfp_var}" '%s' "no matching comment in your pending review"
        return 1
    fi
    printf -v "${__cfp_var}" '%s' "${value}"
}

#######################################
# Refuse to edit a comment somebody else wrote. GitHub answers whether the
# authenticated user wrote it: the comment's node_id, from the response of the
# read that precedes the write, goes into one GraphQL query for viewerDidAuthor
# (IssueComment, PullRequestReviewComment, and PullRequestReview all implement
# the Comment interface). The login in the read's response only names the
# author in the refusal.
# Arguments:
#   $1 response of the GET of the comment or review summary,
#   $2 the GET's endpoint, for the message.
# Outputs:
#   An "Error: ..." message on stdout when the node ID is missing, the query
#   fails, or the answer is not exactly true.
# Returns:
#   0 when the caller wrote it; otherwise gh's exit status from the query, or 1.
#######################################
_comment_edit_check_author() {
    local response="$1" endpoint="$2"
    local node_id author author_out author_exit=0

    if ! node_id=$(printf '%s' "${response}" | jq -r '.node_id // empty' 2>/dev/null) || [[ -z "${node_id}" ]]; then
        echo "Error: comment_edit: unexpected response from GitHub for GET ${endpoint}"
        return 1
    fi

    log "INFO" "comment_edit: asking whether you wrote ${node_id}"
    # shellcheck disable=SC2016  # GraphQL variable ($id), not a shell var
    _comment_edit_graphql author_out gh api graphql \
        -f 'query=query($id: ID!) { node(id: $id) { ... on Comment { viewerDidAuthor } } }' \
        -f "id=${node_id}" || author_exit=$?
    if [[ ${author_exit} -ne 0 ]]; then
        echo "Error: comment_edit: asking whether you wrote the comment failed: ${author_out}; nothing was edited"
        return "${author_exit}"
    fi
    if ! printf '%s' "${author_out}" | jq -e '.data.node.viewerDidAuthor == true' >/dev/null 2>&1; then
        author=$(printf '%s' "${response}" | jq -r '.user | objects | .login | strings')
        echo "Error: comment_edit: the comment was written by ${author:-a deleted user}, not by you; nothing was edited. Pass allow_other_author: true to edit it"
        return 1
    fi
}

#######################################
# Edit an inline comment that the REST API reported as 404 and that may sit in
# the caller's own pending review: find it there, then edit it through the
# updatePullRequestReviewComment mutation. No author check runs: GitHub refuses
# to edit another user's comment, and that refusal is the mutation's error.
# Every error starts with the 404 statement.
# Arguments:
#   $1 repository in owner/repo format,
#   $2 PR number,
#   $3 database ID of the comment,
#   $4 new body,
#   $5 the statement that the REST read returned 404.
# Outputs:
#   The edited comment's URL on success, otherwise an "Error: ..." message.
# Returns:
#   0 when the comment was edited; otherwise gh's exit status, or 1 when the
#   failure did not come from a gh exit.
#######################################
_comment_edit_pending_edit() {
    local repo="$1" number="$2" comment_id="$3" body="$4" not_found_note="$5"
    local pending_node_id mutation mutation_url __exit=0

    log "INFO" "comment_edit: pending-review lookup for comment ${comment_id} on PR ${number}"
    _comment_edit_find_pending pending_node_id "${repo}" "${number}" "${comment_id}" || __exit=$?
    if [[ ${__exit} -ne 0 ]]; then
        echo "Error: comment_edit: ${not_found_note}; pending-review lookup on PR ${number}: ${pending_node_id}"
        return "${__exit}"
    fi

    log "INFO" "comment_edit: pending-review mutation for ${pending_node_id}"
    _comment_edit_graphql mutation gh api graphql \
        -f "query=mutation(\$id: ID!, \$body: String!) { updatePullRequestReviewComment(input: {pullRequestReviewCommentId: \$id, body: \$body}) { pullRequestReviewComment { url } } }" \
        -f "id=${pending_node_id}" -f "body=${body}" || __exit=$?
    if [[ ${__exit} -ne 0 ]]; then
        echo "Error: comment_edit: ${not_found_note}; pending-review comment edit failed: ${mutation}"
        return "${__exit}"
    fi
    mutation_url=$(printf '%s' "${mutation}" | jq -r '.data.updatePullRequestReviewComment.pullRequestReviewComment.url // empty' 2>/dev/null || true)
    if [[ -z "${mutation_url}" ]]; then
        echo "Error: comment_edit: ${not_found_note}; the pending-review edit was sent and GitHub reported success but returned no URL, so the comment may already hold the new body: ${mutation}"
        return 1
    fi
    echo "${mutation_url}"
}

#######################################
# Replace the body of one existing comment: an issue or PR conversation
# comment, an inline review comment (including one in the caller's own pending
# review), or a review summary. Commit comments and Discussions comments are
# not supported. The kind comes from the anchor of the URL; REFERENCE.md lists
# the accepted URL forms. A URL that matches none fails before any gh call. The
# comment is read first. A conversation or inline comment is edited only when
# it belongs to the issue or PR number in the URL. Unless allow_other_author is
# true, the edit also needs the comment's author to be the caller. An inline
# comment the REST API reports as 404 may sit in the caller's own pending
# review, so it is looked up there, page by page, and edited through GraphQL;
# no author check runs there, because GitHub refuses to edit another user's
# comment. When that lookup fails or finds nothing, the error states the 404
# and the lookup's result. Every other failure ends the call without a write.
# Arguments:
#   $1 JSON arguments: url (required), body (required), allow_other_author
#      (optional boolean, default false).
# Outputs:
#   The edited comment's URL on success, otherwise an "Error: ..." message.
# Returns:
#   0 when the comment was edited; otherwise gh's exit status, or 1 when the
#   failure did not come from a gh exit.
#######################################
tool_comment_edit() {
    local args="$1"

    local url body allow_other_author
    url=$(echo "${args}" | jq -r '.url // empty')
    body=$(echo "${args}" | jq -r '.body // empty')
    allow_other_author=$(echo "${args}" | jq -r '.allow_other_author // false')

    if [[ -z "${url}" ]]; then
        echo "Error: url is required for comment_edit"
        return 1
    fi

    if [[ -z "${body}" ]]; then
        echo "Error: body is required for comment_edit"
        return 1
    fi

    # The scheme and host match without regard to case; the path keeps its case.
    local rest="${url}" prefix
    for prefix in "https://github.com/" "http://github.com/" "https://www.github.com/"; do
        if [[ "${rest,,}" == "${prefix}"* ]]; then
            rest="${rest:${#prefix}}"
            break
        fi
    done

    if [[ "${rest}" =~ ^[A-Za-z][A-Za-z0-9+.-]*:// ]]; then
        echo "Error: url must be a github.com URL, got: '${url}'"
        return 1
    fi

    # Owners may contain "_" (Enterprise Managed User accounts). A "?query"
    # before the "#" is dropped.
    local sha='[0-9a-fA-F]{7,40}'
    local form_error="Error: url must be OWNER/REPO/issues/N#issuecomment-ID, OWNER/REPO/pull/N#issuecomment-ID, OWNER/REPO/pull/N#discussion_rID, OWNER/REPO/pull/N/files#rID, OWNER/REPO/pull/N/changes#rID, OWNER/REPO/pull/N/files/SHA#rID, OWNER/REPO/pull/N/files/SHA..SHA#rID, OWNER/REPO/pull/N/changes/SHA#rID, OWNER/REPO/pull/N/changes/SHA..SHA#rID, OWNER/REPO/pull/N/commits/SHA#rID, or OWNER/REPO/pull/N#pullrequestreview-ID (SHA is 7 to 40 hex characters; optionally with a leading https://github.com/ and a ?query before the #), got: '${url}'"
    local url_re="^([A-Za-z0-9_-]+/[A-Za-z0-9_.-]+)/(issues|pull)/([0-9]+)(/files|/changes|/files/${sha}\\.\\.${sha}|/files/${sha}|/changes/${sha}\\.\\.${sha}|/changes/${sha}|/commits/${sha})?(\\?[^#]*)?#([A-Za-z0-9_-]+)\$"
    if [[ ! "${rest}" =~ ${url_re} ]]; then
        echo "${form_error}"
        return 1
    fi
    local repo="${BASH_REMATCH[1]}" kind="${BASH_REMATCH[2]}" number="${BASH_REMATCH[3]}"
    local suffix="${BASH_REMATCH[4]}" anchor="${BASH_REMATCH[6]}"
    # A repo named "." or ".." would let repos/OWNER/../... resolve to another endpoint.
    if [[ "${repo##*/}" == "." || "${repo##*/}" == ".." ]]; then
        echo "${form_error}"
        return 1
    fi

    # owner_field names the field of the GET response that holds the issue or
    # PR the comment belongs to; owner_path is how that URL must end. A review
    # summary has neither: its endpoint already carries the PR number.
    local endpoint method owner_field="" owner_path="" review_comment_id=""
    if [[ "${anchor}" =~ ^issuecomment-([0-9]+)$ && -z "${suffix}" ]]; then
        endpoint="repos/${repo}/issues/comments/${BASH_REMATCH[1]}"
        method="PATCH"
        owner_field="issue_url"
        owner_path="issues/${number}"
    elif [[ "${kind}" == "pull" ]] && { [[ -z "${suffix}" && "${anchor}" =~ ^discussion_r([0-9]+)$ ]] || [[ -n "${suffix}" && "${anchor}" =~ ^r([0-9]+)$ ]]; }; then
        endpoint="repos/${repo}/pulls/comments/${BASH_REMATCH[1]}"
        method="PATCH"
        owner_field="pull_request_url"
        owner_path="pulls/${number}"
        review_comment_id="${BASH_REMATCH[1]}"
    elif [[ "${kind}" == "pull" && -z "${suffix}" && "${anchor}" =~ ^pullrequestreview-([0-9]+)$ ]]; then
        endpoint="repos/${repo}/pulls/${number}/reviews/${BASH_REMATCH[1]}"
        method="PUT"
    else
        echo "${form_error}"
        return 1
    fi

    local __out __err __exit=0

    log "INFO" "comment_edit: GET ${endpoint}"
    _comment_edit_gh __out __err gh api "${endpoint}" || __exit=$?
    if [[ ${__exit} -ne 0 ]]; then
        # Only an inline comment can still be edited: REST answers 404 for a
        # comment inside the caller's unsubmitted review.
        if [[ -n "${review_comment_id}" && "${__err}" == *"(HTTP 404)"* ]]; then
            _comment_edit_pending_edit "${repo}" "${number}" "${review_comment_id}" "${body}" \
                "GET ${endpoint} returned 404 (not found, or no access to the repository)"
            return $?
        fi
        echo "Error: comment_edit: GET ${endpoint} failed: ${__out}"
        return "${__exit}"
    fi

    if [[ -n "${owner_field}" ]]; then
        local owner_url
        if ! owner_url=$(printf '%s' "${__out}" | jq -r --arg field "${owner_field}" '.[$field] // empty' 2>/dev/null) || [[ -z "${owner_url}" ]]; then
            echo "Error: comment_edit: GET ${endpoint} returned no ${owner_field}; nothing was edited"
            return 1
        fi
        if [[ "${owner_url}" != */"${owner_path}" ]]; then
            echo "Error: comment_edit: the comment belongs to #${owner_url##*/}, not to #${number} named in the URL; nothing was edited"
            return 1
        fi
    fi
    if [[ "${allow_other_author}" != "true" ]]; then
        _comment_edit_check_author "${__out}" "${endpoint}" || return $?
    fi

    log "INFO" "comment_edit: ${method} ${endpoint}"
    _comment_edit_gh __out __err gh api "${endpoint}" -X "${method}" -f "body=${body}" --jq ".html_url // empty" || __exit=$?
    if [[ ${__exit} -ne 0 ]]; then
        echo "Error: comment_edit: ${method} ${endpoint} failed: ${__out}"
        return "${__exit}"
    fi
    if [[ -z "${__out}" ]]; then
        echo "Error: comment_edit: ${method} ${endpoint} was sent and GitHub reported success but returned no URL, so the comment may already hold the new body"
        return 1
    fi
    echo "${__out}"
}
