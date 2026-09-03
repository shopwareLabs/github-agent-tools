#!/usr/bin/env bats
# bats file_tags=github-mcp,write-tools
# Tests for the issue_type_set and issue_field_set write tools
bats_require_minimum_version 1.11.0

load 'test_helper/common_setup'

TYPES_JSON='[{"id":125714,"name":"Bug"},{"id":25328944,"name":"Improvement"}]'
FIELDS_JSON='[{"id":8847,"name":"Priority","data_type":"single_select","options":[{"id":12296,"name":"High"},{"id":12298,"name":"Low"}]},{"id":8848,"name":"Start date","data_type":"date"},{"id":8851,"name":"Points","data_type":"number"},{"id":8852,"name":"Owner","data_type":"text"},{"id":8853,"name":"Teams","data_type":"multi_select","options":[{"id":1,"name":"Core"},{"id":2,"name":"Storefront"}]},{"id":8854,"name":"Flag","data_type":"boolean"}]'

setup() {
    log() { :; }
    GH_DEFAULT_REPO="shopware/shopware"
    GH_TOOLING_CONFIG_FILE=""
    source "${GH_LIB_DIR}/common.sh"
    source "${GH_LIB_DIR}/issue_schema_write.sh"

    GH_ARGS_FILE="${BATS_TEST_TMPDIR}/gh_args"
    GH_BODY_FILE="${BATS_TEST_TMPDIR}/gh_body"

    # Stub answers the org lookups from fixtures and records the write request.
    gh() {
        case "$*" in
            *orgs/*/issue-types*) printf '%s\n' "${TYPES_JSON}"; return 0 ;;
            *orgs/*/issue-fields*) printf '%s\n' "${FIELDS_JSON}"; return 0 ;;
        esac
        printf '%s\n' "$@" > "${GH_ARGS_FILE}"
        cat > "${GH_BODY_FILE}"
        [[ -n "${GH_STUB_EXIT:-}" ]] && return "${GH_STUB_EXIT}"
        printf '%s\n' "${GH_STUB_OUTPUT}"
        return 0
    }
    GH_STUB_OUTPUT='{"number":19952,"type":{"name":"Bug"}}'
    GH_STUB_EXIT=""
}

body() { jq -c "$1" "${GH_BODY_FILE}"; }

# ============================================================================
# issue_type_set
# ============================================================================

@test "issue_type_set PATCHes the issue with the canonical type name" {
    run tool_issue_type_set '{"number": 19952, "type": "bug"}'
    assert_success
    run grep -x -- 'PATCH' "${GH_ARGS_FILE}"
    assert_success
    run grep -x -- 'repos/shopware/shopware/issues/19952' "${GH_ARGS_FILE}"
    assert_success
    assert_equal "$(body '.type')" '"Bug"'
}

@test "issue_type_set sends a null type to clear it" {
    GH_STUB_OUTPUT='{"number":19952,"type":null}'
    run tool_issue_type_set '{"number": 19952, "type": null}'
    assert_success
    assert_equal "$(body '.type')" 'null'
    assert_equal "$(printf '%s' "${output}" | jq -r '.type')" 'null'
}

@test "issue_type_set rejects an unknown type before calling the API" {
    run tool_issue_type_set '{"number": 19952, "type": "Bogus"}'
    assert_failure
    assert_output --partial "Available types: Bug, Improvement"
    [ ! -f "${GH_ARGS_FILE}" ]
}

@test "issue_type_set requires the type key" {
    run tool_issue_type_set '{"number": 19952}'
    assert_failure
    assert_output --partial "type is required"
}

@test "issue_type_set requires a number" {
    run tool_issue_type_set '{"type": "Bug"}'
    assert_failure
    assert_output --partial "number is required"
}

@test "issue_type_set returns the fallback when the API call fails" {
    GH_STUB_EXIT=1
    run tool_issue_type_set '{"number": 19952, "type": "Bug", "fallback": "unchanged"}'
    assert_success
    assert_output "unchanged"
}

# ============================================================================
# issue_field_set
# ============================================================================

@test "issue_field_set PUTs the whole set with resolved field ids" {
    GH_STUB_OUTPUT='[{"issue_field_name":"Priority","single_select_option":{"name":"High"}}]'
    run tool_issue_field_set '{"number": 19952, "values": {"Priority": "high"}}'
    assert_success
    run grep -x -- 'PUT' "${GH_ARGS_FILE}"
    assert_success
    run grep -x -- 'repos/shopware/shopware/issues/19952/issue-field-values' "${GH_ARGS_FILE}"
    assert_success
    assert_equal "$(body '.issue_field_values')" '[{"field_id":8847,"value":"High"}]'
}

@test "issue_field_set sends an empty array when values is empty" {
    GH_STUB_OUTPUT='[]'
    run tool_issue_field_set '{"number": 19952, "values": {}}'
    assert_success
    assert_equal "$(body '.issue_field_values')" '[]'
}

@test "issue_field_set passes date, number, and text values through unchanged" {
    GH_STUB_OUTPUT='[]'
    run tool_issue_field_set '{"number": 19952, "values": {"Start date": "2026-09-30", "Points": 5, "Owner": "core"}}'
    assert_success
    assert_equal "$(body '[.issue_field_values[].value]')" '["2026-09-30",5,"core"]'
}

@test "issue_field_set rejects an unknown field before calling the API" {
    run tool_issue_field_set '{"number": 19952, "values": {"Prioriti": "High"}}'
    assert_failure
    assert_output --partial "Available fields: Priority, Start date, Points, Owner"
    [ ! -f "${GH_ARGS_FILE}" ]
}

