#!/usr/bin/env bash
# GitHub CLI MCP Server — Write Operations
# Wraps the gh CLI for GitHub write operations: PRs, issues, reviews, labels, projects
# Gated by enable_write_server in .mcp-gh-tooling.json (default: false)

set -euo pipefail
shopt -s inherit_errexit 2>/dev/null || true

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SHARED_DIR="$(cd "${SCRIPT_DIR}/../shared" && pwd)"

MCP_CONFIG_FILE="${SCRIPT_DIR}/config-write.json"
MCP_TOOLS_LIST_FILE="${SCRIPT_DIR}/tools-write.json"
MCP_LOG_FILE="${SCRIPT_DIR}/server-write.log"

PROJECT_ROOT="${PROJECT_ROOT:-$(pwd)}"

export SCRIPT_DIR SHARED_DIR MCP_CONFIG_FILE MCP_TOOLS_LIST_FILE MCP_LOG_FILE PROJECT_ROOT

source "${SHARED_DIR}/mcpserver_core.sh"

GH_TOOLING_CONFIG_FILE=""
GH_DEFAULT_REPO=""

_read_gh_config() {
    if [[ -z "${GH_TOOLING_CONFIG_FILE}" ]] || [[ ! -f "${GH_TOOLING_CONFIG_FILE}" ]]; then
        return 0
    fi
    GH_DEFAULT_REPO=$(jq -r '.repo // empty' "${GH_TOOLING_CONFIG_FILE}" 2>/dev/null || echo "")
    log "INFO" "Default repo from config: ${GH_DEFAULT_REPO:-<none>}"

    local log_file_val
    log_file_val=$(jq -r '.log_file // empty' "${GH_TOOLING_CONFIG_FILE}" 2>/dev/null || echo "")
    _configure_extra_log_file "$log_file_val"
}

_check_write_enabled() {
    local enabled="false"
    if [[ -n "${GH_TOOLING_CONFIG_FILE}" && -f "${GH_TOOLING_CONFIG_FILE}" ]]; then
        enabled=$(jq -r 'if .enable_write_server == true then "true" else "false" end' \
            "${GH_TOOLING_CONFIG_FILE}" 2>/dev/null || echo "false")
    fi
    if [[ "${enabled}" != "true" ]]; then
        log "INFO" "Write server disabled (enable_write_server != true)"
        # A shipped empty list rather than one written at startup. The protocol
        # layer answers -32603 for a tools list it cannot read, which a
        # startup-written file becomes the moment anything removes it, and any
        # cleanup it chains into teardown never runs after SIGKILL.
        MCP_TOOLS_LIST_FILE="${SCRIPT_DIR}/tools-empty.json"
        export MCP_TOOLS_LIST_FILE
    else
        log "INFO" "Write server enabled"
    fi
}

export GH_DEFAULT_REPO GH_TOOLING_CONFIG_FILE

source "${SCRIPT_DIR}/lib/common.sh"
source "${SCRIPT_DIR}/lib/api.sh"
source "${SCRIPT_DIR}/lib/pr_write.sh"
source "${SCRIPT_DIR}/lib/issue_write.sh"
source "${SCRIPT_DIR}/lib/issue_schema_write.sh"
source "${SCRIPT_DIR}/lib/review_write.sh"
source "${SCRIPT_DIR}/lib/label.sh"
source "${SCRIPT_DIR}/lib/assignee_write.sh"
source "${SCRIPT_DIR}/lib/sub_issue_write.sh"
source "${SCRIPT_DIR}/lib/project.sh"

trap 'log "ERROR" "Unexpected error on line ${LINENO}"' ERR

_load_gh_config "${PROJECT_ROOT}" "No .mcp-gh-tooling.json found - write server disabled (no config)"
_read_gh_config
_check_write_enabled
_gh_require_tools_list

log "INFO" "======================================"
log "INFO" "GitHub CLI MCP Server (WRITE) starting"
log "INFO" "Script dir: ${SCRIPT_DIR}"
log "INFO" "Project root: ${PROJECT_ROOT}"
log "INFO" "Default repo: ${GH_DEFAULT_REPO:-<none>}"
log "INFO" "Tools file: ${MCP_TOOLS_LIST_FILE}"
log "INFO" "======================================"

run_mcp_server "$@"
