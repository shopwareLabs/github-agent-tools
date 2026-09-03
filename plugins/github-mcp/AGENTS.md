@README.md

## Directory & File Structure

```
plugins/github-mcp/
├── README.md                           # User documentation (usage, configuration, troubleshooting)
├── REFERENCE.md                        # Full tool parameter docs and examples (31 read + 25 write tools)
├── AGENTS.md                           # LLM navigation guide (this file)
├── CHANGELOG.md                        # Version history
│
├── .claude-plugin/plugin.json          # Claude Code plugin manifest
├── .codex-plugin/plugin.json           # Codex plugin manifest + inline MCP registrations
├── .mcp.json                           # Claude Code MCP registrations
│
├── hooks/                              # HOOKS (MCP tool enforcement)
│   ├── hooks.json                      # Hook configuration (SessionStart + PreToolUse x3)
│   ├── prompts/
│   │   └── mcp-tool-directives.md      # SessionStart prompt template: MCP tool listing and usage rules
│   └── scripts/
│       ├── session-start.sh            # SessionStart hook: assembles prompt from template + conditional sections
│       ├── check-gh-tools.sh           # Blocks common gh CLI bash commands (read + write)
│       ├── check-api-tools.sh          # Blocks MCP api_read/api tool bypass of dedicated tools
│       └── lib/
│           └── common.sh              # Shared: parse_hook_input(), load_mcp_config(), block_tool()
│
├── shared/                             # SHARED FRAMEWORK (language-agnostic)
│   └── mcpserver_core.sh              # JSON-RPC 2.0 protocol handler
│
└── mcp-server-gh/                      # GITHUB CLI MCP SERVERS
    ├── server-read.sh                 # Read server entry point - loads optional .mcp-gh-tooling.json
    ├── server-write.sh                # Write server entry point - gated by enable_write_server config
    ├── config-read.json               # Read server metadata (name="gh-tooling")
    ├── config-write.json              # Write server metadata (name="gh-tooling-write")
    ├── tools-read.json                # 31 read tools (PR, issue, CI, commit, search, repo, release, label, project, api_read)
    ├── tools-write.json               # 25 write tools (PR lifecycle, reviews, issues, issue types/fields, labels, assignees, sub-issues, projects, api)
    ├── mcp-gh-tooling.schema.json     # JSON Schema for .mcp-gh-tooling.json
    └── lib/
        ├── common.sh                  # _gh_validate_number/repo/sha(), _gh_resolve_repo(), _gh_validate_jq_filter(), _gh_post_process(), _gh_parse_github_url(), _gh_validate_path(), _gh_download_file(), _gh_resolve_owner_repo()
        ├── pr.sh                      # tool_pr_view/diff/list/checks/comments/reviews/files/commits()
        ├── pr_write.sh                # tool_pr_create/edit/ready/merge/close/reopen()
        ├── issue.sh                   # tool_issue_view(), tool_issue_list()
        ├── issue_schema.sh            # tool_issue_schema() (org issue types + issue fields, name filters)
        ├── issue_write.sh             # tool_issue_create/edit/close/reopen/comment()
        ├── issue_schema_write.sh      # tool_issue_type_set(), tool_issue_field_set() (name-to-ID resolution, PUT replace)
        ├── review_write.sh            # tool_pr_review_submit(), tool_pr_comment(), tool_pr_review_reply()
        ├── run.sh                     # tool_run_view(), tool_run_list(), tool_run_logs(), tool_workflow_jobs()
        ├── job.sh                     # tool_job_view(), tool_job_logs(), tool_job_annotations()
        ├── commit.sh                  # tool_commit_pulls()
        ├── search.sh                  # tool_search(), tool_search_code(), tool_search_repos(), tool_search_commits(), tool_search_discussions()
        ├── repo.sh                    # tool_repo_tree(), tool_repo_file()
        ├── release.sh                 # tool_release_list() (batch, semver pinning, tag→SHA)
        ├── label.sh                   # tool_label_list() (read), tool_label_add(), tool_label_remove() (write)
        ├── assignee_write.sh          # tool_assignee_add(), tool_assignee_remove()
        ├── sub_issue_write.sh         # tool_sub_issue_add(), tool_sub_issue_remove() (GraphQL)
        ├── project.sh                 # tool_project_list(), tool_project_view() (read), tool_project_item_add(), tool_project_status_set() (write, name-to-ID resolution)
        └── api.sh                     # tool_api_read() (GET only), tool_api() (all methods)
```

## Component Overview

