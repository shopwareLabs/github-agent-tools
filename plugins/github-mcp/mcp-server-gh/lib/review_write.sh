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
# Run one gh api graphql call for comment_edit and classify the result. A
# non-zero exit, an empty stdout, an `errors` field, or stdout that is not
# JSON each count as a failure. stdout alone is parsed; stderr only explains a
# failed call, so a warning on a successful call never fails it.
# Arguments:
#   $1 name of the caller's variable that receives the result,
#   $2 label for the error message (for example "pending-review lookup"),
#   $3... the gh command and its arguments.
# Outputs:
#   Nothing on stdout; the result goes to the variable named by $1.
# Returns:
#   0 with the response JSON in the variable. Otherwise gh's exit status (1
#   when gh exited 0) with an "Error: ..." message in the variable.
#######################################
_comment_edit_graphql() {
    local __ceg_var="$1" __ceg_label="$2"
    shift 2
    local __ceg_out __ceg_err __ceg_exit=0 __ceg_problem=""

    _gh_capture_split __ceg_out __ceg_err "$@" || __ceg_exit=$?
    if [[ ${__ceg_exit} -ne 0 ]]; then
        __ceg_problem="${__ceg_err:-${__ceg_out:-gh api graphql failed with exit ${__ceg_exit} and no output}}"
    elif [[ -z "${__ceg_out}" ]]; then
        __ceg_problem="GitHub returned no output"
    elif ! __ceg_problem=$(printf '%s' "${__ceg_out}" | jq -r 'if (.errors // empty) then "GraphQL errors: \(.errors | tostring)" else empty end' 2>/dev/null); then
        __ceg_problem="unparseable response: ${__ceg_out}"
    fi

    if [[ -n "${__ceg_problem}" ]]; then
        [[ ${__ceg_exit} -ne 0 ]] || __ceg_exit=1
        printf -v "${__ceg_var}" '%s' "Error: comment_edit: ${__ceg_label} failed: ${__ceg_problem}"
        return "${__ceg_exit}"
    fi
    printf -v "${__ceg_var}" '%s' "${__ceg_out}"
}

