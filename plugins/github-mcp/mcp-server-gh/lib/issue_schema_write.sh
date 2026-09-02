#!/usr/bin/env bash
# Issue type and issue field write tools for gh-tooling-write MCP server
# Write: issue_type_set, issue_field_set

#######################################
# Fetch an organization's issue types or issue fields.
# Arguments:
#   $1 organization login, $2 endpoint segment ("issue-types" or "issue-fields").
# Outputs:
#   The endpoint's JSON array on stdout, or gh's error text on stdout.
# Returns:
#   gh's exit status.
#######################################
_gh_issue_org_collection() {
    local org="$1" endpoint="$2"

    local __raw __exit=0
    __raw=$(gh api "orgs/${org}/${endpoint}" 2>&1) || __exit=$?
    printf '%s\n' "${__raw}"
    return ${__exit}
}

#######################################
# Resolve an issue type name to the organization's canonical spelling.
# Arguments:
#   $1 organization login, $2 requested type name.
# Outputs:
#   The canonical type name on stdout, or an error listing the available types.
# Returns:
#   0 when the name resolved, 1 otherwise.
#######################################
_gh_resolve_issue_type() {
    local org="$1" wanted="$2"

    local types_json
    types_json=$(_gh_issue_org_collection "${org}" "issue-types") || {
        printf '%s\n' "Error: could not list issue types for '${org}': ${types_json}"
        return 1
    }

    local resolved
    resolved=$(printf '%s\n' "${types_json}" | jq -r --arg wanted "${wanted}" '
        [.[] | select((.name | ascii_downcase) == ($wanted | ascii_downcase)) | .name][0] // empty' 2>/dev/null)

    if [[ -z "${resolved}" ]]; then
        local available
        available=$(printf '%s\n' "${types_json}" | jq -r '[.[].name] | join(", ")' 2>/dev/null)
        printf '%s\n' "Error: issue type '${wanted}' not found in '${org}'. Available types: ${available:-<none>}"
        return 1
    fi

    printf '%s\n' "${resolved}"
}

#######################################
# Turn a name-keyed values object into the API's issue_field_values array.
# Resolves each field name to its numeric id and checks each value against the
# field's data type, so a bad name fails here naming the valid options rather
# than reaching GitHub, which reports a wrong option name for an unknown field.
# Arguments:
#   $1 organization login, $2 values object keyed by field name.
# Outputs:
#   The issue_field_values JSON array on stdout, or an error message.
# Returns:
#   0 when every entry resolved, 1 otherwise.
#######################################
_gh_resolve_issue_field_values() {
    local org="$1" values="$2"

    local fields_json
    fields_json=$(_gh_issue_org_collection "${org}" "issue-fields") || {
        printf '%s\n' "Error: could not list issue fields for '${org}': ${fields_json}"
        return 1
    }

    local resolved
    resolved=$(jq -n \
        --argjson fields "${fields_json}" \
        --argjson values "${values}" '
        def find($name): [$fields[] | select((.name | ascii_downcase) == ($name | ascii_downcase))][0];
        def option($field; $value):
            [$field.options[] | select((.name | ascii_downcase) == ($value | ascii_downcase)) | .name][0];
        def check($name; $value):
            find($name) as $field
            | if $field == null
              then {error: "issue field \($name) not found. Available fields: \([$fields[].name] | join(", "))"}
              elif $field.data_type == "single_select" then
                  (if ($value | type) != "string" then {error: "issue field \($name) takes an option name as a string, got \($value | type)"}
                   else option($field; $value) as $match
                   | if $match == null
                     then {error: "option \($value) not found for issue field \($name). Available options: \([$field.options[].name] | join(", "))"}
                     else {field_id: $field.id, value: $match} end
                   end)
              elif $field.data_type == "multi_select" then
                  (if ($value | type) != "array" then {error: "issue field \($name) takes an array of option names, got \($value | type)"}
                   elif ([$value[] | type] | any(. != "string")) then {error: "issue field \($name) takes an array of option names as strings"}
                   else ([$value[] | option($field; .)] | if any(. == null) then null else . end) as $matches
                   | if $matches == null
                     then {error: "one or more options not found for issue field \($name). Available options: \([$field.options[].name] | join(", "))"}
                     else {field_id: $field.id, value: $matches} end
                   end)
              elif $field.data_type == "date" then
                  (if ($value | type) == "string" and ($value | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}$"))
                   then {field_id: $field.id, value: $value}
                   else {error: "issue field \($name) takes a date as YYYY-MM-DD, got \($value | tostring)"} end)
              elif $field.data_type == "number" then
                  (if ($value | type) == "number"
                   then {field_id: $field.id, value: $value}
                   else {error: "issue field \($name) takes a number, got \($value | type)"} end)
              else
                  (if ($value | type) == "string"
                   then {field_id: $field.id, value: $value}
                   else {error: "issue field \($name) takes a string, got \($value | type)"} end)
              end;
        [$values | to_entries[] | check(.key; .value)] as $entries
        | [$entries[] | select(has("error")) | .error] as $errors
        | if ($errors | length) > 0 then {errors: $errors} else {values: $entries} end') || {
        printf '%s\n' "Error: could not read the 'values' object"
        return 1
    }

    local errors
    errors=$(printf '%s\n' "${resolved}" | jq -r '.errors // [] | join("; ")')
    if [[ -n "${errors}" ]]; then
        printf '%s\n' "Error: ${errors}"
        return 1
    fi

    printf '%s\n' "${resolved}" | jq -c '.values'
}

#######################################
# Set or clear an issue's type.
# Setting the same type twice is the same call: the type name replaces whatever
# the issue carried before, and null clears it.
# Maps to: gh api -X PATCH repos/<repo>/issues/<number> with a type body
# Arguments:
#   JSON args string.
# Outputs:
#   The issue's number and resulting type as JSON, or an error message.
# Returns:
#   0 on success, non-zero on validation or gh failure.
#######################################
tool_issue_type_set() {
    local args="$1"

    local number has_type type_is_null type repo suppress_errors fallback
    number=$(printf '%s\n' "${args}" | jq -r '.number // empty')
    has_type=$(printf '%s\n' "${args}" | jq -r 'if has("type") then "true" else "false" end')
    type_is_null=$(printf '%s\n' "${args}" | jq -r 'if .type == null then "true" else "false" end')
    type=$(printf '%s\n' "${args}" | jq -r '.type // empty')
    repo=$(printf '%s\n' "${args}" | jq -r '.repo // empty')
    suppress_errors=$(printf '%s\n' "${args}" | jq -r '.suppress_errors // false')
    fallback=$(printf '%s\n' "${args}" | jq -r '.fallback // empty')

    if [[ -z "${number}" ]]; then printf '%s\n' "Error: number is required for issue_type_set"; return 1; fi
    if [[ "${has_type}" != "true" ]]; then
        printf '%s\n' "Error: type is required for issue_type_set. Pass an issue type name, or null to clear the type."
        return 1
    fi
    _gh_validate_number "${number}" "number" || return 1

    local effective_repo
    effective_repo=$(_gh_resolve_repo "${repo}")
    if [[ -z "${effective_repo}" ]]; then
        printf '%s\n' "Error: repo is required for issue_type_set"
        return 1
    fi
    _gh_validate_repo "${effective_repo}" || return 1

    local body
    if [[ "${type_is_null}" == "true" ]]; then
        body='{"type":null}'
    else
        if [[ -z "${type}" ]]; then
            printf '%s\n' "Error: type is required for issue_type_set. Pass an issue type name, or null to clear the type."
            return 1
        fi

        local canonical
        canonical=$(_gh_resolve_issue_type "${effective_repo%%/*}" "${type}") || {
            printf '%s\n' "${canonical}"
            return 1
        }
        body=$(jq -nc --arg type "${canonical}" '{type: $type}')
    fi

    _gh_issue_schema_write "PATCH" "repos/${effective_repo}/issues/${number}" "${body}" \
        '{number: .number, type: (.type.name // null)}' "issue_type_set" "${suppress_errors}" "${fallback}"
}

#######################################
# Replace an issue's field values with the given set.
# The object passed becomes the issue's complete set of field values: a field
# left out is cleared, and an empty object clears every value. Sending the same
# object twice leaves the issue in the same state.
# Maps to: gh api -X PUT repos/<repo>/issues/<number>/issue-field-values
# Arguments:
#   JSON args string.
# Outputs:
#   The resulting field values as JSON, or an error message.
# Returns:
#   0 on success, non-zero on validation or gh failure.
#######################################
tool_issue_field_set() {
    local args="$1"

    local number values_type values repo suppress_errors fallback
    number=$(printf '%s\n' "${args}" | jq -r '.number // empty')
    values_type=$(printf '%s\n' "${args}" | jq -r 'if has("values") then (.values | type) else "absent" end')
    values=$(printf '%s\n' "${args}" | jq -c '.values')
    repo=$(printf '%s\n' "${args}" | jq -r '.repo // empty')
    suppress_errors=$(printf '%s\n' "${args}" | jq -r '.suppress_errors // false')
    fallback=$(printf '%s\n' "${args}" | jq -r '.fallback // empty')

    if [[ -z "${number}" ]]; then printf '%s\n' "Error: number is required for issue_field_set"; return 1; fi
    if [[ "${values_type}" == "absent" ]]; then
        printf '%s\n' "Error: values is required for issue_field_set. Pass the complete set of field values, or {} to clear them all."
        return 1
    fi
    if [[ "${values_type}" != "object" ]]; then
        printf '%s\n' "Error: values must be an object keyed by field name, got ${values_type}. Pass {} to clear every field value."
        return 1
    fi
    _gh_validate_number "${number}" "number" || return 1

    local effective_repo
    effective_repo=$(_gh_resolve_repo "${repo}")
    if [[ -z "${effective_repo}" ]]; then
        printf '%s\n' "Error: repo is required for issue_field_set"
        return 1
    fi
    _gh_validate_repo "${effective_repo}" || return 1

    local field_values
    field_values=$(_gh_resolve_issue_field_values "${effective_repo%%/*}" "${values}") || {
        printf '%s\n' "${field_values}"
        return 1
    }

    local body
    body=$(jq -nc --argjson entries "${field_values}" '{issue_field_values: $entries}') || {
        printf '%s\n' "Error: could not build the request body for issue_field_set"
        return 1
    }

    _gh_issue_schema_write "PUT" "repos/${effective_repo}/issues/${number}/issue-field-values" \
        "${body}" '[.[] | {field: .issue_field_name, value: (.single_select_option.name // .value)}]' \
        "issue_field_set" "${suppress_errors}" "${fallback}"
}

#######################################
# Send a request body to the GitHub API and shape the response.
# Arguments:
#   $1 HTTP method, $2 endpoint, $3 request body JSON, $4 jq filter for the
#   response, $5 tool name, $6 suppress_errors, $7 fallback.
# Outputs:
#   The filtered response on stdout, or gh's error text on stdout.
# Returns:
#   0 on success, gh's exit status on failure.
#######################################
_gh_issue_schema_write() {
    local method="$1" endpoint="$2" body="$3" response_filter="$4"
    local tool="$5" suppress_errors="$6" fallback="$7"

    local -a cmd=("gh" "api" "-X" "${method}" "${endpoint}" "--input" "-")

    log "INFO" "${tool}: ${cmd[*]} ${body}"
    local __raw __exit=0
    if [[ "${suppress_errors}" == "true" ]]; then
        __raw=$(printf '%s' "${body}" | "${cmd[@]}" 2>/dev/null) || __exit=$?
    else
        __raw=$(printf '%s' "${body}" | "${cmd[@]}" 2>&1) || __exit=$?
    fi
    if [[ ${__exit} -ne 0 ]]; then
        [[ -n "${fallback}" ]] && { printf '%s\n' "${fallback}"; return 0; }
        printf '%s\n' "${__raw}"
        return ${__exit}
    fi

    printf '%s\n' "${__raw}" | jq "${response_filter}" 2>/dev/null || printf '%s\n' "${__raw}"
}
