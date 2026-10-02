@README.md

## Directory & File Structure

```
plugins/github-mcp/
├── README.md                           # User documentation (usage, configuration, troubleshooting)
├── REFERENCE.md                        # Full tool parameter docs and examples (31 read + 25 write tools)
├── AGENTS.md                           # LLM navigation guide (this file)
├── CHANGELOG.md                        # Version history
├── SETUP.md                            # Interactive setup procedure (kept byte-identical to plugin-setup's copy)
│
├── .claude-plugin/plugin.json          # Claude Code plugin manifest
├── .codex-plugin/plugin.json           # Codex plugin manifest + inline MCP registrations
├── .mcp.json                           # Claude Code MCP registrations
│
├── pi/                                  # PI EXTENSION
│   ├── index.ts                        # Extension factory: server registration, directive, gates
│   └── gate.ts                         # runScript()/runGate(): spawns a hook script, parses its result
│
├── hooks/                              # HOOKS (MCP tool enforcement)
│   ├── hooks.json                      # Hook configuration (SessionStart + PreToolUse x3)
│   ├── prompts/
│   │   ├── mcp-tool-directives.md      # SessionStart prompt template: MCP tool listing and usage rules
│   │   ├── write-operations-enabled.md # {{WRITE_SECTION}} filler when enable_write_server is true
│   │   ├── write-operations-disabled.md # {{WRITE_SECTION}} filler when enable_write_server is false/absent
│   │   ├── label-definitions-header.md # {{LABEL_SECTION}} header, followed by one generated line per label
│   │   └── host-pi.md                  # Appended after the assembled template when the host is pi
│   └── scripts/
│       ├── session-start.sh            # SessionStart hook: assembles prompt from template + conditional sections
│       ├── check-gh-tools.sh           # Blocks common gh CLI bash commands (read + write)
│       ├── check-api-tools.sh          # Blocks MCP api_read/api tool bypass of dedicated tools
│       └── lib/
│           └── common.sh              # Shared: resolve_hook_context(), find_mcp_config(), parse_hook_input(), load_mcp_config(), block_tool()
│
├── shared/                             # SHARED FRAMEWORK (language-agnostic)
│   ├── mcpserver_core.sh              # JSON-RPC 2.0 protocol handler (vendored)
│   └── config-dirs.sh                 # github_mcp_config_dirs(): host config directory order for hooks and servers
│
└── mcp-server-gh/                      # GITHUB CLI MCP SERVERS
    ├── server-read.sh                 # Read server entry point - loads optional .mcp-gh-tooling.json
    ├── server-write.sh                # Write server entry point - gated by enable_write_server config
    ├── config-read.json               # Read server metadata (name="gh-tooling")
    ├── config-write.json              # Write server metadata (name="gh-tooling-write")
    ├── tools-read.json                # 31 read tools (PR, issue, CI, commit, search, repo, release, label, project, api_read)
    ├── tools-write.json               # 25 write tools (PR lifecycle, reviews, issues, issue types/fields, labels, assignees, sub-issues, projects, api)
    ├── tools-empty.json               # Tools list the write server reports while enable_write_server is false
    ├── mcp-gh-tooling.schema.json     # JSON Schema for .mcp-gh-tooling.json
    └── lib/
        ├── common.sh                  # _load_gh_config(), _gh_validate_number/repo/sha(), _gh_resolve_repo(), _gh_validate_jq_filter(), _gh_post_process(), _gh_parse_github_url(), _gh_validate_path(), _gh_download_file(), _gh_resolve_owner_repo()
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
- **pi Extension** via `pi/index.ts` (the package entry point declared in root `package.json`'s
  `pi.extensions`), loaded only by pi:
  - Registers both MCP servers with `exposure: "deferred"`, same command scripts as Claude Code and
    Codex
  - Runs `session-start.sh` on `session_start` and stores its directive for `before_agent_start`
  - Runs `check-gh-tools.sh`/`check-api-tools.sh` on `tool_call` through `pi/gate.ts`'s
    `runGate()`/`runScript()` in place of hooks.json's PreToolUse matchers

## Architecture

### Config Loading

The gh-tooling servers load their config with `_load_gh_config()` in `mcp-server-gh/lib/common.sh`:
- Config is **optional** (works without any config file if `gh` is authenticated)
- Provides a default repo so `repo` doesn't need to be passed to every tool call
- Config discovery checks standard locations, including the project root, `.claude/`, `.codex/`,
  and `.pi/`
- The host directory order comes from `github_mcp_config_dirs()` in `shared/config-dirs.sh`, which
  the hooks' `find_mcp_config()` also uses: the active host's directory first, then the others in the
  fixed order `.claude/`, `.codex/`, `.pi/`. The servers take the host from `GITHUB_MCP_HOST`; any
  value other than `pi` or `codex` uses the Claude Code order
- The hooks' `resolve_hook_context()` selects Claude Code whenever `CLAUDE_PROJECT_DIR` is set, then
  `GITHUB_MCP_HOST` (`pi` or `codex`), and falls back to Codex
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
| Change the host config directory order | `shared/config-dirs.sh` | - | `github_mcp_config_dirs()`, used by hooks and servers |
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

**Modifying the pi extension:**
1. `pi/index.ts` registers the servers, runs the SessionStart directive, and wires the two gates —
   it calls the same scripts as `hooks/hooks.json`, so a new blocked command or a directive change
   needs no change here
2. `pi/gate.ts` only spawns a script and interprets its exit code; change it only to change how a
   gate script's result is turned into a block/allow decision
3. Both files import pi's own packages with `import type` only, so the extension keeps no runtime
   dependency on them

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
| pi | `mcp__gh_tooling__<tool_name>` | `mcp__gh_tooling_write__<tool_name>` |

pi's tool names match Codex's: both sanitize the server ID the same way.

```yaml
# Codex read tools
tools: mcp__gh_tooling__pr_view, mcp__gh_tooling__run_logs, mcp__gh_tooling__search

