#!/usr/bin/env bats
# bats file_tags=github-mcp,read-tools
# Tests for the issue_schema read tool
bats_require_minimum_version 1.11.0

load 'test_helper/common_setup'

TYPES_JSON='[{"id":125714,"name":"Bug","description":"Something broke","color":"red","is_enabled":true},{"id":25328944,"name":"Improvement","description":"Better now","color":"green","is_enabled":true}]'
FIELDS_JSON='[{"id":8847,"name":"Priority","description":"How urgent","data_type":"single_select","visibility":"all","options":[{"id":12296,"name":"High","color":"red"},{"id":12298,"name":"Low","color":"green"}]},{"id":8848,"name":"Start date","description":"When work begins","data_type":"date","visibility":"organization_members_only"}]'

setup() {
    log() { :; }
    GH_DEFAULT_REPO="shopware/shopware"
    GH_TOOLING_CONFIG_FILE=""
    source "${GH_LIB_DIR}/common.sh"
    source "${GH_LIB_DIR}/issue_schema.sh"

    GH_ARGS_FILE="${BATS_TEST_TMPDIR}/gh_args"

    # Stub responds per endpoint: the tool makes two gh api calls per run.
    gh() {
        printf '%s\n' "$@" >> "${GH_ARGS_FILE}"
        case "$*" in
            *issue-types*)
                [[ -n "${GH_STUB_TYPES_EXIT:-}" ]] && return "${GH_STUB_TYPES_EXIT}"
                printf '%s\n' "${GH_STUB_TYPES}"
                ;;
            *issue-fields*)
                [[ -n "${GH_STUB_FIELDS_EXIT:-}" ]] && return "${GH_STUB_FIELDS_EXIT}"
                printf '%s\n' "${GH_STUB_FIELDS}"
                ;;
            *)
                printf '%s\n' "${GH_STUB_REPO_VIEW:-}"
                ;;
        esac
        return 0
    }
    GH_STUB_TYPES="${TYPES_JSON}"
    GH_STUB_FIELDS="${FIELDS_JSON}"
    GH_STUB_TYPES_EXIT=""
    GH_STUB_FIELDS_EXIT=""
}

@test "issue_schema returns types and fields for the default repo owner" {
    run tool_issue_schema '{}'
    assert_success
    assert_equal "$(printf '%s' "${output}" | jq -r '.org')" "shopware"
    assert_equal "$(printf '%s' "${output}" | jq -r '[.types[].name] | join(",")')" "Bug,Improvement"
    assert_equal "$(printf '%s' "${output}" | jq -r '[.fields[].name] | join(",")')" "Priority,Start date"
}

@test "issue_schema queries the organization endpoints" {
    run tool_issue_schema '{"org": "shopware"}'
    assert_success
    run grep -x -- 'orgs/shopware/issue-types' "${GH_ARGS_FILE}"
    assert_success
    run grep -x -- 'orgs/shopware/issue-fields' "${GH_ARGS_FILE}"
    assert_success
}

@test "issue_schema keeps single-select options and omits them for other data types" {
    run tool_issue_schema '{"field": "Priority"}'
    assert_success
    assert_equal "$(printf '%s' "${output}" | jq -r '[.fields[0].options[].name] | join(",")')" "High,Low"

    run tool_issue_schema '{"field": "Start date"}'
    assert_success
    assert_equal "$(printf '%s' "${output}" | jq -r '.fields[0] | has("options")')" "false"
}

@test "issue_schema type filter matches case-insensitively and narrows only types" {
    run tool_issue_schema '{"type": "bug"}'
    assert_success
    assert_equal "$(printf '%s' "${output}" | jq -r '[.types[].name] | join(",")')" "Bug"
    assert_equal "$(printf '%s' "${output}" | jq -r '.fields | length')" "2"
}

@test "issue_schema derives the org from a repo parameter" {
    run tool_issue_schema '{"repo": "some-other-org/some-repo"}'
    assert_success
    assert_equal "$(printf '%s' "${output}" | jq -r '.org')" "some-other-org"
}

@test "issue_schema errors on an unknown type instead of returning an empty list" {
    run tool_issue_schema '{"type": "Nope"}'
    assert_failure
    assert_output --partial "issue type 'Nope' not found"
}

@test "issue_schema errors on an unknown field instead of returning an empty list" {
    run tool_issue_schema '{"field": "Nope"}'
    assert_failure
    assert_output --partial "issue field 'Nope' not found"
}

@test "issue_schema propagates a failing types call" {
    GH_STUB_TYPES_EXIT=1
    run tool_issue_schema '{"org": "cli"}'
    assert_failure
}

@test "issue_schema propagates a failing fields call" {
    GH_STUB_FIELDS_EXIT=1
    run tool_issue_schema '{"org": "cli"}'
    assert_failure
}

@test "issue_schema returns the fallback when a call fails" {
    GH_STUB_TYPES_EXIT=1
    run tool_issue_schema '{"org": "cli", "fallback": "no schema"}'
    assert_success
    assert_output "no schema"
}

@test "issue_schema applies jq_filter to the merged document" {
    run tool_issue_schema '{"jq_filter": "[.fields[].name]"}'
    assert_success
    assert_equal "$(printf '%s' "${output}" | jq -r 'join(",")')" "Priority,Start date"
}

@test "issue_schema rejects an invalid jq_filter" {
    run tool_issue_schema '{"jq_filter": "[.fields["}'
    assert_failure
    assert_output --partial "Invalid jq_filter"
}

@test "issue_schema prefers org over owner and a repo parameter" {
    run tool_issue_schema '{"org": "from-org", "owner": "from-owner", "repo": "from-repo/x"}'
    assert_success
    assert_equal "$(printf '%s' "${output}" | jq -r '.org')" "from-org"
}

@test "issue_schema prefers owner over a repo parameter" {
    run tool_issue_schema '{"owner": "from-owner", "repo": "from-repo/x"}'
    assert_success
    assert_equal "$(printf '%s' "${output}" | jq -r '.org')" "from-owner"
}

@test "issue_schema with suppress_errors returns no error text" {
    GH_STUB_TYPES_EXIT=1
    run tool_issue_schema '{"org": "cli", "suppress_errors": true}'
    assert_failure
    assert_output ""
}

@test "issue_schema keeps working when a field carries a null options key" {
    GH_STUB_FIELDS='[{"id":1,"name":"Priority","data_type":"single_select","options":null}]'
    run tool_issue_schema '{"org": "acme"}'
    assert_success
    assert_equal "$(printf '%s' "${output}" | jq -r '.fields[0] | has("options")')" "false"
}

@test "issue_schema rejects an org that is not a login" {
    run tool_issue_schema '{"org": "../../repos/victim/private"}'
    assert_failure
    assert_output --partial "invalid organization"
    [ ! -f "${GH_ARGS_FILE}" ]
}

@test "fallback does not mask an unresolvable org" {
    GH_DEFAULT_REPO=""
    run tool_issue_schema '{"org": "!!", "fallback": "ok"}'
    assert_failure
    assert_output --partial "invalid organization"
}
