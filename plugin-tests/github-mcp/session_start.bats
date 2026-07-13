#!/usr/bin/env bats
# bats file_tags=github-mcp,session-start
bats_require_minimum_version 1.11.0

load 'test_helper/common_setup'

run_session_start() {
    local payload
    payload=$(jq -cn --arg cwd "${HOOK_CWD:-${CLAUDE_PROJECT_DIR:-}}" '{cwd: $cwd}')
    run bash -c 'printf "%s" "$1" | bash "$2"' _ "$payload" "$SESSION_SCRIPT"
}

# ============================================================================
# JSON output structure
# ============================================================================

# bats test_tags=output
@test "outputs valid JSON with additionalContext" {
    run_session_start
    assert_success
    # Valid JSON
    echo "$output" | jq -e . >/dev/null
    # Correct structure
    echo "$output" | jq -e '.hookSpecificOutput.hookEventName == "SessionStart"'
    echo "$output" | jq -e '.hookSpecificOutput.additionalContext | length > 0'
}

@test "additionalContext is a non-empty string" {
    run_session_start
    assert_success
    echo "$output" | jq -e '.hookSpecificOutput.additionalContext | type == "string"'
    echo "$output" | jq -e '.hookSpecificOutput.additionalContext | length > 0'
}

# ============================================================================
# enforce_mcp_tools: false — disables SessionStart output
# ============================================================================

# bats test_tags=config
@test "silent when enforcement disabled" {
    setup_config "gh-tooling" '{"enforce_mcp_tools": false}'
    run_session_start
    assert_success
    assert_output ""
}

@test "outputs when no config file exists" {
    export CLAUDE_PROJECT_DIR="${BATS_TEST_TMPDIR}/empty"
    mkdir -p "$CLAUDE_PROJECT_DIR"
    run_session_start
    assert_success
    echo "$output" | jq -e '.hookSpecificOutput.additionalContext | length > 0'
}

@test "Codex cwd loads .codex config and disables SessionStart output" {
    setup_codex_config "gh-tooling" '{"enforce_mcp_tools": false}'
    run_session_start
    assert_success
    assert_output ""
}