This plugin provides:
- **Two MCP Servers** via `.mcp.json` in Claude Code and inline `mcpServers` in
  `.codex-plugin/plugin.json` in Codex:
  - `gh-tooling` (read) - 31 read-only GitHub tools (PRs, issues, CI, commits, search, repo, releases, labels, projects, read-only API)
  - `gh-tooling-write` (write) - 25 write tools (PR lifecycle, reviews, issues, issue types/fields, labels, assignees, sub-issues, projects, full API). Gated by `enable_write_server` config flag.
- **SessionStart Hook** via the shared `hooks/hooks.json`:
  - Assembles MCP tool directives dynamically from template with conditional write and label sections
  - Prompt template maintained in `hooks/prompts/mcp-tool-directives.md`
  - Outputs JSON `additionalContext` format
- **PreToolUse Hooks** via `hooks/hooks.json`:
  - `check-gh-tools.sh` - Blocks bash commands that should use MCP tools instead (both read and write commands)
  - `check-api-tools.sh` - Blocks `api_read` and `api` MCP tools when targeting endpoints with dedicated tools (opt-in via `block_api_tool_read`/`block_api_tool_write`)
- All hook types configurable via `enforce_mcp_tools: false` in `.mcp-gh-tooling.json`

## Architecture

### Config Loading

The gh-tooling servers have their own config loading logic independent of any shared config framework:
- Config is **optional** (works without any config file if `gh` is authenticated)
- Provides a default repo so `repo` doesn't need to be passed to every tool call
- Config discovery checks standard locations, including the project root, `.claude/`, and `.codex/`
- When both host-specific files exist, the active host's file has the highest priority and the
  other host's file remains a fallback
- Write server checks `enable_write_server` flag and returns empty tools list when disabled

### Protocol Flow

```
Claude Code / Codex → stdin → server-read.sh → mcpserver_core.sh → tool_* function
                                                                ↓
Claude Code / Codex ← stdout ← JSON-RPC response ← formatted output

Claude Code / Codex → stdin → server-write.sh → mcpserver_core.sh → tool_* function
                                                                ↓
Claude Code / Codex ← stdout ← JSON-RPC response ← formatted output
```

### Tool Dispatch Convention

Tools in `tools-read.json` and `tools-write.json` map to bash functions with `tool_` prefix:
- Uses bash arrays (`local -a cmd=("gh" "pr" "view" "${number}")`) for injection-safe argument passing
- `_gh_resolve_repo()` falls back to `GH_DEFAULT_REPO` from config
- All tools support `suppress_errors` and `fallback` shared parameters
- Tools with JSON output support `jq_filter` with pre-execution syntax validation
- Log/text tools support `max_lines`, `tail_lines`, and grep parameters

### Standard execution block

Captures `__raw` and `__exit` separately; branches on `suppress_errors` for `2>/dev/null` vs `2>&1`; checks `fallback` before re-echoing error output. Always calls `_gh_post_process()` on success.

## Key Navigation Points

| Task | Primary File | Secondary File | Key Concepts |
|------|--------------|----------------|--------------|
| Add read tool | `mcp-server-gh/lib/<group>.sh` | `mcp-server-gh/tools-read.json` | `tool_*()`, array-based `gh` args |
| Add write tool | `mcp-server-gh/lib/<group>_write.sh` | `mcp-server-gh/tools-write.json` | `tool_*()`, array-based `gh` args |
| Edit SessionStart prompt | `hooks/prompts/mcp-tool-directives.md` | `hooks/scripts/session-start.sh` | Template + conditional sections |
| Add blocked gh command | `hooks/scripts/check-gh-tools.sh` | - | `block_tool()`, grep pattern |
| Add blocked API endpoint | `hooks/scripts/check-api-tools.sh` | - | Endpoint pattern matching |
| Modify shared hook logic | `hooks/scripts/lib/common.sh` | - | `parse_hook_input()`, `load_mcp_config()`, `block_tool()` |
| Modify Claude Code registration | `.mcp.json` | `.claude-plugin/plugin.json` | `${CLAUDE_PLUGIN_ROOT}` |
| Modify Codex registration | `.codex-plugin/plugin.json` | - | Inline `mcpServers`, inherited project cwd |
| Disable hook enforcement | `.mcp-gh-tooling.json` | - | `enforce_mcp_tools: false` |
| Enable write server | `.mcp-gh-tooling.json` | - | `enable_write_server: true` |
| Configure label semantics | `.mcp-gh-tooling.json` | - | `labels: {...}` map |
| Modify protocol | upstream `shopwareLabs/bash-mcp-sdk` | - | `shared/mcpserver_core.sh` is vendored; see root `AGENTS.md` |
| Update read tool schemas | `mcp-server-gh/tools-read.json` | - | JSON Schema Draft 7 |
| Update write tool schemas | `mcp-server-gh/tools-write.json` | - | JSON Schema Draft 7 |

