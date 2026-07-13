#!/usr/bin/env bats
# bats file_tags=github-mcp,write-server,gating
# Tests that the write server respects enable_write_server config flag
bats_require_minimum_version 1.11.0

load 'test_helper/common_setup'

SERVER_SCRIPT="${GH_SERVER_DIR}/server-write.sh"

# Helper: send a JSON-RPC request
send_jsonrpc() {
    local method="$1"
    local id="${2:-1}"
    local params="${3:-{}}"
    printf '{"jsonrpc":"2.0","id":%d,"method":"%s","params":%s}\n' "$id" "$method" "$params"
}

# Helper: run the server with a config and a request, capture last response
run_server_request() {
    local config_json="$1"
    local method="$2"

    export CLAUDE_PROJECT_DIR="${BATS_TEST_TMPDIR}"
    export PROJECT_ROOT="${BATS_TEST_TMPDIR}"
    if [[ -n "${config_json}" ]]; then
        echo "${config_json}" > "${BATS_TEST_TMPDIR}/.mcp-gh-tooling.json"
    fi

    local requests
    requests=$(send_jsonrpc "initialize" 1)
    requests+=$'\n'
    requests+=$(send_jsonrpc "${method}" 2)

    run bash -c 'echo "$1" | bash "$2" 2>/dev/null | tail -1' _ "${requests}" "${SERVER_SCRIPT}"
}

run_codex_server_request() {
    local project_root="$1"
    local requests="$2"

    printf '%s' "$requests" | env PROJECT_ROOT="$project_root" GITHUB_MCP_HOST=codex \
        bash "$SERVER_SCRIPT" 2>/dev/null | tail -1
}

@test "write server returns empty tools list when enable_write_server is false" {
    run_server_request '{"enable_write_server": false}' "tools/list"
    assert_success
    local tool_count
    tool_count=$(echo "$output" | jq '.result.tools | length')
    [[ "$tool_count" -eq 0 ]]
}

@test "write server returns empty tools list when enable_write_server is absent" {
    run_server_request '{"repo": "shopware/shopware"}' "tools/list"
    assert_success
    local tool_count
    tool_count=$(echo "$output" | jq '.result.tools | length')
    [[ "$tool_count" -eq 0 ]]
}

@test "write server returns tools when enable_write_server is true" {
    run_server_request '{"enable_write_server": true}' "tools/list"
    assert_success
    local tool_count
    tool_count=$(echo "$output" | jq '.result.tools | length')
    [[ "$tool_count" -gt 0 ]]
}

@test "write server returns empty tools list when no config file exists" {
    export CLAUDE_PROJECT_DIR="${BATS_TEST_TMPDIR}/no-config"
    mkdir -p "$CLAUDE_PROJECT_DIR"
    export PROJECT_ROOT="$CLAUDE_PROJECT_DIR"
    local requests
    requests=$(send_jsonrpc "initialize" 1)
    requests+=$'\n'
    requests+=$(send_jsonrpc "tools/list" 2)
    run bash -c 'echo "$1" | bash "$2" 2>/dev/null | tail -1' _ "${requests}" "${SERVER_SCRIPT}"
    assert_success
    local tool_count
    tool_count=$(echo "$output" | jq '.result.tools | length')
    [[ "$tool_count" -eq 0 ]]
}

@test "Codex server prefers .codex config over .claude config" {
    local project_root="${BATS_TEST_TMPDIR}/codex-priority"
    mkdir -p "${project_root}/.claude" "${project_root}/.codex"
    printf '%s\n' '{"enable_write_server": false}' > "${project_root}/.claude/.mcp-gh-tooling.json"
    printf '%s\n' '{"enable_write_server": true}' > "${project_root}/.codex/.mcp-gh-tooling.json"

    local requests
    requests=$(send_jsonrpc "initialize" 1)
    requests+=$'\n'
    requests+=$(send_jsonrpc "tools/list" 2)
    run run_codex_server_request "$project_root" "$requests"

    assert_success
    local tool_count
    tool_count=$(echo "$output" | jq '.result.tools | length')
    [[ "$tool_count" -gt 0 ]]
}
