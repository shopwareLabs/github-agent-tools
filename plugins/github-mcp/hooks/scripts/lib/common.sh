#!/bin/bash
# Shared functions for MCP tool enforcement hooks
# ================================================
# This library provides common functionality for Claude Code and Codex hooks
# that block bash commands in favor of MCP tools.
#
# Usage:
#   source "${SCRIPT_DIR}/lib/common.sh"
#   parse_hook_input
#   load_mcp_config "php-tooling"  # or "js-tooling"
#   # ... pattern matching ...
#   block_tool "mcp__php-tooling__phpstan_analyze" "Description"

# Global variables set by this library:
#   HOOK_INPUT - Raw hook input read from stdin
#   COMMAND - The bash command being checked
#   PROJECT_DIR - Project directory reported by the active host
#   HOOK_HOST - Host inferred from the hook environment (claude/codex)
#   CONFIG_FILE - Path to loaded config file (or empty)
#   ENVIRONMENT - Environment from config (native/docker/vagrant/ddev)
#   ENFORCE_MCP_TOOLS - Whether to enforce MCP tools (true/false)

# Resolve the active host and project directory from hook input.
# Claude Code provides CLAUDE_PROJECT_DIR; Codex provides cwd in the JSON payload.
resolve_hook_context() {
    local input="${1:-}"

    if [[ -n "${CLAUDE_PROJECT_DIR:-}" ]]; then
        HOOK_HOST="claude"
        PROJECT_DIR="${CLAUDE_PROJECT_DIR}"
    else
        HOOK_HOST="codex"
        PROJECT_DIR=""
        if command -v jq &>/dev/null; then
            PROJECT_DIR=$(printf '%s' "$input" | jq -r '.cwd // empty' 2>/dev/null || true)
        fi
    fi
}

# Find a project config, preferring the active host's directory and then the
# other supported host's directory before the project-root fallback.
# Args: $1 = config prefix
# Sets: CONFIG_FILE (global)
find_mcp_config() {
    local config_prefix="$1"
    local -a locations
    CONFIG_FILE=""

    [[ -z "${PROJECT_DIR:-}" ]] && return 0

    if [[ "${HOOK_HOST:-claude}" == "codex" ]]; then
        locations=(
            ".codex/.mcp-${config_prefix}.json"
            ".claude/.mcp-${config_prefix}.json"
            ".mcp-${config_prefix}.json"
        )
    else
        locations=(
            ".claude/.mcp-${config_prefix}.json"
            ".codex/.mcp-${config_prefix}.json"
            ".mcp-${config_prefix}.json"
        )
    fi

    local location
    for location in "${locations[@]}"; do
        if [[ -f "${PROJECT_DIR}/${location}" ]]; then
            CONFIG_FILE="${PROJECT_DIR}/${location}"
            break
        fi
    done
}

# Parse hook input from stdin
# Sets: HOOK_INPUT, COMMAND, PROJECT_DIR, HOOK_HOST (globals)
# Exits 0 if command is empty
parse_hook_input() {
    HOOK_INPUT=$(cat)
    resolve_hook_context "$HOOK_INPUT"
    COMMAND=$(printf '%s' "$HOOK_INPUT" | jq -r '.tool_input.command // empty')
    if [[ -z "$COMMAND" ]]; then
        exit 0
    fi
}

# Load MCP config from project directory
# Args: $1 = config prefix (e.g., "php-tooling", "js-tooling")
# Sets: CONFIG_FILE, ENVIRONMENT, ENFORCE_MCP_TOOLS (globals)
# Exits 0 if enforcement is disabled
load_mcp_config() {
    local config_prefix="$1"
    ENVIRONMENT=""
    ENFORCE_MCP_TOOLS="true"

    find_mcp_config "$config_prefix"

    if [[ -n "$CONFIG_FILE" ]]; then
        ENVIRONMENT=$(jq -r '.environment // empty' "$CONFIG_FILE" 2>/dev/null || true)
        # Check if MCP tool enforcement is disabled (default: true)
        # Note: jq's // operator treats false as falsy, so we check explicitly
        local enforce_value
        enforce_value=$(jq -r 'if .enforce_mcp_tools == false then "false" else "true" end' "$CONFIG_FILE" 2>/dev/null || echo "true")
        if [[ "$enforce_value" == "false" ]]; then
            ENFORCE_MCP_TOOLS="false"
        fi
    fi

    if [[ "$ENFORCE_MCP_TOOLS" == "false" ]]; then
        exit 0
    fi
}

# Block a tool with formatted message
# Args: $1 = full MCP tool name (e.g., "mcp__php-tooling__phpstan_analyze")
#       $2 = description of what to use instead
# Outputs to stderr and exits with code 2
block_tool() {
    local tool="$1"
    local description="$2"
    local display_tool="$tool"

    if [[ "${HOOK_HOST:-claude}" == "codex" ]]; then
        display_tool="${display_tool//gh-tooling-write/gh_tooling_write}"
        display_tool="${display_tool//gh-tooling/gh_tooling}"
    else
        display_tool="${display_tool//mcp__gh-tooling-write__/mcp__plugin_github-mcp_gh-tooling-write__}"
        display_tool="${display_tool//mcp__gh-tooling__/mcp__plugin_github-mcp_gh-tooling__}"
    fi

    {
        echo "🤖 Down, model! Use the ${display_tool} instead!"
        echo ""
        echo "Bad command detected: ${COMMAND}"
        echo ""
        echo "You were trained better than this! ${description}"
        echo ""
        if [[ -n "$ENVIRONMENT" ]]; then
            echo "Good models use MCP tools because they:"
            echo "  🔧 Handle your '${ENVIRONMENT}' environment automatically"
            echo "  🔧 Use project configuration without extra flags"
            echo "  🔧 Earn you treats (user approval)"
        else
            echo "Good models use MCP tools because they:"
            echo "  🔧 Handle environment detection (native/docker/vagrant/ddev)"
            echo "  🔧 Run in correct directory context automatically"
            echo "  🔧 Earn you treats (user approval)"
        fi
    } >&2
    exit 2
}
