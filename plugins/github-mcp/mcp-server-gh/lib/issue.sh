#!/usr/bin/env bash
# Issue tools for gh-tooling MCP server
# Tools: issue_view, issue_list

# View a GitHub issue with optional comments, type, and field values.
# Maps to: gh issue view <number> [--repo owner/repo] [--json <fields>] [--comments]
#          and gh api repos/<repo>/issues/<number> for the type and field values
tool_issue_view() {
    local args="$1"

    local number fields with_comments with_field_values jq_filter suppress_errors fallback max_lines
    number=$(echo "${args}" | jq -r '.number // empty')
    fields=$(echo "${args}" | jq -r '.fields // empty')
    with_comments=$(echo "${args}" | jq -r '.with_comments // false')
    with_field_values=$(echo "${args}" | jq -r '.with_field_values // false')
    jq_filter=$(echo "${args}" | jq -r '.jq_filter // empty')
    suppress_errors=$(echo "${args}" | jq -r '.suppress_errors // false')
    fallback=$(echo "${args}" | jq -r '.fallback // empty')
    max_lines=$(echo "${args}" | jq -r '.max_lines // empty')

    if [[ -z "${number}" ]]; then
        echo "Error: number is required for issue_view"
        return 1
    fi
    if [[ "${with_field_values}" == "true" && "${with_comments}" == "true" ]]; then
        echo "Error: with_field_values returns JSON and with_comments returns text; request them in separate calls"
        return 1
    fi
    _gh_validate_number "${number}" "number" || return 1
    _gh_validate_jq_filter "${jq_filter}" || return 1

    _gh_resolve_owner_repo_optional "${args}" || return 1
    local effective_repo=""
    [[ -n "${_GH_OWNER}" ]] && effective_repo="${_GH_OWNER}/${_GH_REPO}"
    _gh_require_repo_or_git "${effective_repo}" || return 1

    # The REST path is built by concatenation below, unlike --repo which gh
    # parses itself, so a resolved repo that is not owner/repo is rejected before
    # any call: the split form only checks that `repo` has no slash, and letting
    # it reach gh would turn an input error into a fallback success.
    if [[ "${with_field_values}" == "true" ]]; then
        _gh_validate_repo "${effective_repo}" || return 1
    fi

    local doc="{}"

    # gh issue view has nothing to contribute when the caller asked only for the
    # type and field values, which come from the REST issue instead.
    if [[ -n "${fields}" || "${with_field_values}" != "true" ]]; then
        local -a cmd=("gh" "issue" "view" "${number}")

        if [[ -n "${effective_repo}" ]]; then
            cmd+=("--repo" "${effective_repo}")
        fi

        if [[ -n "${fields}" ]]; then
            cmd+=("--json" "${fields}")
        elif [[ "${with_comments}" == "true" ]]; then
            cmd+=("--comments")
        fi

        log "INFO" "issue_view: ${cmd[*]}"
        local __raw __exit=0
        if [[ "${suppress_errors}" == "true" ]]; then
            __raw=$("${cmd[@]}" 2>/dev/null) || __exit=$?
        else
            __raw=$("${cmd[@]}" 2>&1) || __exit=$?
        fi
        if [[ ${__exit} -ne 0 ]]; then
            [[ -n "${fallback}" ]] && { echo "${fallback}"; return 0; }
            echo "${__raw}"; return ${__exit}
        fi

        if [[ "${with_field_values}" != "true" ]]; then
            _gh_post_process "${__raw}" "${jq_filter}" "" 0 0 false false "${max_lines}" "" || return $?
            return 0
        fi
        doc="${__raw}"
    fi

    local rest __fv_exit=0
    rest=$(_gh_issue_rest_issue "${effective_repo}" "${number}" "${suppress_errors}") || __fv_exit=$?
    if [[ ${__fv_exit} -ne 0 ]]; then
        [[ -n "${fallback}" ]] && { echo "${fallback}"; return 0; }
        echo "${rest}"; return ${__fv_exit}
    fi

    # A response this tool cannot decode is its own failure, not the failed API
    # call fallback stands in for, so it is reported either way.
    local extra
    extra=$(_gh_issue_field_values "${rest}") || {
        echo "${extra}"
        return 1
    }

    # The requested fields go in on stdin: an issue body or comment thread can be
    # larger than a command line holds.
    local merged
    merged=$(printf '%s' "${doc}" | jq --argjson extra "${extra}" '. + $extra') || {
        echo "Error: could not merge the issue's field values into the requested fields"
        return 1
    }

    _gh_post_process "${merged}" "${jq_filter}" "" 0 0 false false "${max_lines}" "" || return $?
}

