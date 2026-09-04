#!/usr/bin/env bats
# bats file_tags=github-mcp,mcp-tools
# Tests that the read tools whose gh subcommand only emits JSON under --json
# reject a jq_filter passed without fields, and still work when both are given.
bats_require_minimum_version 1.11.0

load 'test_helper/common_setup'

setup() {
    log() { :; }

    GH_DEFAULT_REPO="shopware/shopware"
    GH_TOOLING_CONFIG_FILE=""

    source "${GH_LIB_DIR}/common.sh"
    source "${GH_LIB_DIR}/pr.sh"
    source "${GH_LIB_DIR}/run.sh"
    source "${GH_LIB_DIR}/issue.sh"
    source "${GH_LIB_DIR}/search.sh"

    GH_CALLED_FILE="${BATS_TEST_TMPDIR}/gh_called"

    gh() {
        touch "${GH_CALLED_FILE}"
        [[ -n "${GH_STUB_OUTPUT:-}" ]] && printf '%s\n' "${GH_STUB_OUTPUT}"
        return "${GH_STUB_EXIT:-0}"
    }

    GH_STUB_OUTPUT=""
    GH_STUB_EXIT=0
}

# Assert a tool rejects jq_filter without fields, before reaching gh.
# Usage: assert_requires_fields <tool_fn> <args_json>
assert_requires_fields() {
    local fn="$1" args="$2"
    run "${fn}" "${args}"
    assert_failure
    assert_output --partial "jq_filter"
    assert_output --partial "fields"
    [[ -e "${GH_CALLED_FILE}" ]] && {
        echo "gh was invoked despite the rejected arguments"
        return 1
    }
    return 0
}

# =============================================================================
# jq_filter without fields is rejected
# =============================================================================

_test_reject_pr_view()    { assert_requires_fields tool_pr_view    '{"number":"123","jq_filter":"{c: .state}"}'; }
_test_reject_pr_list()    { assert_requires_fields tool_pr_list    '{"jq_filter":"[.[].number]"}'; }
_test_reject_run_view()   { assert_requires_fields tool_run_view   '{"run_id":"123","jq_filter":"{c: .conclusion}"}'; }
_test_reject_run_list()   { assert_requires_fields tool_run_list   '{"jq_filter":"[.[].databaseId]"}'; }
_test_reject_issue_view() { assert_requires_fields tool_issue_view '{"number":"42","jq_filter":"{t: .title}"}'; }
_test_reject_issue_list() { assert_requires_fields tool_issue_list '{"jq_filter":"[.[].number]"}'; }
_test_reject_search()     { assert_requires_fields tool_search     '{"search":"is:open","jq_filter":"[.[].number]"}'; }

bats_test_function --description "pr_view: jq_filter without fields is rejected"    -- _test_reject_pr_view
bats_test_function --description "pr_list: jq_filter without fields is rejected"    -- _test_reject_pr_list
bats_test_function --description "run_view: jq_filter without fields is rejected"   -- _test_reject_run_view
bats_test_function --description "run_list: jq_filter without fields is rejected"   -- _test_reject_run_list
bats_test_function --description "issue_view: jq_filter without fields is rejected" -- _test_reject_issue_view
bats_test_function --description "issue_list: jq_filter without fields is rejected" -- _test_reject_issue_list
bats_test_function --description "search: jq_filter without fields is rejected"     -- _test_reject_search

@test "run_view names both the cause and a usable fields value" {
    run tool_run_view '{"run_id":"123","jq_filter":"{c: .conclusion}"}'
    assert_failure
    assert_output --partial "jq_filter requires fields on run_view"
    assert_output --partial "conclusion,status,headSha"
}

# =============================================================================
# jq_filter together with fields still works
# =============================================================================

@test "pr_view applies jq_filter when fields is given" {
    GH_STUB_OUTPUT='{"number":123,"state":"OPEN"}'
    run tool_pr_view '{"number":"123","fields":"number,state","jq_filter":".state"}'
    assert_success
    assert_output '"OPEN"'
}

@test "pr_list applies jq_filter when fields is given" {
    GH_STUB_OUTPUT='[{"number":1},{"number":2}]'
    run tool_pr_list '{"fields":"number","jq_filter":"[.[].number]"}'
    assert_success
    assert_output "$(printf '[\n  1,\n  2\n]')"
}

@test "run_view applies jq_filter when fields is given" {
    GH_STUB_OUTPUT='{"conclusion":"failure","headSha":"60e5456d"}'
    run tool_run_view '{"run_id":"123","fields":"conclusion,headSha","jq_filter":"{c: .conclusion, sha: .headSha}"}'
    assert_success
    assert_output --partial '"c": "failure"'
    assert_output --partial '"sha": "60e5456d"'
}

@test "run_list applies jq_filter when fields is given" {
    GH_STUB_OUTPUT='[{"databaseId":7}]'
    run tool_run_list '{"fields":"databaseId","jq_filter":"[.[].databaseId]"}'
    assert_success
    assert_output "$(printf '[\n  7\n]')"
}

@test "issue_view applies jq_filter when fields is given" {
    GH_STUB_OUTPUT='{"number":42,"title":"Broken"}'
    run tool_issue_view '{"number":"42","fields":"number,title","jq_filter":".title"}'
    assert_success
    assert_output '"Broken"'
}

@test "issue_list applies jq_filter when fields is given" {
    GH_STUB_OUTPUT='[{"number":42}]'
    run tool_issue_list '{"fields":"number","jq_filter":"[.[].number]"}'
    assert_success
    assert_output "$(printf '[\n  42\n]')"
}

@test "search applies jq_filter when fields is given" {
    GH_STUB_OUTPUT='[{"number":9,"title":"Found"}]'
    run tool_search '{"search":"is:open","fields":"number,title","jq_filter":"[.[].title]"}'
    assert_success
    assert_output "$(printf '[\n  "Found"\n]')"
}

# =============================================================================
# Tools that always request a field set are unaffected
# =============================================================================

@test "issue_view accepts jq_filter without fields under with_field_values" {
    GH_STUB_OUTPUT='{"type":{"name":"Bug"},"issue_field_values":[]}'
    run tool_issue_view '{"number":"42","with_field_values":true,"jq_filter":".type"}'
    assert_success
    assert_output '"Bug"'
}

@test "search_code accepts jq_filter without fields" {
    GH_STUB_OUTPUT='[{"path":"src/Foo.php"}]'
    run tool_search_code '{"search":"addClass","jq_filter":"[.[].path]"}'
    assert_success
    assert_output "$(printf '[\n  "src/Foo.php"\n]')"
}

@test "search_commits accepts jq_filter without fields" {
    GH_STUB_OUTPUT='[{"sha":"60e5456d"}]'
    run tool_search_commits '{"search":"fix","jq_filter":"[.[].sha]"}'
    assert_success
    assert_output "$(printf '[\n  "60e5456d"\n]')"
}

@test "search_repos accepts jq_filter without fields" {
    GH_STUB_OUTPUT='[{"fullName":"shopware/shopware"}]'
    run tool_search_repos '{"search":"shopware","jq_filter":"[.[].fullName]"}'
    assert_success
    assert_output "$(printf '[\n  "shopware/shopware"\n]')"
}
