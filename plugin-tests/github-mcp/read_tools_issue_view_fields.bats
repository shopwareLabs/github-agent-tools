#!/usr/bin/env bats
# bats file_tags=github-mcp,read-tools
# Tests for issue_view's with_field_values output
bats_require_minimum_version 1.11.0

load 'test_helper/common_setup'

REST_ISSUE='{"number":19952,"type":{"id":125714,"name":"Bug"},"issue_field_values":[{"issue_field_id":8847,"issue_field_name":"Priority","data_type":"single_select","value":12298,"single_select_option":{"id":12298,"name":"Low","color":"green"}},{"issue_field_id":8849,"issue_field_name":"Target date","data_type":"date","value":"2026-03-01"},{"issue_field_id":8851,"issue_field_name":"Areas","data_type":"multi_select","multi_select_options":[{"id":13001,"name":"Storefront"},{"id":13002,"name":"Admin"}]}]}'

setup() {
    log() { :; }
    GH_DEFAULT_REPO="shopware/shopware"
    GH_TOOLING_CONFIG_FILE=""
    source "${GH_LIB_DIR}/common.sh"
    source "${GH_LIB_DIR}/issue.sh"

    GH_ARGS_FILE="${BATS_TEST_TMPDIR}/gh_args"

    # The tool makes at most two calls per run: gh issue view for the requested
    # fields, gh api for the type and field values.
    gh() {
        printf '%s\n' "$*" >> "${GH_ARGS_FILE}"
        case "$*" in
            *"issue view"*)
                [[ -n "${GH_STUB_VIEW_EXIT:-}" ]] && return "${GH_STUB_VIEW_EXIT}"
                printf '%s\n' "${GH_STUB_VIEW}"
                ;;
            *"api repos/"*)
                [[ -n "${GH_STUB_REST_EXIT:-}" ]] && { printf '%s\n' "${GH_STUB_REST}"; return "${GH_STUB_REST_EXIT}"; }
                printf '%s\n' "${GH_STUB_REST}"
                ;;
            *)
                printf '%s\n' ""
                ;;
        esac
        return 0
    }
    GH_STUB_VIEW='{"title":"Broken thing","state":"OPEN"}'
    GH_STUB_REST="${REST_ISSUE}"
    GH_STUB_VIEW_EXIT=""
    GH_STUB_REST_EXIT=""
}

@test "issue_view with_field_values returns the type and field values keyed by name" {
    run tool_issue_view '{"number": 19952, "repo": "shopware/shopware", "with_field_values": true}'
    assert_success
    assert_equal "$(printf '%s' "${output}" | jq -r '.type')" "Bug"
    assert_equal "$(printf '%s' "${output}" | jq -r '.field_values.Priority')" "Low"
    assert_equal "$(printf '%s' "${output}" | jq -r '.field_values["Target date"]')" "2026-03-01"
    assert_equal "$(printf '%s' "${output}" | jq -rc '.field_values.Areas')" '["Storefront","Admin"]'
}

@test "issue_view with_field_values reports a single-select by option name, not id" {
    run tool_issue_view '{"number": 19952, "repo": "shopware/shopware", "with_field_values": true}'
    assert_success
    refute_output --partial "12298"
}

@test "issue_view with_field_values skips gh issue view when no fields are requested" {
    run tool_issue_view '{"number": 19952, "repo": "shopware/shopware", "with_field_values": true}'
    assert_success
    run grep -c -- "issue view" "${GH_ARGS_FILE}"
    assert_output "0"
}

@test "issue_view with_field_values merges into the requested fields" {
    run tool_issue_view '{"number": 19952, "repo": "shopware/shopware", "with_field_values": true, "fields": "title,state"}'
    assert_success
    assert_equal "$(printf '%s' "${output}" | jq -r '.title')" "Broken thing"
    assert_equal "$(printf '%s' "${output}" | jq -r '.state')" "OPEN"
    assert_equal "$(printf '%s' "${output}" | jq -r '.type')" "Bug"
    assert_equal "$(printf '%s' "${output}" | jq -r '.field_values.Priority')" "Low"
}

@test "issue_view with_field_values queries the issue's REST endpoint" {
    run tool_issue_view '{"number": 19952, "repo": "shopware/shopware", "with_field_values": true}'
    assert_success
    run grep -F -- "api repos/shopware/shopware/issues/19952" "${GH_ARGS_FILE}"
    assert_success
}