@test "issue_field_set rejects an unknown single-select option" {
    run tool_issue_field_set '{"number": 19952, "values": {"Priority": "Urgent"}}'
    assert_failure
    assert_output --partial "Available options: High, Low"
}

@test "issue_field_set rejects a malformed date" {
    run tool_issue_field_set '{"number": 19952, "values": {"Start date": "30.09.2026"}}'
    assert_failure
    assert_output --partial "takes a date as YYYY-MM-DD"
}

@test "issue_field_set rejects a non-numeric value for a number field" {
    run tool_issue_field_set '{"number": 19952, "values": {"Points": "five"}}'
    assert_failure
    assert_output --partial "takes a number"
}

@test "issue_field_set reports every rejected entry at once" {
    run tool_issue_field_set '{"number": 19952, "values": {"Prioriti": "High", "Points": "five"}}'
    assert_failure
    assert_output --partial "Prioriti"
    assert_output --partial "takes a number"
}

@test "issue_field_set requires the values key" {
    run tool_issue_field_set '{"number": 19952}'
    assert_failure
    assert_output --partial "values is required"
}

@test "issue_field_set requires a number" {
    run tool_issue_field_set '{"values": {}}'
    assert_failure
    assert_output --partial "number is required"
}

@test "issue_field_set returns the fallback when the API call fails" {
    GH_STUB_EXIT=1
    run tool_issue_field_set '{"number": 19952, "values": {}, "fallback": "unchanged"}'
    assert_success
    assert_output "unchanged"
}

@test "issue_field_set shapes the response like the values it takes" {
    GH_STUB_OUTPUT='[{"issue_field_name":"Priority","value":12296,"single_select_option":{"id":12296,"name":"High"}},{"issue_field_name":"Start date","value":"2026-09-30"},{"issue_field_name":"Areas","multi_select_options":[{"id":13001,"name":"Storefront"}]}]'
    run tool_issue_field_set '{"number": 19952, "values": {"Priority": "High"}}'
    assert_success
    assert_equal "$(printf '%s' "${output}" | jq -c '.')" '{"Priority":"High","Start date":"2026-09-30","Areas":["Storefront"]}'
}

@test "issue_field_set resolves a multi-select array to canonical option names" {
    GH_STUB_OUTPUT='[]'
    run tool_issue_field_set '{"number": 19952, "values": {"Teams": ["core", "Storefront"]}}'
    assert_success
    assert_equal "$(body '.issue_field_values')" '[{"field_id":8853,"value":["Core","Storefront"]}]'
}

@test "issue_field_set rejects a non-array value for a multi-select field" {
    run tool_issue_field_set '{"number": 19952, "values": {"Teams": "Core"}}'
    assert_failure
    assert_output --partial "takes an array of option names"
}

@test "issue_field_set rejects an unknown option inside a multi-select array" {
    run tool_issue_field_set '{"number": 19952, "values": {"Teams": ["Core", "Nope"]}}'
    assert_failure
    assert_output --partial "Available options: Core, Storefront"
}

@test "issue_field_set with suppress_errors returns no error text" {
    GH_STUB_EXIT=1
    run tool_issue_field_set '{"number": 19952, "values": {}, "suppress_errors": true}'
    assert_failure
    assert_output ""
}

@test "issue_field_set rejects a null or array values argument instead of clearing everything" {
    run tool_issue_field_set '{"number": 19952, "values": null}'
    assert_failure
    assert_output --partial "must be an object"
    [ ! -f "${GH_ARGS_FILE}" ]

    run tool_issue_field_set '{"number": 19952, "values": []}'
    assert_failure
    assert_output --partial "must be an object"
    [ ! -f "${GH_ARGS_FILE}" ]
}

@test "issue_field_set rejects non-string elements in a multi-select array" {
    run tool_issue_field_set '{"number": 19952, "values": {"Teams": [1, 2]}}'
    assert_failure
    assert_output --partial "array of option names as strings"
}

@test "issue_field_set rejects a malformed repo" {
    run tool_issue_field_set '{"number": 19952, "values": {}, "repo": "widgets"}'
    assert_failure
    assert_output --partial "owner/repo"
}

@test "issue_type_set rejects a malformed repo" {
    run tool_issue_type_set '{"number": 19952, "type": "Bug", "repo": "widgets"}'
    assert_failure
    assert_output --partial "owner/repo"
}

@test "fallback does not mask an unknown field name" {
    run tool_issue_field_set '{"number": 19952, "values": {"Ghost": "x"}, "fallback": "ok"}'
    assert_failure
    assert_output --partial "not found"
}

@test "fallback does not mask an unknown issue type" {
    run tool_issue_type_set '{"number": 19952, "type": "Bogus", "fallback": "ok"}'
    assert_failure
    assert_output --partial "Available types"
}

@test "issue_field_set rejects a date with trailing whitespace or an impossible month" {
    run tool_issue_field_set '{"number": 19952, "values": {"Start date": "2026-09-30\n"}}'
    assert_failure
    assert_output --partial "YYYY-MM-DD"

    run tool_issue_field_set '{"number": 19952, "values": {"Start date": "2026-99-99"}}'
    assert_failure
    assert_output --partial "YYYY-MM-DD"
}

@test "issue_field_set rejects a field whose data type it does not support" {
    run tool_issue_field_set '{"number": 19952, "values": {"Flag": "yes"}}'
    assert_failure
    assert_output --partial "unsupported data type boolean"
}

@test "issue_field_set rejects two keys that name the same field" {
    run tool_issue_field_set '{"number": 19952, "values": {"Priority": "High", "priority": "Low"}}'
    assert_failure
    assert_output --partial "name the same issue field"
    [ ! -f "${GH_ARGS_FILE}" ]
}
