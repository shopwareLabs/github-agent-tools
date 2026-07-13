#!/bin/bash
# Test fixtures for the github-mcp plugin suites.
#
# Naming: PLUGIN_NAME "github-mcp" is the plugin/directory identity. The MCP
# servers it ships keep the server identity "gh-tooling"/"gh-tooling-write",
# and the runtime config file is .mcp-gh-tooling.json — do not conflate them.

load "${BATS_TEST_DIRNAME}/../test_helper/common_setup"

# Plugin under test — the one line to change when copying this helper for a
# new plugin.
PLUGIN_NAME="github-mcp"

# Standard plugin layout, derived from PLUGIN_NAME. Consumed by the .bats
# files instead of re-hardcoding plugins/<name>/ paths per file.
PLUGIN_DIR="${REPO_ROOT}/plugins/${PLUGIN_NAME}"
SCRIPTS_DIR="${PLUGIN_DIR}/hooks/scripts"
SESSION_SCRIPT="${SCRIPTS_DIR}/session-start.sh"
SHARED_DIR="${PLUGIN_DIR}/shared"

# This plugin's MCP server component roots.
GH_SERVER_DIR="${PLUGIN_DIR}/mcp-server-gh"
GH_LIB_DIR="${GH_SERVER_DIR}/lib"

# Default setup: enforcement enabled, written under the server/config identity.
# Override CONFIG_PREFIX in a test file to target a different config file, or
# define a custom setup() (tool-function suites do) to replace this entirely.
setup() {
    setup_config "${CONFIG_PREFIX:-gh-tooling}" '{"enforce_mcp_tools": true}'
}