## When to Modify What

**Adding a new read tool:**
1. Choose or create appropriate `mcp-server-gh/lib/<group>.sh` (pr, issue, run, job, commit, search, label, project)
2. Add `tool_<name>()` function using bash arrays for gh CLI args (not string eval)
3. Validate inputs via `_gh_validate_number()`, `_gh_validate_repo()`, `_gh_validate_sha()` from `lib/common.sh`; validate jq_filter via `_gh_validate_jq_filter()`
4. Use the standard execution block (suppress_errors/fallback) instead of bare `"${cmd[@]}" 2>&1`; pipe output through `_gh_post_process()` for jq/grep/head/tail support
5. Add `suppress_errors`, `fallback`, and any applicable `jq_filter`/`max_lines`/`tail_lines`/grep params to `tools-read.json` inputSchema
6. Add tool definition to `mcp-server-gh/tools-read.json`
7. If new file: source it in `mcp-server-gh/server-read.sh`
8. Update README.md and REFERENCE.md

**Adding a new write tool:**
1. Choose or create appropriate `mcp-server-gh/lib/<group>_write.sh`
2. Add `tool_<name>()` function using bash arrays for gh CLI args
3. Add tool definition to `mcp-server-gh/tools-write.json`
4. If new file: source it in `mcp-server-gh/server-write.sh`
5. Add bash command blocking in `hooks/scripts/check-gh-tools.sh`
6. Update README.md and REFERENCE.md

**Key design decisions:**
- No environment wrapping (gh always runs natively on host)
- Config is optional (no config = works with no default repo)
- Uses bash arrays instead of string eval for injection safety
- Read/write separation: read server always active, write server gated by config flag
- Claude Code and Codex launch the same server scripts; do not fork the MCP implementation by host
- The Codex launcher locates the installed plugin but leaves `cwd` unset so the server inherits the
  active project directory used for GitHub repository inference and project config discovery
- Hook has three enforcement layers: `enforce_mcp_tools` (default `true`) blocks high-level subcommands; `block_api_commands` (default `false`, opt-in) blocks `gh api` bash calls; `block_api_tool_read`/`block_api_tool_write` (default `false`, opt-in) blocks MCP API tool bypass

## Integration with Other Plugins

The raw server IDs stay `gh-tooling` and `gh-tooling-write`, but model-visible tool names depend on
the host:

| Host | Read tools | Write tools |
|------|------------|-------------|
| Claude Code | `mcp__plugin_github-mcp_gh-tooling__<tool_name>` | `mcp__plugin_github-mcp_gh-tooling-write__<tool_name>` |
| Codex | `mcp__gh_tooling__<tool_name>` | `mcp__gh_tooling_write__<tool_name>` |

```yaml
# Codex read tools
tools: mcp__gh_tooling__pr_view, mcp__gh_tooling__run_logs, mcp__gh_tooling__search

# Codex write tools
tools: mcp__gh_tooling_write__pr_create, mcp__gh_tooling_write__pr_comment, mcp__gh_tooling_write__label_add
```

## Testing

BATS tests for hook scripts and MCP tool functions are in `plugin-tests/github-mcp/`:

| Test File | Coverage |
|-----------|----------|
| `gh_tools.bats` | GitHub CLI tool blocking (gh pr, gh issue, gh run, gh search, gh label, gh project, gh api) |
| `check_api_tools.bats` | Dedicated API-tool enforcement for Claude Code and Codex tool namespaces |
| `session_start.bats` | Shared SessionStart context and host-specific config discovery |
| `write_server_gating.bats` | Write-server gating and active-host config priority |
| `read_tools_issue_schema.bats` | `issue_schema` org resolution, name filters, and merge output |
| `write_tools_issue_schema.bats` | `issue_type_set` and `issue_field_set` name resolution and value checks |
| `mcp_tool_gh.bats` | MCP tool shared parameters (_gh_validate_jq_filter, _gh_post_process, suppress_errors, fallback) |
| `tool_schemas.bats` | Shipped tool schemas against the vendored validator: identifier unions, required fields, defaults, and validation round-trips |

The vendored SDK's own surface — argument validation and logging — is tested upstream in
`shopwareLabs/bash-mcp-sdk`, not here.

Run tests:
```bash
.bats/bats-core/bin/bats plugin-tests/github-mcp/*.bats
```

## External References

- [Bash MCP SDK](https://github.com/shopwareLabs/bash-mcp-sdk) - source of the vendored `shared/mcpserver_core.sh`; pinned in `.mcp-sdk.lock`
- [MCP Protocol Specification](https://modelcontextprotocol.io/specification) - JSON-RPC 2.0 protocol details
