#!/bin/bash
# Core test fixtures shared across all plugin hook tests

# Calculate repo root by walking up until we find .bats/ directory
_get_repo_root() {
    local test_dir="${BATS_TEST_DIRNAME}"
    while [[ ! -d "${test_dir}/.bats" ]] && [[ "${test_dir}" != "/" ]]; do
        test_dir="$(dirname "$test_dir")"
    done
    printf '%s\n' "$test_dir"
}

REPO_ROOT="$(_get_repo_root)"

# Load BATS helper libraries
load "${REPO_ROOT}/.bats/bats-support/load"
load "${REPO_ROOT}/.bats/bats-assert/load"

# Run a hook script with a command and capture output. HOOK_CWD allows tests to
# exercise Codex payloads without CLAUDE_PROJECT_DIR.
# Note: SCRIPTS_DIR must be set by the plugin-specific helper
run_hook() {
    local script="$1"
    local command="$2"

    if [[ -z "${SCRIPTS_DIR:-}" ]]; then
        fail "SCRIPTS_DIR must be set before calling run_hook"
    fi

    local payload
    payload=$(jq -cn \
        --arg cmd "$command" \
        --arg cwd "${HOOK_CWD:-${CLAUDE_PROJECT_DIR:-}}" \
        '{cwd: $cwd, tool_input: {command: $cmd}}')

    run bash -c 'printf "%s" "$1" | bash "$2"' _ "$payload" "${SCRIPTS_DIR}/${script}"
}

# Assert that a hook script blocks a command and suggests a specific MCP tool
# Args: $1=script name, $2=bash command, $3=expected suggestion substring
assert_hook_blocks() {
    local script="$1" command="$2" suggestion="$3"
    run_hook "$script" "$command"
    assert_failure 2
    assert_output --partial "$suggestion"
}

# Write a temporary MCP config file and point CLAUDE_PROJECT_DIR at it.
# Args: $1=config prefix (the server/config identity, e.g. "gh-tooling"
#       → .mcp-gh-tooling.json), $2=JSON content
setup_config() {
    local prefix="$1"
    local content="$2"
    export CLAUDE_PROJECT_DIR="${BATS_TEST_TMPDIR}"
    printf '%s\n' "$content" > "${BATS_TEST_TMPDIR}/.mcp-${prefix}.json"
}

# Write a temporary config under the Codex project directory and make hook
# helpers pass that project as cwd.
setup_codex_config() {
    local prefix="$1"
    local content="$2"
    export CODEX_PROJECT_DIR="${BATS_TEST_TMPDIR}/codex-project"
    export HOOK_CWD="${CODEX_PROJECT_DIR}"
    unset CLAUDE_PROJECT_DIR
    mkdir -p "${CODEX_PROJECT_DIR}/.codex"
    printf '%s\n' "$content" > "${CODEX_PROJECT_DIR}/.codex/.mcp-${prefix}.json"
}

# Default teardown for suites using setup_config; test files may override.
teardown() {
    unset CLAUDE_PROJECT_DIR
    unset CODEX_PROJECT_DIR
    unset HOOK_CWD
}
