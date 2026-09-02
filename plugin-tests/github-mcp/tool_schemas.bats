#!/usr/bin/env bats
# bats file_tags=github-mcp,tool-schemas
# The tool schemas this plugin ships, checked against the vendored SDK
# validator that enforces them at call time.
#
# The SDK owns the validator's own semantics (shopwareLabs/bash-mcp-sdk,
# tests/mcp_argument_validation.bats). What only this repository can check is
# the seam: whether tools-read.json and tools-write.json describe the calls
# clients actually make, now that a declared `type` is refused when it does
# not match.
bats_require_minimum_version 1.11.0

load 'test_helper/common_setup'

setup() {
    READ_TOOLS="${GH_SERVER_DIR}/tools-read.json"
    WRITE_TOOLS="${GH_SERVER_DIR}/tools-write.json"

    MCP_LOG_FILE="${BATS_TEST_TMPDIR}/server.log"
    MCP_CONFIG_FILE="/dev/null"
    PROJECT_ROOT="${BATS_TEST_TMPDIR}"
    export MCP_LOG_FILE MCP_CONFIG_FILE PROJECT_ROOT
}

teardown() {
    unset MCP_LOG_FILE MCP_CONFIG_FILE PROJECT_ROOT MCP_TOOLS_LIST_FILE
}

# Source the vendored SDK against one tool list. Deferred to the test body so
# each test picks the read or the write registry.
load_validator_for() {
    export MCP_TOOLS_LIST_FILE="$1"
    source "${SHARED_DIR}/mcpserver_core.sh"
}

# --- schema shape ---

@test "an identifier parameter accepts the number written as a string" {
    # Clients send issue and PR numbers both ways. An identifier declared
    # "integer" alone makes the string form an isError once the validator
    # enforces type, so every numeric identifier declares the union.
    # String-only identifiers (commit_id, a SHA) are not numbers and are left
    # alone.
    run jq -r '.tools[] | .name as $tool | (.inputSchema.properties // {}) | to_entries[]
        | select(.key == "number" or (.key | endswith("_id")) or (.key | endswith("_number")))
        | select(.value.type == "integer")
        | "\($tool).\(.key) is integer-only"' "$READ_TOOLS" "$WRITE_TOOLS"

    assert_success
    assert_output ""
}

@test "a required parameter is declared in the tool's own properties" {
    # A name in `required` but not in `properties` makes the tool uncallable
    # under additionalProperties:false — supplying it is rejected as unknown,
    # omitting it as missing.
    run jq -r '.tools[] | .name as $tool | .inputSchema as $schema
        | ($schema.required // [])[] | . as $field
        | select((($schema.properties // {}) | has($field)) | not)
        | "\($tool) requires \($field) but declares no such property"' "$READ_TOOLS" "$WRITE_TOOLS"

    assert_success
    assert_output ""
}

@test "a parameter's default satisfies the constraints declared beside it" {
    # A default outside its own enum, or of the wrong type, documents a call
    # the validator refuses.
    run jq -r '.tools[] | .name as $tool | (.inputSchema.properties // {}) | to_entries[]
        | .key as $field | .value as $prop
        | select($prop.default != null)
        | select(
            ($prop.enum != null and ($prop.enum | index($prop.default)) == null)
            or (($prop.type | type) == "string" and (
                if $prop.type == "integer"
                then ($prop.default | type) != "number"
                else ($prop.default | type) != $prop.type
                end))
          )
        | "\($tool).\($field) default \($prop.default | tojson) violates its own schema"' \
        "$READ_TOOLS" "$WRITE_TOOLS"

    assert_success
    assert_output ""
}

# --- validator round-trip against the shipped registries ---

@test "a read tool accepts an issue number sent as a string" {
    load_validator_for "$READ_TOOLS"

    run validate_tool_arguments "issue_view" '{"number": "339", "repo": "shopwareLabs/github-agent-tools"}'

    assert_success
    assert_output ""
}

@test "a read tool accepts a project number sent as a string" {
    load_validator_for "$READ_TOOLS"

    run validate_tool_arguments "project_view" '{"number": "12", "owner": "shopwareLabs"}'

    assert_success
    assert_output ""
}

@test "a write tool accepts sub-issue numbers sent as strings" {
    load_validator_for "$WRITE_TOOLS"

    run validate_tool_arguments "sub_issue_add" '{"issue_number": "339", "sub_issue_number": "340"}'

    assert_success
    assert_output ""
}

@test "a paging limit sent as a string is refused, naming the parameter" {
    # The counterpart to the identifier union: limit and max_lines are
    # integer-only on purpose, so the string form must fail rather than reach
    # gh as an unvalidated value.
    load_validator_for "$READ_TOOLS"

    run validate_tool_arguments "pr_list" '{"limit": "20"}'

    assert_failure
    assert_output --partial "limit expected integer, got string"
}