#######################################
# Replace the body of one existing comment, whatever its kind. The kind comes
# from the anchor of the URL; REFERENCE.md lists the accepted URL forms. A URL
# that matches none fails before any gh call. A conversation or inline comment
# is read first and edited only when it belongs to the issue or PR number in
# the URL. An inline comment the REST API reports as 404 may sit in the
# caller's own pending review, so it is looked up there and edited through
# GraphQL. Every other failure ends the call without a write.
# Arguments:
#   $1 JSON arguments: url (required) and body (required).
# Outputs:
#   The edited comment's URL on success, otherwise an "Error: ..." message.
# Returns:
#   0 when the comment was edited; otherwise gh's exit status, or 1 when the
#   failure did not come from a gh exit.
#######################################
tool_comment_edit() {
    local args="$1"

    local url body
    url=$(echo "${args}" | jq -r '.url // empty')
    body=$(echo "${args}" | jq -r '.body // empty')

    if [[ -z "${url}" ]]; then
        echo "Error: url is required for comment_edit"
        return 1
    fi

    if [[ -z "${body}" ]]; then
        echo "Error: body is required for comment_edit"
        return 1
    fi

    local rest="${url}"
    case "${rest}" in
        https://github.com/*)     rest="${rest#https://github.com/}" ;;
        http://github.com/*)      rest="${rest#http://github.com/}" ;;
        https://www.github.com/*) rest="${rest#https://www.github.com/}" ;;
    esac

    if [[ "${rest}" =~ ^[A-Za-z][A-Za-z0-9+.-]*:// ]]; then
        echo "Error: url must be a github.com URL, got: '${url}'"
        return 1
    fi

    local form_error="Error: url must be OWNER/REPO/issues/N#issuecomment-ID, OWNER/REPO/pull/N#issuecomment-ID, OWNER/REPO/pull/N#discussion_rID, OWNER/REPO/pull/N/files#rID, OWNER/REPO/pull/N/changes#rID, or OWNER/REPO/pull/N#pullrequestreview-ID (optionally with a leading https://github.com/), got: '${url}'"
    local url_re='^([A-Za-z0-9-]+/[A-Za-z0-9_.-]+)/(issues|pull)/([0-9]+)(/files|/changes)?#([A-Za-z0-9_-]+)$'
    if [[ ! "${rest}" =~ ${url_re} ]]; then
        echo "${form_error}"
        return 1
    fi
    local repo="${BASH_REMATCH[1]}" kind="${BASH_REMATCH[2]}" number="${BASH_REMATCH[3]}"
    local suffix="${BASH_REMATCH[4]}" anchor="${BASH_REMATCH[5]}"
    if [[ "${repo##*/}" == "." || "${repo##*/}" == ".." || "${repo##*/}" == *.git ]]; then
        echo "${form_error}"
        return 1
    fi

    # owner_field names the field of the GET response that holds the issue or
    # PR the comment belongs to; owner_path is how that URL must end.
    local endpoint method owner_field="" owner_path="" review_comment_id=""
    if [[ "${anchor}" =~ ^issuecomment-([0-9]+)$ && -z "${suffix}" ]]; then
        endpoint="repos/${repo}/issues/comments/${BASH_REMATCH[1]}"
        method="PATCH"
        owner_field="issue_url"
        owner_path="issues/${number}"
    elif [[ "${kind}" == "pull" && -z "${suffix}" && "${anchor}" =~ ^discussion_r([0-9]+)$ ]]; then
        endpoint="repos/${repo}/pulls/comments/${BASH_REMATCH[1]}"
        method="PATCH"
        owner_field="pull_request_url"
        owner_path="pulls/${number}"
        review_comment_id="${BASH_REMATCH[1]}"
    elif [[ "${kind}" == "pull" && -n "${suffix}" && "${anchor}" =~ ^r([0-9]+)$ ]]; then
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
    local in_pending_review=false

    if [[ -n "${owner_field}" ]]; then
        log "INFO" "comment_edit: GET ${endpoint}"
        _gh_capture_split __out __err gh api "${endpoint}" || __exit=$?
        if [[ ${__exit} -ne 0 ]]; then
            # Only an inline comment can still be edited: REST answers 404 for
            # a comment inside the caller's unsubmitted review.
            if [[ -n "${review_comment_id}" && "${__err}" == *"(HTTP 404)"* ]]; then
                in_pending_review=true
                __exit=0
            else
                echo "Error: comment_edit: GET ${endpoint} failed: ${__err:-${__out:-gh exited with status ${__exit} and no output}}"
                return "${__exit}"
            fi
        else
            local owner_url
            if ! owner_url=$(printf '%s' "${__out}" | jq -r --arg field "${owner_field}" '.[$field] // empty' 2>/dev/null) || [[ -z "${owner_url}" ]]; then
                echo "Error: comment_edit: GET ${endpoint} returned no ${owner_field}: ${__out}"
                return 1
            fi
            if [[ "${owner_url}" != */"${owner_path}" ]]; then
                echo "Error: comment_edit: the comment belongs to #${owner_url##*/}, not to #${number} named in the URL; nothing was edited"
                return 1
            fi
        fi
    fi

    if [[ "${in_pending_review}" == "true" ]]; then
        local owner="${repo%%/*}" name="${repo##*/}"
        local lookup
        log "INFO" "comment_edit: pending-review lookup for comment ${review_comment_id} on PR ${number}"
        _comment_edit_graphql lookup "pending-review lookup" gh api graphql \
            -f "query=query(\$owner: String!, \$name: String!, \$number: Int!) { repository(owner: \$owner, name: \$name) { pullRequest(number: \$number) { reviews(states: [PENDING], first: 100) { pageInfo { hasNextPage } nodes { viewerDidAuthor comments(first: 100) { nodes { id fullDatabaseId } pageInfo { hasNextPage } } } } } } }" \
            -f "owner=${owner}" -f "name=${name}" -F "number=${number}" || __exit=$?
        if [[ ${__exit} -ne 0 ]]; then
            echo "${lookup}"
            return "${__exit}"
        fi
        if [[ "$(printf '%s' "${lookup}" | jq -r '.data.repository.pullRequest | type')" != "object" ]]; then
            echo "Error: comment_edit: pending-review lookup failed: response has no pull request data: ${lookup}"
            return 1
        fi

        # Only the caller's own pending review counts; GitHub allows one per PR.
        # fullDatabaseId is a BigInt that GitHub serializes as a string.
        local node_id has_next reviews_next own_count
        own_count=$(printf '%s' "${lookup}" | jq -r '[.data.repository.pullRequest.reviews.nodes[]? | select(.viewerDidAuthor == true)] | length')
        reviews_next=$(printf '%s' "${lookup}" | jq -r '.data.repository.pullRequest.reviews.pageInfo.hasNextPage // false')
        if [[ "${own_count}" == "0" && "${reviews_next}" == "true" ]]; then
            echo "Error: comment_edit: comment ${review_comment_id} is not a submitted review comment on ${repo}, and your pending review on PR ${number} could not be located among more than 100 pending reviews"
            return 1
        fi
        node_id=$(printf '%s' "${lookup}" | jq -r --arg id "${review_comment_id}" \
            '[.data.repository.pullRequest.reviews.nodes[]? | select(.viewerDidAuthor == true) | .comments.nodes[]? | select(.fullDatabaseId == $id) | .id][0] // empty')
        has_next=$(printf '%s' "${lookup}" | jq -r '[.data.repository.pullRequest.reviews.nodes[]? | select(.viewerDidAuthor == true) | .comments.pageInfo.hasNextPage][0] // false')

        if [[ -z "${node_id}" ]]; then
            if [[ "${has_next}" == "true" ]]; then
                echo "Error: comment_edit: comment ${review_comment_id} is not a submitted review comment on ${repo}, and your pending review on PR ${number} has more than 100 comments, so it could not be searched in full"
                return 1
            fi
            echo "Error: comment_edit: comment ${review_comment_id} is not a submitted review comment on ${repo}, and it is not in your pending review on PR ${number}"
            return 1
        fi

        local mutation mutation_url
        log "INFO" "comment_edit: pending-review mutation for ${node_id}"
        _comment_edit_graphql mutation "pending-review comment edit" gh api graphql \
            -f "query=mutation(\$id: ID!, \$body: String!) { updatePullRequestReviewComment(input: {pullRequestReviewCommentId: \$id, body: \$body}) { pullRequestReviewComment { url } } }" \
            -f "id=${node_id}" -f "body=${body}" || __exit=$?
        if [[ ${__exit} -ne 0 ]]; then
            echo "${mutation}"
            return "${__exit}"
        fi
        mutation_url=$(printf '%s' "${mutation}" | jq -r '.data.updatePullRequestReviewComment.pullRequestReviewComment.url // empty')
        if [[ -z "${mutation_url}" ]]; then
            echo "Error: comment_edit: pending-review comment edit failed: GitHub returned no URL for the edited comment: ${mutation}"
            return 1
        fi
        echo "${mutation_url}"
        return 0
    fi

    log "INFO" "comment_edit: ${method} ${endpoint}"
    _gh_capture_split __out __err gh api "${endpoint}" -X "${method}" -f "body=${body}" --jq ".html_url // empty" || __exit=$?
    if [[ ${__exit} -ne 0 ]]; then
        echo "Error: comment_edit: ${method} ${endpoint} failed: ${__err:-${__out:-gh exited with status ${__exit} and no output}}"
        return "${__exit}"
    fi
    if [[ -z "${__out}" || "${__out}" == "null" ]]; then
        echo "Error: comment_edit: GitHub returned no URL for the edited comment"
        return 1
    fi
    echo "${__out}"
}
