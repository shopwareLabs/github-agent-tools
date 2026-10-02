#!/usr/bin/env bash
# Host config directory order, shared by the hooks and the MCP servers.

#######################################
# List the host config directories in priority order: the active host's
# directory first, then the remaining ones of the fixed order .claude, .codex,
# .pi. The project root is not listed; callers handle it.
# Arguments:
#   Host: pi, codex, or claude. Any other value uses the claude order.
# Outputs:
#   One directory name per line on stdout, highest priority first.
#######################################
github_mcp_config_dirs() {
    local first
    case "$1" in
        pi) first=".pi" ;;
        codex) first=".codex" ;;
        *) first=".claude" ;;
    esac

    printf '%s\n' "${first}"
    local dir
    for dir in .claude .codex .pi; do
        if [[ "${dir}" != "${first}" ]]; then
            printf '%s\n' "${dir}"
        fi
    done
}
