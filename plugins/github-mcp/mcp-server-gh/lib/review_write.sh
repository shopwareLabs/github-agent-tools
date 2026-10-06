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

# Replace the body of one existing comment, whatever its kind. The kind comes
# from the URL anchor, and a URL that matches none of the forms below fails
# before any gh call:
#   OWNER/REPO/issues/N#issuecomment-ID        → PATCH repos/O/R/issues/comments/ID
#   OWNER/REPO/pull/N#issuecomment-ID          → PATCH repos/O/R/issues/comments/ID
#   OWNER/REPO/pull/N#discussion_rID           → PATCH repos/O/R/pulls/comments/ID
#   OWNER/REPO/pull/N/files|changes#rID        → PATCH repos/O/R/pulls/comments/ID
#   OWNER/REPO/pull/N#pullrequestreview-ID     → PUT   repos/O/R/pulls/N/reviews/ID
# For the two review-comment forms, the caller's own pending (unsubmitted)
# review is looked up first, because REST answers 404 for a comment inside it.
# A match is edited with the updatePullRequestReviewComment GraphQL mutation;
# no match falls through to the PATCH above. A failed lookup, a failed
# mutation, or a pending review of more than 100 comments with no match is an
# error and makes no further call.
# A leading https://github.com/, http://github.com/, or https://www.github.com/
# is stripped; any other scheme or host is rejected.
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

    local endpoint method review_comment_id=""
    if [[ "${anchor}" =~ ^issuecomment-([0-9]+)$ && -z "${suffix}" ]]; then
        endpoint="repos/${repo}/issues/comments/${BASH_REMATCH[1]}"
        method="PATCH"
    elif [[ "${kind}" == "pull" && -z "${suffix}" && "${anchor}" =~ ^discussion_r([0-9]+)$ ]]; then
        endpoint="repos/${repo}/pulls/comments/${BASH_REMATCH[1]}"
        method="PATCH"
        review_comment_id="${BASH_REMATCH[1]}"
    elif [[ "${kind}" == "pull" && -n "${suffix}" && "${anchor}" =~ ^r([0-9]+)$ ]]; then
        endpoint="repos/${repo}/pulls/comments/${BASH_REMATCH[1]}"
        method="PATCH"
        review_comment_id="${BASH_REMATCH[1]}"
    elif [[ "${kind}" == "pull" && -z "${suffix}" && "${anchor}" =~ ^pullrequestreview-([0-9]+)$ ]]; then
        endpoint="repos/${repo}/pulls/${number}/reviews/${BASH_REMATCH[1]}"
        method="PUT"
    else
        echo "${form_error}"
        return 1
    fi

    local __raw __exit=0

    if [[ -n "${review_comment_id}" ]]; then
        local owner="${repo%%/*}" name="${repo##*/}"
        local -a lookup_cmd=("gh" "api" "graphql"
            "-f" "query=query(\$owner: String!, \$name: String!, \$number: Int!) { repository(owner: \$owner, name: \$name) { pullRequest(number: \$number) { reviews(states: [PENDING], first: 1) { nodes { comments(first: 100) { nodes { id databaseId } pageInfo { hasNextPage } } } } } } }"
            "-f" "owner=${owner}" "-f" "name=${name}" "-F" "number=${number}"
        )

        log "INFO" "comment_edit: pending-review lookup: ${lookup_cmd[*]}"
        __raw=$("${lookup_cmd[@]}" 2>&1) || __exit=$?
        local lookup_error=""
        if [[ ${__exit} -ne 0 ]]; then
            lookup_error="${__raw:-gh api graphql failed with exit ${__exit} and no output}"
        elif [[ -z "${__raw}" ]]; then
            lookup_error="GitHub returned no output"
        elif ! lookup_error=$(printf '%s' "${__raw}" | jq -r 'if (.errors // empty) then "GraphQL errors: \(.errors | tostring)" elif (.data.repository.pullRequest | type) != "object" then "response has no pull request data" else empty end' 2>&1); then
            lookup_error="unparseable response: ${__raw}"
        fi
        if [[ -n "${lookup_error}" || ${__exit} -ne 0 ]]; then
            [[ "${__exit}" -ne 0 ]] || __exit=1
            echo "Error: pending-review lookup failed: ${lookup_error}"
            return ${__exit}
        fi

        local node_id has_next
        node_id=$(printf '%s' "${__raw}" | jq -r --argjson id "${review_comment_id}" \
            '[.data.repository.pullRequest.reviews.nodes[0].comments.nodes[]? | select(.databaseId == $id) | .id][0] // empty')
        has_next=$(printf '%s' "${__raw}" | jq -r '.data.repository.pullRequest.reviews.nodes[0].comments.pageInfo.hasNextPage // false')

        if [[ -n "${node_id}" ]]; then
            local -a mutation_cmd=("gh" "api" "graphql"
                "-f" "query=mutation(\$id: ID!, \$body: String!) { updatePullRequestReviewComment(input: {pullRequestReviewCommentId: \$id, body: \$body}) { pullRequestReviewComment { url } } }"
                "-f" "id=${node_id}" "-f" "body=${body}"
            )
            log "INFO" "comment_edit: pending-review mutation: ${mutation_cmd[*]}"
            __exit=0
            __raw=$("${mutation_cmd[@]}" 2>&1) || __exit=$?
            local mutation_error="" mutation_url=""
            if [[ ${__exit} -ne 0 ]]; then
                mutation_error="${__raw:-gh api graphql failed with exit ${__exit} and no output}"
            elif [[ -z "${__raw}" ]]; then
                mutation_error="GitHub returned no URL for the edited comment"
            elif ! mutation_error=$(printf '%s' "${__raw}" | jq -r 'if (.errors // empty) then "GraphQL errors: \(.errors | tostring)" else empty end' 2>&1); then
                mutation_error="unparseable response: ${__raw}"
            elif [[ -z "${mutation_error}" ]]; then
                mutation_url=$(printf '%s' "${__raw}" | jq -r '.data.updatePullRequestReviewComment.pullRequestReviewComment.url // empty')
                [[ -n "${mutation_url}" && "${mutation_url}" != "null" ]] || mutation_error="GitHub returned no URL for the edited comment: ${__raw}"
            fi
            if [[ -n "${mutation_error}" ]]; then
                [[ "${__exit}" -ne 0 ]] || __exit=1
                echo "Error: pending-review comment edit failed: ${mutation_error}"
                return ${__exit}
            fi
            echo "${mutation_url}"
            return 0
        fi

        if [[ "${has_next}" == "true" ]]; then
            echo "Error: the pending review has more than 100 comments and comment ${review_comment_id} could not be located"
            return 1
        fi
        __exit=0
    fi

    local -a cmd=("gh" "api" "${endpoint}" "-X" "${method}" "-f" "body=${body}" "--jq" ".html_url // empty")

    log "INFO" "comment_edit: ${cmd[*]}"
    __raw=$("${cmd[@]}" 2>&1) || __exit=$?
    if [[ ${__exit} -ne 0 ]]; then
        echo "${__raw:-comment_edit: gh api ${endpoint} failed with exit ${__exit} and no output}"
        return ${__exit}
    fi
    if [[ -z "${__raw}" || "${__raw}" == "null" ]]; then
        echo "Error: comment_edit: GitHub returned no URL for the edited comment"
        return 1
    fi
    echo "${__raw}"
}