@test "issue_view with_field_values reports an empty object for an issue with no values" {
    GH_STUB_REST='{"number":42,"type":null}'
    run tool_issue_view '{"number": 42, "repo": "shopware/shopware", "with_field_values": true}'
    assert_success
    assert_equal "$(printf '%s' "${output}" | jq -r '.type')" "null"
    assert_equal "$(printf '%s' "${output}" | jq -rc '.field_values')" "{}"
}

@test "issue_view rejects with_field_values together with with_comments" {
    run tool_issue_view '{"number": 19952, "repo": "shopware/shopware", "with_field_values": true, "with_comments": true}'
    assert_failure
    assert_output --partial "separate calls"
}

@test "issue_view applies jq_filter to the merged document" {
    run tool_issue_view '{"number": 19952, "repo": "shopware/shopware", "with_field_values": true, "jq_filter": ".field_values.Priority"}'
    assert_success
    assert_output --partial "Low"
}

@test "issue_view with_field_values reports a failed REST call" {
    GH_STUB_REST="gh: Not Found (HTTP 404)"
    GH_STUB_REST_EXIT=1
    run tool_issue_view '{"number": 999999, "repo": "shopware/shopware", "with_field_values": true}'
    assert_failure
    assert_output --partial "Not Found"
}

@test "issue_view with_field_values honors fallback when the REST call fails" {
    GH_STUB_REST="gh: Not Found (HTTP 404)"
    GH_STUB_REST_EXIT=1
    run tool_issue_view '{"number": 999999, "repo": "shopware/shopware", "with_field_values": true, "fallback": "no issue"}'
    assert_success
    assert_output "no issue"
}

@test "issue_view with_field_values rejects a malformed repository before calling the API" {
    run tool_issue_view '{"number": 19952, "owner": "shopware/extra", "repo": "shopware", "with_field_values": true}'
    assert_failure
    assert_output --partial "owner/repo"
    assert_equal "$(grep -c -- "api repos/" "${GH_ARGS_FILE}" 2>/dev/null || printf '0')" "0"
}

@test "issue_view with_field_values rejects a malformed repository even when fields are requested" {
    run tool_issue_view '{"number": 19952, "owner": "shopware/extra", "repo": "shopware", "with_field_values": true, "fields": "title", "fallback": "unavailable"}'
    assert_failure
    assert_output --partial "owner/repo"
}

@test "issue_view with_field_values fails on two values naming the same field" {
    GH_STUB_REST='{"number":1,"issue_field_values":[{"issue_field_name":"Priority","value":"High"},{"issue_field_name":"Priority","value":"Low"}]}'
    run tool_issue_view '{"number": 1, "repo": "shopware/shopware", "with_field_values": true}'
    assert_failure
    assert_output --partial "more than one value for Priority"
}

@test "issue_view with_field_values fails on a value with no field name" {
    GH_STUB_REST='{"number":1,"issue_field_values":[{"value":"High"}]}'
    run tool_issue_view '{"number": 1, "repo": "shopware/shopware", "with_field_values": true}'
    assert_failure
    assert_output --partial "no field name"
}

@test "issue_view with_field_values does not answer an undecodable response with fallback" {
    GH_STUB_REST='{"number":1,"issue_field_values":[{"value":"High"}]}'
    run tool_issue_view '{"number": 1, "repo": "shopware/shopware", "with_field_values": true, "fallback": "unavailable"}'
    assert_failure
    refute_output --partial "unavailable"
}

@test "issue_view with_field_values reports the API call's own exit status" {
    GH_STUB_REST="gh: Bad credentials (HTTP 401)"
    GH_STUB_REST_EXIT=4
    run tool_issue_view '{"number": 19952, "repo": "shopware/shopware", "with_field_values": true}'
    assert_equal "${status}" 4
}

@test "issue_view without with_field_values makes no REST call" {
    run tool_issue_view '{"number": 19952, "repo": "shopware/shopware", "fields": "title"}'
    assert_success
    assert_equal "$(printf '%s' "${output}" | jq -r '.title')" "Broken thing"
    run grep -c -- "api repos/" "${GH_ARGS_FILE}"
    assert_output "0"
}
