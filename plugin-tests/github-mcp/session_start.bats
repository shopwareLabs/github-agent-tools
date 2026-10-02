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

# ============================================================================
# Host pi (GITHUB_MCP_HOST=pi): tool-naming note and .pi/ config
# ============================================================================

PI_HOST_NOTE=$(<"${PLUGIN_DIR}/hooks/prompts/host-pi.md")

# Args: $1=project dir, $2=config dir relative to it ("" for the root), $3=JSON
write_project_config() {
    mkdir -p "${1}/${2}"
    printf '%s\n' "$3" > "${1}/${2}/.mcp-gh-tooling.json"
}

# Run session-start.sh in a fresh hook environment; $output is the parsed
# additionalContext. Empty host or Claude project dir leaves that variable unset.
# Args: $1=GITHUB_MCP_HOST, $2=CLAUDE_PROJECT_DIR, $3=payload cwd
run_session_start_context() {
    local -a hook_env=(-u GITHUB_MCP_HOST -u CLAUDE_PROJECT_DIR)
    [[ -n "$1" ]] && hook_env+=("GITHUB_MCP_HOST=$1")
    [[ -n "$2" ]] && hook_env+=("CLAUDE_PROJECT_DIR=$2")
    local payload
    mkdir -p "$3"
    payload=$(jq -cn --arg cwd "$3" '{cwd: $cwd}')
    run bash -c \
        'set -o pipefail; printf "%s" "$1" | env "${@:3}" bash "$2" | jq -r ".hookSpecificOutput.additionalContext"' \
        _ "$payload" "$SESSION_SCRIPT" "${hook_env[@]}"
}

# bats test_tags=host,pi
@test "pi directive ends with the pi tool-naming note after a blank line" {
    run_session_start_context "pi" "" "${BATS_TEST_TMPDIR}/pi-project"

    assert_success
    [[ "$output" == *$'\n\n'"${PI_HOST_NOTE}" ]]
}

@test "Claude directive omits the pi tool-naming note" {
    local project="${BATS_TEST_TMPDIR}/claude-project"

    run_session_start_context "" "$project" "$project"

    assert_success
    refute_output --partial "In pi, these tools are named"
}

@test "Codex directive omits the pi tool-naming note" {
    run_session_start_context "" "" "${BATS_TEST_TMPDIR}/codex-project"

    assert_success
    refute_output --partial "In pi, these tools are named"
}

@test "pi takes enable_write_server from .pi over .claude and .codex" {
    local project="${BATS_TEST_TMPDIR}/pi-project"
    write_project_config "$project" ".pi" '{"enable_write_server": true}'
    write_project_config "$project" ".claude" '{"enable_write_server": false}'
    write_project_config "$project" ".codex" '{"enable_write_server": false}'

    run_session_start_context "pi" "" "$project"

    assert_success
    assert_output --partial "## Write (gh-tooling-write)"
}

@test "pi takes labels from .pi over .claude and .codex" {
    local project="${BATS_TEST_TMPDIR}/pi-project"
    write_project_config "$project" ".pi" '{"labels": {"needs-triage": "New and not yet reviewed"}}'
    write_project_config "$project" ".claude" '{"labels": {"claude-label": "From .claude"}}'
    write_project_config "$project" ".codex" '{"labels": {"codex-label": "From .codex"}}'

    run_session_start_context "pi" "" "$project"

    assert_success
    assert_output --partial "- needs-triage: New and not yet reviewed"
    refute_output --partial "claude-label"
    refute_output --partial "codex-label"
}
