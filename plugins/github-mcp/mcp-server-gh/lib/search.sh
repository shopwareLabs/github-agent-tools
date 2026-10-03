#!/usr/bin/env bash
# Search tools for gh-tooling MCP server
# Tools: search, search_code, search_repos, search_commits, search_discussions

#######################################
# Split a search expression into the keyword arguments gh search expects.
# gh quotes each argument that contains whitespace, so the whole expression
# passed as one argument would become a single phrase. Splits on spaces, tabs,
# and newlines; a double-quoted span stays in the term it belongs to, with its
# quotes removed and its whitespace collapsed to single spaces, so gh quotes it
# again: '"exact phrase"' -> 'exact phrase', 'label:"good first issue"' ->
# 'label:good first issue'.
# gh re-quotes only a term that contains whitespace, and reads the text before a
# term's first ':' as a qualifier name. So '-"exact phrase"' becomes the phrase
# '-exact phrase' rather than its negation, '"OR"' becomes the operator OR, and
# '"error: timeout"' does not reach GitHub as that phrase; gh has no argument
# form for any of them.
# Callers pass the terms after "--", so a term starting with '-' (-label:bug)
# is not read as a gh flag.
# Built on read's field splitting rather than a per-character loop, which takes
# quadratic time in bash.
# Globals:
#   _GH_SEARCH_TERMS (set)
# Arguments:
#   $1 search expression,
#   $2 tool name, for error messages,
#   $3 "required" to fail when no term remains, "optional" to allow none.
# Outputs:
#   An error message on stdout on failure.
# Returns:
#   0 on success, 1 on an unbalanced double quote, a unit separator (U+001F)
#   in the expression, or no term in required mode.
#######################################
_gh_split_search_terms() {
    local search="$1" tool_name="$2" mode="$3"
    local ws=$' \t\n' us=$'\x1f'
    _GH_SEARCH_TERMS=()

    if [[ "${mode}" != "required" && "${mode}" != "optional" ]]; then
        echo "Error: _gh_split_search_terms mode must be 'required' or 'optional', got: '${mode}'"
        return 1
    fi
    if [[ "${search}" == *"${us}"* ]]; then
        echo "Error: search for ${tool_name} contains a unit separator (U+001F): '${search}'"
        return 1
    fi

    # Fields at odd indexes were inside quotes. The appended quote terminates the
    # last field; the field after it holds only the here-string's newline.
    local -a parts words
    IFS='"' read -r -d '' -a parts <<< "${search}\"" || true
    unset 'parts[${#parts[@]}-1]'
    if (( ${#parts[@]} % 2 == 0 )); then
        echo "Error: search for ${tool_name} has an unbalanced double quote: '${search}'"
        return 1
    fi

    # A quoted span's words are joined with the unit separator, so the split
    # below keeps the span in one term; the separator becomes a space after.
    local flat="" phrase i
    for (( i = 0; i < ${#parts[@]}; i++ )); do
        if (( i % 2 == 0 )); then
            flat+="${parts[i]}"
            continue
        fi
        IFS="${ws}" read -r -d '' -a words <<< "${parts[i]}" || true
        if (( ${#words[@]} > 0 )); then
            printf -v phrase "%s${us}" "${words[@]}"
            flat+="${phrase%"${us}"}"
        fi
    done

    IFS="${ws}" read -r -d '' -a _GH_SEARCH_TERMS <<< "${flat}" || true
    if (( ${#_GH_SEARCH_TERMS[@]} > 0 )); then
        _GH_SEARCH_TERMS=("${_GH_SEARCH_TERMS[@]//"${us}"/ }")
    elif [[ "${mode}" == "required" ]]; then
        echo "Error: search for ${tool_name} has no search terms: '${search}'"
        return 1
    fi
}

#######################################
# Resolve the scope of a search_code or search_commits call. An owner/repo value
# in repo comes first, and an owner passed with it must name the same owner; a
# bare repo name joins owner (the split form); an owner alone searches that
# user's or organization's repositories; GH_DEFAULT_REPO applies only when
# neither is passed. owner takes the characters _gh_validate_repo allows in an
# owner, since a user login, unlike an organization's, can contain '_'.
# Globals:
#   GH_DEFAULT_REPO (read); _GH_SEARCH_SCOPE (set)
# Arguments:
#   $1 owner from the tool arguments, may be empty,
#   $2 repo from the tool arguments, may be empty,
#   $3 tool name, for error messages.
# Outputs:
#   An error message on stdout on failure.
# Returns:
#   0 on success, 1 on a bare repo without owner, an owner that differs from
#   the owner in repo, or an invalid owner or repo.
#######################################
_gh_resolve_search_scope() {
    local owner="$1" repo="$2" tool_name="$3"
    _GH_SEARCH_SCOPE=()

    if [[ -n "${owner}" && ! "${owner}" =~ ^[a-zA-Z0-9_.-]+$ ]]; then
        echo "Error: owner for ${tool_name} must be a single GitHub user or organization login, got: '${owner}'"
        return 1
    fi
    # GitHub logins are case-insensitive.
    local repo_owner="${repo%%/*}"
    if [[ -n "${owner}" && "${repo}" == */* && "${owner,,}" != "${repo_owner,,}" ]]; then
        echo "Error: owner '${owner}' for ${tool_name} does not match the owner in repo '${repo}'"
        return 1
    fi

    if [[ -n "${repo}" && "${repo}" != */* ]]; then
        if [[ -z "${owner}" ]]; then
            echo "Error: repo '${repo}' for ${tool_name} needs owner, or pass repo as 'owner/repo'"
            return 1
        fi
        repo="${owner}/${repo}"
    fi

    if [[ -n "${repo}" ]]; then
        _gh_validate_repo "${repo}" || return 1
        _GH_SEARCH_SCOPE=("--repo" "${repo}")
    elif [[ -n "${owner}" ]]; then
        _GH_SEARCH_SCOPE=("--owner" "${owner}")
    elif [[ -n "${GH_DEFAULT_REPO:-}" ]]; then
        _gh_validate_repo "${GH_DEFAULT_REPO}" || return 1
        _GH_SEARCH_SCOPE=("--repo" "${GH_DEFAULT_REPO}")
    fi
}

# Search for GitHub issues or pull requests using a search expression.
# Maps to: gh search issues|prs [--repo] [--state] [--limit] [--json] -- <terms...>
tool_search() {
    local args="$1"

    local search type repo state limit fields jq_filter suppress_errors fallback
    search=$(echo "${args}" | jq -r '.search // empty')
    type=$(echo "${args}" | jq -r '.type // "prs"')
    repo=$(echo "${args}" | jq -r '.repo // empty')
    state=$(echo "${args}" | jq -r '.state // empty')
    limit=$(echo "${args}" | jq -r '.limit // 20')
    fields=$(echo "${args}" | jq -r '.fields // empty')
    jq_filter=$(echo "${args}" | jq -r '.jq_filter // empty')
    suppress_errors=$(echo "${args}" | jq -r '.suppress_errors // false')
    fallback=$(echo "${args}" | jq -r '.fallback // empty')

    if [[ -z "${search}" ]]; then
        echo "Error: search is required for search"
        return 1
    fi

    if [[ "${type}" != "issues" && "${type}" != "prs" ]]; then
        echo "Error: type must be 'issues' or 'prs', got: '${type}'"
        return 1
    fi

    _gh_validate_jq_filter "${jq_filter}" || return 1
    if [[ -n "${jq_filter}" && -z "${fields}" ]]; then
        printf '%s\n' "Error: jq_filter requires fields on search. Without fields, gh search returns a human-readable table that jq cannot parse. Pass fields (for example \"number,title,state,repository\") alongside jq_filter."
        return 1
    fi

    local effective_repo
    effective_repo=$(_gh_resolve_repo "${repo}")

    _gh_validate_number "${limit}" "limit" || return 1
    _gh_split_search_terms "${search}" "search" required || return 1

    local -a cmd=("gh" "search" "${type}")

    if [[ -n "${effective_repo}" ]]; then
        _gh_validate_repo "${effective_repo}" || return 1
        cmd+=("--repo" "${effective_repo}")
    fi

    [[ -n "${state}" ]] && cmd+=("--state" "${state}")
    cmd+=("--limit" "${limit}")
    [[ -n "${fields}" ]] && cmd+=("--json" "${fields}")
    cmd+=("--" "${_GH_SEARCH_TERMS[@]}")

    log "INFO" "search: ${cmd[*]}"
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
    _gh_post_process "${__raw}" "${jq_filter}" "" 0 0 false false "" "" || return $?
}

# Search for code across GitHub repositories.
# Uses the legacy code search engine (no regex, no symbol search, no path globs).
# Rate limit: 10 requests/minute (separate bucket from other search endpoints).
# Maps to: gh search code [--repo] [--owner] [--language] [--extension] [--filename] [--match] [--limit] [--json] -- <search>
tool_search_code() {
    local args="$1"

    local search owner repo language extension filename match limit fields
    local jq_filter grep_pattern grep_before grep_after grep_ignore_case grep_invert
    local max_lines tail_lines suppress_errors fallback download_to
    search=$(echo "${args}" | jq -r '.search // empty')
    owner=$(echo "${args}" | jq -r '.owner // empty')
    repo=$(echo "${args}" | jq -r '.repo // empty')
    language=$(echo "${args}" | jq -r '.language // empty')
    extension=$(echo "${args}" | jq -r '.extension // empty')
    filename=$(echo "${args}" | jq -r '.filename // empty')
    match=$(echo "${args}" | jq -r '.match // empty')
    limit=$(echo "${args}" | jq -r '.limit // 30')
    fields=$(echo "${args}" | jq -r '.fields // empty')
    jq_filter=$(echo "${args}" | jq -r '.jq_filter // empty')
    grep_pattern=$(echo "${args}" | jq -r '.grep_pattern // empty')
    grep_before=$(echo "${args}" | jq -r '.grep_context_before // 0')
    grep_after=$(echo "${args}" | jq -r '.grep_context_after // 0')
    grep_ignore_case=$(echo "${args}" | jq -r '.grep_ignore_case // false')
    grep_invert=$(echo "${args}" | jq -r '.grep_invert // false')
    max_lines=$(echo "${args}" | jq -r '.max_lines // empty')
    tail_lines=$(echo "${args}" | jq -r '.tail_lines // empty')
    suppress_errors=$(echo "${args}" | jq -r '.suppress_errors // false')
    fallback=$(echo "${args}" | jq -r '.fallback // empty')
    download_to=$(echo "${args}" | jq -r '.download_to // empty')

    if [[ -z "${search}" ]]; then
        echo "Error: search is required for search_code"
        return 1
    fi

    if [[ -n "${match}" && "${match}" != "file" && "${match}" != "path" ]]; then
        echo "Error: match must be 'file' or 'path', got: '${match}'"
        return 1
    fi

    _gh_validate_jq_filter "${jq_filter}" || return 1
    _gh_validate_grep_pattern "${grep_pattern}" || return 1
    _gh_validate_number "${limit}" "limit" || return 1

    local -a cmd=("gh" "search" "code")

    _gh_resolve_search_scope "${owner}" "${repo}" "search_code" || return 1
    cmd+=(${_GH_SEARCH_SCOPE[@]+"${_GH_SEARCH_SCOPE[@]}"})

    [[ -n "${language}" ]]  && cmd+=("--language" "${language}")
    [[ -n "${extension}" ]] && cmd+=("--extension" "${extension}")
    [[ -n "${filename}" ]]  && cmd+=("--filename" "${filename}")
    [[ -n "${match}" ]]     && cmd+=("--match" "${match}")
    cmd+=("--limit" "${limit}")

    local default_fields="repository,path,textMatches"
    [[ -n "${fields}" ]] && cmd+=("--json" "${fields}") || cmd+=("--json" "${default_fields}")
    # One argument, so gh quotes it as the exact text match the tool promises;
    # "--" keeps a search such as "->getId(" from being read as a flag.
    cmd+=("--" "${search}")

    log "INFO" "search_code: ${cmd[*]}"
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

    # download_to mode: save matching files locally
    if [[ -n "${download_to}" ]]; then
        local count=0 errors=0
        local entries
        entries=$(echo "${__raw}" | jq -r '.[] | "\(.repository.nameWithOwner)\t\(.path)"' 2>/dev/null) || {
            echo "Error: could not parse search results for download"
            return 1
        }
        while IFS=$'\t' read -r name_with_owner file_path; do
            [[ -z "${name_with_owner}" ]] && continue
            local dl_owner="${name_with_owner%%/*}"
            local dl_repo="${name_with_owner#*/}"
            local local_path="${download_to}/${name_with_owner}/${file_path}"
            if _gh_download_file "${dl_owner}" "${dl_repo}" "${file_path}" "${local_path}"; then
                count=$((count + 1))
            else
                errors=$((errors + 1))
            fi
        done <<< "${entries}"
        echo "Downloaded ${count} files to ${download_to} (${errors} errors)"
        return 0
    fi

    _gh_post_process "${__raw}" "${jq_filter}" "${grep_pattern}" "${grep_before}" \
        "${grep_after}" "${grep_ignore_case}" "${grep_invert}" "${max_lines}" "${tail_lines}" || return $?
}

# Search for GitHub repositories.
# Query is optional — filters alone (owner, topic, language, stars) suffice.
# Maps to: gh search repos [--owner] [--topic] [--language] [--license] [--stars] [--sort] [--limit] [--json] [-- <terms...>]
tool_search_repos() {
    local args="$1"

    local search owner topic language license stars sort limit fields
    local jq_filter max_lines suppress_errors fallback
    search=$(echo "${args}" | jq -r '.search // empty')
    owner=$(echo "${args}" | jq -r '.owner // empty')
    topic=$(echo "${args}" | jq -r '.topic // empty')
    language=$(echo "${args}" | jq -r '.language // empty')
    license=$(echo "${args}" | jq -r '.license // empty')
    stars=$(echo "${args}" | jq -r '.stars // empty')
    sort=$(echo "${args}" | jq -r '.sort // empty')
    limit=$(echo "${args}" | jq -r '.limit // 20')
    fields=$(echo "${args}" | jq -r '.fields // empty')
    jq_filter=$(echo "${args}" | jq -r '.jq_filter // empty')
    max_lines=$(echo "${args}" | jq -r '.max_lines // empty')
    suppress_errors=$(echo "${args}" | jq -r '.suppress_errors // false')
    fallback=$(echo "${args}" | jq -r '.fallback // empty')

    if [[ -n "${sort}" ]]; then
        case "${sort}" in
            stars|forks|help-wanted-issues|updated) ;;
            *)
                echo "Error: sort must be 'stars', 'forks', 'help-wanted-issues', or 'updated', got: '${sort}'"
                return 1
                ;;
        esac
    fi

    _gh_validate_jq_filter "${jq_filter}" || return 1
    _gh_validate_number "${limit}" "limit" || return 1
    _gh_split_search_terms "${search}" "search_repos" optional || return 1

    local -a cmd=("gh" "search" "repos")
    [[ -n "${owner}" ]]    && cmd+=("--owner" "${owner}")
    [[ -n "${topic}" ]]    && cmd+=("--topic" "${topic}")
    [[ -n "${language}" ]] && cmd+=("--language" "${language}")
    [[ -n "${license}" ]]  && cmd+=("--license" "${license}")
    [[ -n "${stars}" ]]    && cmd+=("--stars" "${stars}")
    [[ -n "${sort}" ]]     && cmd+=("--sort" "${sort}")
    cmd+=("--limit" "${limit}")

    local default_fields="fullName,description,stargazersCount,language,updatedAt,url"
    [[ -n "${fields}" ]] && cmd+=("--json" "${fields}") || cmd+=("--json" "${default_fields}")
    [[ ${#_GH_SEARCH_TERMS[@]} -gt 0 ]] && cmd+=("--" "${_GH_SEARCH_TERMS[@]}")

    log "INFO" "search_repos: ${cmd[*]}"
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
    _gh_post_process "${__raw}" "${jq_filter}" "" 0 0 false false "${max_lines}" "" || return $?
}

# Search for GitHub commits.
# Maps to: gh search commits [--repo] [--owner] [--author] [--committer] [--author-date] [--committer-date] [--hash] [--merge] [--sort] [--limit] [--json] -- <terms...>
tool_search_commits() {
    local args="$1"

    local search repo owner author committer author_date committer_date hash merge sort limit fields
    local jq_filter suppress_errors fallback
    search=$(echo "${args}" | jq -r '.search // empty')
    repo=$(echo "${args}" | jq -r '.repo // empty')
    owner=$(echo "${args}" | jq -r '.owner // empty')
    author=$(echo "${args}" | jq -r '.author // empty')
    committer=$(echo "${args}" | jq -r '.committer // empty')
    author_date=$(echo "${args}" | jq -r '.author_date // empty')
    committer_date=$(echo "${args}" | jq -r '.committer_date // empty')
    hash=$(echo "${args}" | jq -r '.hash // empty')
    merge=$(echo "${args}" | jq -r '.merge // empty')
    sort=$(echo "${args}" | jq -r '.sort // empty')
    limit=$(echo "${args}" | jq -r '.limit // 20')
    fields=$(echo "${args}" | jq -r '.fields // empty')
    jq_filter=$(echo "${args}" | jq -r '.jq_filter // empty')
    suppress_errors=$(echo "${args}" | jq -r '.suppress_errors // false')
    fallback=$(echo "${args}" | jq -r '.fallback // empty')

    if [[ -z "${search}" ]]; then
        echo "Error: search is required for search_commits"
        return 1
    fi

    if [[ -n "${sort}" ]]; then
        case "${sort}" in
            author-date|committer-date) ;;
            *)
                echo "Error: sort must be 'author-date' or 'committer-date', got: '${sort}'"
                return 1
                ;;
        esac
    fi

    _gh_validate_jq_filter "${jq_filter}" || return 1
    _gh_validate_number "${limit}" "limit" || return 1
    _gh_split_search_terms "${search}" "search_commits" required || return 1

    local -a cmd=("gh" "search" "commits")

    _gh_resolve_search_scope "${owner}" "${repo}" "search_commits" || return 1
    cmd+=(${_GH_SEARCH_SCOPE[@]+"${_GH_SEARCH_SCOPE[@]}"})

    [[ -n "${author}" ]]         && cmd+=("--author" "${author}")
    [[ -n "${committer}" ]]      && cmd+=("--committer" "${committer}")
    [[ -n "${author_date}" ]]    && cmd+=("--author-date" "${author_date}")
    [[ -n "${committer_date}" ]] && cmd+=("--committer-date" "${committer_date}")
    [[ -n "${hash}" ]]           && cmd+=("--hash" "${hash}")
    [[ "${merge}" == "true" ]]   && cmd+=("--merge")
    [[ "${merge}" == "false" ]]  && cmd+=("--merge=false")
    [[ -n "${sort}" ]]           && cmd+=("--sort" "${sort}")
    cmd+=("--limit" "${limit}")

    local default_fields="sha,commit"
    [[ -n "${fields}" ]] && cmd+=("--json" "${fields}") || cmd+=("--json" "${default_fields}")
    cmd+=("--" "${_GH_SEARCH_TERMS[@]}")

    log "INFO" "search_commits: ${cmd[*]}"
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
    _gh_post_process "${__raw}" "${jq_filter}" "" 0 0 false false "" "" || return $?
}

# Search for GitHub discussions using GraphQL.
# Discussions are only available via GraphQL (no gh search discussions subcommand).
# Maps to: gh api graphql with search() query
tool_search_discussions() {
    local args="$1"

    local search repo category author state with_comments limit
    local jq_filter max_lines tail_lines suppress_errors fallback
    search=$(echo "${args}" | jq -r '.search // empty')
    repo=$(echo "${args}" | jq -r '.repo // empty')
    category=$(echo "${args}" | jq -r '.category // empty')
    author=$(echo "${args}" | jq -r '.author // empty')
    state=$(echo "${args}" | jq -r '.state // empty')
    with_comments=$(echo "${args}" | jq -r '.with_comments // false')
    limit=$(echo "${args}" | jq -r '.limit // 20')
    jq_filter=$(echo "${args}" | jq -r '.jq_filter // empty')
    max_lines=$(echo "${args}" | jq -r '.max_lines // empty')
    tail_lines=$(echo "${args}" | jq -r '.tail_lines // empty')
    suppress_errors=$(echo "${args}" | jq -r '.suppress_errors // false')
    fallback=$(echo "${args}" | jq -r '.fallback // empty')

    if [[ -z "${search}" ]]; then
        echo "Error: search is required for search_discussions"
        return 1
    fi

    _gh_validate_jq_filter "${jq_filter}" || return 1
    _gh_validate_number "${limit}" "limit" || return 1

    local search_query="${search}"
    local effective_repo
    if [[ -n "${repo}" ]]; then
        _gh_validate_repo "${repo}" || return 1
        effective_repo="${repo}"
    else
        effective_repo="${GH_DEFAULT_REPO:-}"
    fi
    [[ -n "${effective_repo}" ]] && search_query="repo:${effective_repo} ${search_query}"
    [[ -n "${category}" ]]       && search_query="category:${category} ${search_query}"
    [[ -n "${author}" ]]         && search_query="author:${author} ${search_query}"
    [[ -n "${state}" ]]          && search_query="${state} ${search_query}"

    # Escape for GraphQL string interpolation: backslashes first, then double quotes, then newlines
    search_query="${search_query//\\/\\\\}"
    search_query="${search_query//\"/\\\"}"
    search_query="${search_query//$'\n'/\\n}"

    # Build comments fragment based on with_comments toggle
    local comments_fragment
    if [[ "${with_comments}" == "true" ]]; then
        comments_fragment='comments(first: 20) { nodes { body author { login } isAnswer replies(first: 5) { nodes { body author { login } } } } }'
    else
        comments_fragment='comments { totalCount }'
    fi

    local graphql_query
    graphql_query=$(cat <<GRAPHQL
{
  search(query: "${search_query} type:discussion", type: DISCUSSION, first: ${limit}) {
    nodes {
      ... on Discussion {
        number
        title
        url
        author { login }
        category { name }
        createdAt
        answerChosenAt
        ${comments_fragment}
      }
    }
  }
}
GRAPHQL
)

    local -a cmd=("gh" "api" "graphql" "-f" "query=${graphql_query}")

    log "INFO" "search_discussions: graphql search for '${search}'"
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

    # Extract just the nodes array for cleaner output
    local default_jq='.data.search.nodes'
    local effective_jq="${jq_filter:-${default_jq}}"
    __raw=$(echo "${__raw}" | jq "${effective_jq}") || {
        echo "Error: jq filter failed on output: ${effective_jq}"
        return 1
    }

    _gh_post_process "${__raw}" "" "" 0 0 false false "${max_lines}" "${tail_lines}" || return $?
}
