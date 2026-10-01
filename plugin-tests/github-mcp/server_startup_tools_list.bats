#!/usr/bin/env bats
# bats file_tags=github-mcp,startup
# A missing or unreadable tools list stops the server at startup.
#
# mcpserver_core.sh reads MCP_TOOLS_LIST_FILE lazily, once per tools/list or
# tools/call request, so nothing else catches a corrupt or missing list before
# the first call — the server would otherwise start cleanly and then fail
# every tools/list and tools/call request it receives.
bats_require_minimum_version 1.11.0

load 'test_helper/common_setup'

setup() {
    # A private copy: these tests corrupt tools-read.json, and the real
    # plugin directory is shared with every other suite in this run.
    PLUGIN_COPY="${BATS_TEST_TMPDIR}/plugin"
    cp -R "${PLUGIN_DIR}" "${PLUGIN_COPY}"
    PROJECT_DIR="${BATS_TEST_TMPDIR}/project"
    mkdir -p "${PROJECT_DIR}"
}

# Pipe one initialize request into the copied read server and capture both
# streams plus the exit status.
run_server() {
    printf '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}\n' \
        | env PROJECT_ROOT="${PROJECT_DIR}" bash "${PLUGIN_COPY}/mcp-server-gh/server-read.sh"
}

@test "server-read.sh refuses to start when tools-read.json is invalid JSON" {
    printf '%s\n' '{not valid json' > "${PLUGIN_COPY}/mcp-server-gh/tools-read.json"

    run run_server
    assert_failure
    refute_output --partial '"jsonrpc"'
    assert_output --partial "tools-read.json"
}

@test "server-read.sh refuses to start when tools-read.json holds more than one JSON document" {
    printf '%s\n%s\n' '{"tools":[]}' '{"tools":[]}' > "${PLUGIN_COPY}/mcp-server-gh/tools-read.json"

    run run_server
    assert_failure
    refute_output --partial '"jsonrpc"'
    assert_output --partial "tools-read.json"
}

@test "server-read.sh refuses to start when tools-read.json is missing" {
    rm -f "${PLUGIN_COPY}/mcp-server-gh/tools-read.json"

    run run_server
    assert_failure
    refute_output --partial '"jsonrpc"'
    assert_output --partial "tools-read.json"
}

@test "server-read.sh still answers initialize when tools-read.json is valid" {
    run run_server
    assert_success
    assert_output --partial '"jsonrpc"'
}
