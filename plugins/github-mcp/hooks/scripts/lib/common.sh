#!/bin/bash
# Shared functions for MCP tool enforcement hooks
# ================================================
# This library provides common functionality for Claude Code, Codex, and pi hooks
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
#   HOOK_HOST - Host inferred from the hook environment (claude/codex/pi)
#   CONFIG_FILE - Path to loaded config file (or empty)
#   ENVIRONMENT - Environment from config (native/docker/vagrant/ddev)
#   ENFORCE_MCP_TOOLS - Whether to enforce MCP tools (true/false)

source "$(dirname "${BASH_SOURCE[0]}")/../../../shared/config-dirs.sh"

# Resolve the active host and project directory from hook input.
# Claude Code provides CLAUDE_PROJECT_DIR, which selects claude even when
# GITHUB_MCP_HOST is exported in the shell. Otherwise GITHUB_MCP_HOST=pi or
# codex names the host, and codex is assumed. Codex and pi provide cwd in the
# JSON payload.
resolve_hook_context() {
    local input="${1:-}"

    if [[ -n "${CLAUDE_PROJECT_DIR:-}" ]]; then
        HOOK_HOST="claude"
    elif [[ "${GITHUB_MCP_HOST:-}" == "pi" || "${GITHUB_MCP_HOST:-}" == "codex" ]]; then
        HOOK_HOST="${GITHUB_MCP_HOST}"
    else
        HOOK_HOST="codex"
    fi

    if [[ "$HOOK_HOST" == "claude" ]]; then
        PROJECT_DIR="${CLAUDE_PROJECT_DIR}"
    else
        PROJECT_DIR=""
        if command -v jq &>/dev/null; then
            PROJECT_DIR=$(printf '%s' "$input" | jq -r '.cwd // empty' 2>/dev/null || true)
        fi
    fi
}

# Find a project config in the host config directories, in the order
# github_mcp_config_dirs gives for the active host, then in the project root.
# First match wins.
# Args: $1 = config prefix
# Sets: CONFIG_FILE (global)
find_mcp_config() {
    local config_prefix="$1"
    CONFIG_FILE=""

    [[ -z "${PROJECT_DIR:-}" ]] && return 0

    local dir
    while IFS= read -r dir; do
        if [[ -f "${PROJECT_DIR}/${dir}/.mcp-${config_prefix}.json" ]]; then
            CONFIG_FILE="${PROJECT_DIR}/${dir}/.mcp-${config_prefix}.json"
            return 0
        fi
    done < <(github_mcp_config_dirs "${HOOK_HOST:-claude}")

    if [[ -f "${PROJECT_DIR}/.mcp-${config_prefix}.json" ]]; then
        CONFIG_FILE="${PROJECT_DIR}/.mcp-${config_prefix}.json"
    fi
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

    if [[ "${HOOK_HOST:-claude}" == "codex" || "${HOOK_HOST:-claude}" == "pi" ]]; then
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
