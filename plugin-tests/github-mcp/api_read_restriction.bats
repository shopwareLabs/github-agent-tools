#!/usr/bin/env bats
# bats file_tags=github-mcp,api-restriction
# Tests that tool_api_read rejects non-GET methods
bats_require_minimum_version 1.11.0

load 'test_helper/common_setup'

setup() {
    log() { :; }
    GH_DEFAULT_REPO="shopware/shopware"
    GH_TOOLING_CONFIG_FILE=""
    source "${GH_LIB_DIR}/common.sh"
    source "${GH_LIB_DIR}/api.sh"

    gh() { gh_stub_respond; }
    reset_gh_stub
}

@test "tool_api_read with suppress_errors returns no error text when the call fails" {
    # gh api prints an HTTP error's JSON body on stdout and its summary on stderr.
    GH_STUB_OUTPUT='{"message":"Not Found","documentation_url":"https://docs.github.com/rest","status":"404"}'
    GH_STUB_STDERR="gh: Not Found (HTTP 404)"
    GH_STUB_EXIT=1
    run tool_api_read '{"endpoint": "repos/shopware/shopware/pulls/0", "suppress_errors": true}'
    assert_failure
    assert_output ""
}

@test "tool_api_read allows GET method" {
    GH_STUB_OUTPUT='{"id": 1}'
    run tool_api_read '{"endpoint": "repos/shopware/shopware/pulls/123", "method": "GET"}'
    assert_success
}

@test "tool_api_read defaults to GET when method omitted" {
    GH_STUB_OUTPUT='{"id": 1}'
    run tool_api_read '{"endpoint": "repos/shopware/shopware/pulls/123"}'
    assert_success
}

@test "tool_api_read rejects POST method" {
    run tool_api_read '{"endpoint": "repos/shopware/shopware/pulls", "method": "POST"}'
    assert_failure
    assert_output --partial "read-only"
    assert_output --partial "GET"
}

@test "tool_api_read rejects PATCH method" {
    run tool_api_read '{"endpoint": "repos/shopware/shopware/pulls/123", "method": "PATCH"}'
    assert_failure
    assert_output --partial "read-only"
}

@test "tool_api_read rejects PUT method" {
    run tool_api_read '{"endpoint": "repos/shopware/shopware/pulls/123/merge", "method": "PUT"}'
    assert_failure
    assert_output --partial "read-only"
}

@test "tool_api_read rejects DELETE method" {
    run tool_api_read '{"endpoint": "repos/shopware/shopware/pulls/123", "method": "DELETE"}'
    assert_failure
    assert_output --partial "read-only"
}

@test "tool_api (write) allows POST method" {
    GH_STUB_OUTPUT='{"id": 1}'
    run tool_api '{"endpoint": "repos/shopware/shopware/pulls", "method": "POST"}'
    assert_success
}