# Codex write tools
tools: mcp__gh_tooling_write__pr_create, mcp__gh_tooling_write__pr_comment, mcp__gh_tooling_write__label_add
```

## Testing

BATS tests for hook scripts and MCP tool functions are in `plugin-tests/github-mcp/`; the pi extension's
own unit tests are Node tests under `plugin-tests/github-mcp/pi/`:

| Test File | Coverage |
|-----------|----------|
| `api_read_restriction.bats` | `api_read`'s GET-only method allow-list versus `api`'s full method access |
| `check_api_tools.bats` | Dedicated API-tool enforcement for the Claude Code, Codex, and pi tool namespaces |
| `download_cancel_cleanup.bats` | Partial-file cleanup when a `repo_file` or `search_code` download is cancelled mid-write |
| `gh_tools.bats` | GitHub CLI read-command blocking (gh pr, gh issue, gh run, gh search, gh api) and host and config resolution across Claude Code, Codex, and pi |
| `gh_tools_write.bats` | GitHub CLI blocking for the write-server commands (gh pr/issue create/edit/close/reopen/review/comment, gh project item-add/item-edit) and for `gh label list` and `gh project list`/`view` |
| `mcp_tool_gh.bats` | MCP tool shared parameters (`_gh_validate_jq_filter`, `_gh_post_process`, `suppress_errors`, `fallback`) and core read tool behavior (`pr_view`/`diff`/`list`/`checks`/`comments`/`reviews`/`files`/`commits`, `issue_view`/`list`, `run_view`/`list`/`logs`, `workflow_jobs`, `commit_pulls`, `search`/`search_code`/`search_repos`/`search_commits`/`search_discussions`, `repo_tree`/`repo_file`, `job_view`/`logs`/`annotations`) |
| `package_contents.bats` | npm tarball contents: every runtime file packed, tests/CI/host manifests excluded, executable permissions preserved |
| `package_manifest.bats` | `package.json` version alignment with both plugin manifests, pi extension entry points, and `@earendil-works` dependency pinning |
| `pi_e2e.bats` | End-to-end `pi` binary runs against a scripted model and stubbed `gh`, in both git-clone and npm-install layouts, plus codemode and config-override cases |
| `read_tools_escape_sequences.bats` | ANSI escape-sequence stripping and byte-for-byte downloads across `job_logs`, `api`, `repo_file` |
| `read_tools_issue_schema.bats` | `issue_schema` org resolution, name filters, and merge output |
| `read_tools_issue_view_fields.bats` | `issue_view`'s `with_field_values` REST merge, single-select option-name resolution, and validation |
| `read_tools_jq_filter_fields.bats` | `jq_filter`/`fields` interaction across the pr, run, issue, and search read tools |
| `read_tools_new.bats` | `label_list`, `project_list`, `project_view`, including their `jq_filter` handling |
| `release_tools.bats` | `release_list` semver ranking, prereleases, major/minor constraints, batch mode, `fields`, and `resolve_sha` |
| `server_startup_tools_list.bats` | `server-read.sh` startup validation of `tools-read.json` |
| `session_start.bats` | Shared SessionStart context and host-specific config discovery |
| `session_start_write.bats` | SessionStart write-section and label-section rendering |
| `tool_dispatch_declaration.bats` | Read and write server dispatch limited to the tools each declares |
| `tool_schemas.bats` | Shipped tool schemas against the vendored validator: identifier unions, required fields, defaults, and validation round-trips |
| `write_server_gating.bats` | Write-server gating and active-host config priority |
| `write_tools_edit_params.bats` | `label_add`/`label_remove` and `assignee_add`/`assignee_remove` routing through `gh pr edit`/`gh issue edit` |
| `write_tools_graphql.bats` | `sub_issue_add`/`sub_issue_remove` GraphQL mutations and node-ID resolution |
| `write_tools_issue.bats` | `issue_create`/`edit`/`close`/`reopen`/`comment` parameter handling |
| `write_tools_issue_schema.bats` | `issue_type_set` and `issue_field_set` name resolution and value checks |
| `write_tools_pr.bats` | `pr_create`/`edit`/`ready`/`merge`/`close`/`reopen` parameter handling |
| `write_tools_project.bats` | `project_item_add` and `project_status_set` name-to-ID resolution |
| `write_tools_review.bats` | `pr_review_submit`/`pr_comment`/`pr_review_reply` parameter handling and REST payloads |
| `pi/gate.test.ts` | `runGate()`/`runScript()`: exit codes, stderr capture, stdin handling, and the timeout that kills a gate's background children |
| `pi/index.test.ts` | The extension's event handlers on a fake pi: the `github_mcp` section from session-start output (malformed output and non-zero exits add none), and which `bash` and `api_read` calls the gates block or let through |

The vendored SDK's own surface — argument validation and logging — is tested upstream in
`shopwareLabs/bash-mcp-sdk`, not here.

Run tests: see root `AGENTS.md` §BATS and §Node and pi for the exact commands, the one-time BATS
setup, and the `pi_e2e.bats` prerequisites (`npm ci`, GNU `timeout`/`gtimeout`).

## External References

- [Bash MCP SDK](https://github.com/shopwareLabs/bash-mcp-sdk) - source of the vendored `shared/mcpserver_core.sh`; pinned in `.mcp-sdk.lock`
- [MCP Protocol Specification](https://modelcontextprotocol.io/specification) - JSON-RPC 2.0 protocol details