# Fetch an issue's REST representation, which carries the type and field values
# that gh issue view does not expose.
_gh_issue_rest_issue() {
    local effective_repo="$1" number="$2" suppress_errors="$3"

    local path="repos/{owner}/{repo}/issues/${number}"
    [[ -n "${effective_repo}" ]] && path="repos/${effective_repo}/issues/${number}"

    local -a cmd=("gh" "api" "${path}")

    log "INFO" "issue_view: ${cmd[*]}"
    local __raw __exit=0
    if [[ "${suppress_errors}" == "true" ]]; then
        __raw=$("${cmd[@]}" 2>/dev/null) || __exit=$?
    else
        __raw=$("${cmd[@]}" 2>&1) || __exit=$?
    fi
    if [[ ${__exit} -ne 0 ]]; then
        echo "${__raw}"
        return ${__exit}
    fi
    echo "${__raw}"
}

# Reduce a REST issue to the type name and the field values in the shape
# issue_field_set takes. The REST issue reports a single-select value as an
# option id while writes take the option name, so the names are read off the
# response's option objects rather than the raw value. Two values naming the
# same field are an error rather than a silent collapse: keying by name is what
# makes the result writable, and from_entries would keep only the last.
_gh_issue_field_values() {
    local rest="$1"

    local decoded
    decoded=$(printf '%s' "${rest}" | jq '
        [(.issue_field_values // [])[] | {
            key: .issue_field_name,
            value: (if .multi_select_options != null then [.multi_select_options[].name]
                    elif .single_select_option != null then .single_select_option.name
                    else .value end)
        }] as $entries
        | [$entries[].key] as $names
        | if ($names | any(. == null)) then
              {_error: "the response holds a field value with no field name"}
          elif ($names | length) != ($names | unique | length) then
              {_error: "the response holds more than one value for \($names | group_by(.) | map(select(length > 1)) | map(.[0]) | join(", "))"}
          else
              {type: (.type.name // null), field_values: ($entries | from_entries)}
          end') || {
        echo "Error: could not read the issue's type and field values"
        return 1
    }

    local decode_error
    decode_error=$(printf '%s' "${decoded}" | jq -r '._error // empty')
    if [[ -n "${decode_error}" ]]; then
        echo "Error: could not read the issue's field values: ${decode_error}"
        return 1
    fi

    printf '%s\n' "${decoded}"
}

# List issues with optional filters.
# Maps to: gh issue list [--repo] [--search] [--state] [--label] [--limit] [--json]
tool_issue_list() {
    local args="$1"

    local search state label limit fields jq_filter suppress_errors fallback
    search=$(echo "${args}" | jq -r '.search // empty')
    state=$(echo "${args}" | jq -r '.state // empty')
    label=$(echo "${args}" | jq -r '.label // empty')
    limit=$(echo "${args}" | jq -r '.limit // 20')
    fields=$(echo "${args}" | jq -r '.fields // empty')
    jq_filter=$(echo "${args}" | jq -r '.jq_filter // empty')
    suppress_errors=$(echo "${args}" | jq -r '.suppress_errors // false')
    fallback=$(echo "${args}" | jq -r '.fallback // empty')

    _gh_validate_jq_filter "${jq_filter}" || return 1

    _gh_resolve_owner_repo_optional "${args}" || return 1
    local effective_repo=""
    [[ -n "${_GH_OWNER}" ]] && effective_repo="${_GH_OWNER}/${_GH_REPO}"
    _gh_require_repo_or_git "${effective_repo}" || return 1

    local -a cmd=("gh" "issue" "list")

    if [[ -n "${effective_repo}" ]]; then
        cmd+=("--repo" "${effective_repo}")
    fi

    [[ -n "${search}" ]] && cmd+=("--search" "${search}")
    [[ -n "${state}" ]] && cmd+=("--state" "${state}")
    [[ -n "${label}" ]] && cmd+=("--label" "${label}")
    _gh_validate_number "${limit}" "limit" || return 1
    cmd+=("--limit" "${limit}")
    [[ -n "${fields}" ]] && cmd+=("--json" "${fields}")

    log "INFO" "issue_list: ${cmd[*]}"
    local __raw __exit=0
    if [[ "${suppress_errors}" == "true" ]]; then
        __raw=$("${cmd[@]}" 2>/dev/null) || __exit=$?
    else
        __raw=$("${cmd[@]}" 2>&1) || __exit=$?
    fi
    if [[ ${__exit} -ne 0 ]]; then
        [[ -n "${fallback}" ]] && { echo "${fallback}"; return 0; }
        echo "${__raw}"; return ${__exit}
    fi
    _gh_post_process "${__raw}" "${jq_filter}" "" 0 0 false false "" "" || return $?
}
