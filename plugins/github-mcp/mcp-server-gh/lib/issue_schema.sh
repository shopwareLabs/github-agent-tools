#!/usr/bin/env bash
# Issue type and issue field schema tools for gh-tooling MCP server
# Read: issue_schema

#######################################
# Resolve the organization that owns issue types and issue fields.
# Priority: org > owner > repo-shaped args > GH_DEFAULT_REPO > git remote.
# Globals:
#   GH_DEFAULT_REPO, _GH_OWNER
# Arguments:
#   JSON args string.
# Outputs:
#   Organization login on stdout, or an error message on stdout.
# Returns:
#   0 when an organization was resolved, 1 otherwise.
#######################################
_gh_resolve_issue_schema_org() {
    local args="$1"

    local org owner
    org=$(printf '%s\n' "${args}" | jq -r '.org // empty')
    owner=$(printf '%s\n' "${args}" | jq -r '.owner // empty')

    if [[ -n "${org}" ]]; then
        printf '%s\n' "${org}"
        return 0
    fi
    if [[ -n "${owner}" ]]; then
        printf '%s\n' "${owner}"
        return 0
    fi

    # Not run in a command substitution: the resolver reports through globals,
    # which a subshell would discard. Its own error text goes to our stdout.
    if ! _gh_resolve_owner_repo_optional "${args}"; then
        return 1
    fi
    if [[ -n "${_GH_OWNER}" ]]; then
        printf '%s\n' "${_GH_OWNER}"
        return 0
    fi

    local name_with_owner
    name_with_owner=$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null) || true
    if [[ -n "${name_with_owner}" ]]; then
        printf '%s\n' "${name_with_owner%%/*}"
        return 0
    fi

    printf '%s\n' "Error: org is required for issue_schema. Pass 'org', 'owner', or a repository ('repository', 'repo', or 'owner'+'repo'), or set 'repo' in .mcp-gh-tooling.json"
    return 1
}

#######################################
# List an organization's issue types and issue fields as one JSON document.
# Types and fields are independent: GitHub pins fields to types for the web UI
# only, and any org field can be set on an issue of any type, so this tool
# reports the two lists side by side rather than nesting fields under types.
# Maps to: gh api orgs/<org>/issue-types and gh api orgs/<org>/issue-fields
# Arguments:
#   JSON args string.
# Outputs:
#   Merged JSON on stdout; gh's error text on stdout when a call fails.
# Returns:
#   0 on success, non-zero on validation, resolution, or gh failure.
#######################################
tool_issue_schema() {
    local args="$1"

    local type field jq_filter max_lines suppress_errors fallback
    type=$(printf '%s\n' "${args}" | jq -r '.type // empty')
    field=$(printf '%s\n' "${args}" | jq -r '.field // empty')
    jq_filter=$(printf '%s\n' "${args}" | jq -r '.jq_filter // empty')
    max_lines=$(printf '%s\n' "${args}" | jq -r '.max_lines // empty')
    suppress_errors=$(printf '%s\n' "${args}" | jq -r '.suppress_errors // false')
    fallback=$(printf '%s\n' "${args}" | jq -r '.fallback // empty')

    _gh_validate_jq_filter "${jq_filter}" || return 1

    local org
    org=$(_gh_resolve_issue_schema_org "${args}") || {
        [[ -n "${fallback}" ]] && { printf '%s\n' "${fallback}"; return 0; }
        printf '%s\n' "${org}"
        return 1
    }

    local types_json fields_json
    types_json=$(_gh_issue_schema_fetch "${org}" "issue-types" "${suppress_errors}") || {
        [[ -n "${fallback}" ]] && { printf '%s\n' "${fallback}"; return 0; }
        printf '%s\n' "${types_json}"
        return 1
    }
    fields_json=$(_gh_issue_schema_fetch "${org}" "issue-fields" "${suppress_errors}") || {
        [[ -n "${fallback}" ]] && { printf '%s\n' "${fallback}"; return 0; }
        printf '%s\n' "${fields_json}"
        return 1
    }

    local merged
    merged=$(jq -n \
        --arg org "${org}" \
        --arg type "${type}" \
        --arg field "${field}" \
        --argjson types "${types_json}" \
        --argjson fields "${fields_json}" '
        def matches($wanted): $wanted == "" or (.name | ascii_downcase) == ($wanted | ascii_downcase);
        {
            org: $org,
            types: [$types[] | select(matches($type)) | {
                id, name, description, color, is_enabled
            }],
            fields: [$fields[] | select(matches($field)) | {
                id, name, description, data_type, visibility
            } + (if has("options") then {options: [.options[] | {id, name, color}]} else {} end)]
        }') || {
        [[ -n "${fallback}" ]] && { printf '%s\n' "${fallback}"; return 0; }
        printf '%s\n' "Error: could not merge issue types and issue fields for '${org}'"
        return 1
    }

    local unmatched
    unmatched=$(_gh_issue_schema_unmatched "${merged}" "${type}" "${field}")
    if [[ -n "${unmatched}" ]]; then
        [[ -n "${fallback}" ]] && { printf '%s\n' "${fallback}"; return 0; }
        printf '%s\n' "${unmatched}"
        return 1
    fi

    _gh_post_process "${merged}" "${jq_filter}" "" 0 0 false false "${max_lines}" "" || return $?
}

#######################################
# Fetch one organization-level issue schema collection.
# Arguments:
#   $1 organization login, $2 endpoint segment, $3 suppress_errors flag.
# Outputs:
#   The endpoint's JSON array on stdout, or gh's error text on stdout.
# Returns:
#   gh's exit status.
#######################################
_gh_issue_schema_fetch() {
    local org="$1" endpoint="$2" suppress_errors="$3"

    local -a cmd=("gh" "api" "orgs/${org}/${endpoint}")

    log "INFO" "issue_schema: ${cmd[*]}"
    local __raw __exit=0
    if [[ "${suppress_errors}" == "true" ]]; then
        __raw=$("${cmd[@]}" 2>/dev/null) || __exit=$?
    else
        __raw=$("${cmd[@]}" 2>&1) || __exit=$?
    fi
    if [[ ${__exit} -ne 0 ]]; then
        printf '%s\n' "${__raw}"
        return ${__exit}
    fi
    printf '%s\n' "${__raw}"
}

#######################################
# Report filters that matched nothing, so an empty list never reads as an
# organization that simply has no types or fields.
# Arguments:
#   $1 merged JSON, $2 requested type name, $3 requested field name.
# Outputs:
#   An error message on stdout when a requested name is absent, nothing
#   otherwise.
#######################################
_gh_issue_schema_unmatched() {
    local merged="$1" type="$2" field="$3"

    if [[ -n "${type}" ]]; then
        local type_count
        type_count=$(printf '%s\n' "${merged}" | jq '.types | length')
        if [[ "${type_count}" -eq 0 ]]; then
            printf '%s\n' "Error: issue type '${type}' not found. Call issue_schema without 'type' to list the available types."
            return 0
        fi
    fi

    if [[ -n "${field}" ]]; then
        local field_count
        field_count=$(printf '%s\n' "${merged}" | jq '.fields | length')
        if [[ "${field_count}" -eq 0 ]]; then
            printf '%s\n' "Error: issue field '${field}' not found. Call issue_schema without 'field' to list the available fields."
        fi
    fi
}
