@README.md

# GitHub Agent Tools - Technical Reference

This repository packages the `github-mcp` plugin — GitHub CLI tools delivered over MCP — as its
own installable marketplace, alongside a small optional `plugin-setup` helper. It was extracted
from [shopwareLabs/ai-coding-tools](https://github.com/shopwareLabs/ai-coding-tools).

> **Plugin name vs. server names.** The installable plugin is `github-mcp`, but its two MCP
> servers keep their original IDs `gh-tooling` (read) and `gh-tooling-write` (write). So you
> install `github-mcp@github-agent-tools`, while `/mcp` and `.mcp-gh-tooling.json` use the raw
> server IDs. Claude Code exposes names such as `mcp__plugin_github-mcp_gh-tooling__…`; Codex
> exposes the same tools as `mcp__gh_tooling__…` after sanitizing the server ID.

## Dual-target: Claude Code and Codex

The plugin's core is assistant-neutral: `plugins/github-mcp/mcp-server-gh/server-{read,write}.sh`
are plain stdio [MCP](https://modelcontextprotocol.io/) servers that both hosts spawn. Claude Code
uses `.claude-plugin/marketplace.json`, `.claude-plugin/plugin.json`, and `.mcp.json`; Codex uses
`.agents/plugins/marketplace.json` and `.codex-plugin/plugin.json`. The hook definition and scripts
are shared. Keep the MCP server scripts and hook behavior as the single core across both hosts.

The separate `plugin-setup` plugin remains Claude Code-only because its skill uses Claude Code
interaction and permission-setting features. Do not list it in the Codex marketplace unless that
runtime is ported and tested independently.

## Runtime files vs developer documentation

**Runtime files are executable code, not documentation.** Editing them changes plugin behavior
directly — treat them as you would any source file. For `github-mcp` these are:

- `.mcp.json` — Claude Code MCP server registration
- `.codex-plugin/plugin.json` — Codex manifest and MCP server registration
- `mcp-server-gh/` — the read/write servers, tool definitions (`tools-*.json`), and `lib/*.sh`
- `shared/mcpserver_core.sh` — JSON-RPC protocol handler
- `hooks/` — `hooks.json` plus the SessionStart/PreToolUse scripts

The `github-mcp` plugin ships only MCP servers and hooks — no skills, slash commands, or agents.
The separate `plugin-setup` plugin ships one skill (`github-mcp-setting-up`); its `skills/*/SKILL.md`
is a runtime file. If `github-mcp` gains its own `skills/*/SKILL.md`, `commands/*.md`, or
`agents/*.md` later, those are runtime files too.

**Developer documentation is not runtime.** Repository and plugin `README.md`, `AGENTS.md`,
`CLAUDE.md` (where present), and `CHANGELOG.md` files are read by maintainers; neither host loads
them as installed plugin runtime. When changing runtime behavior, edit runtime files; when updating
guides or architecture notes, edit the docs.

## Repository Architecture

The repository exposes host-specific marketplace registries. Claude Code lists both plugins;
Codex lists only the compatible `github-mcp` plugin. Each entry points at the shared plugin root,
where that host's `plugin.json` provides the full metadata and runtime wiring.

```
.agents/plugins/marketplace.json         # Codex registry → github-mcp
.claude-plugin/marketplace.json          # Claude Code registry → github-mcp + plugin-setup
plugins/
  github-mcp/                            # THE PLUGIN: GitHub CLI MCP servers + enforcement hooks
    .claude-plugin/plugin.json           # Claude Code metadata
    .codex-plugin/plugin.json            # Codex metadata + MCP registrations
    .mcp.json · hooks/ · mcp-server-gh/ · shared/ · docs
  plugin-setup/                          # optional Claude Code-only setup skill
    .claude-plugin/plugin.json · skills/
plugin-tests/                            # BATS suites (mirror the plugin structure)
.github/ISSUE_TEMPLATE/                  # GitHub issue forms; dropdowns generated from the plugins
```

**Claude Code marketplace** — `.claude-plugin/marketplace.json`; local sources use
`{"name": "<name>", "source": "./plugins/<name>"}`.

**Codex marketplace** — `.agents/plugins/marketplace.json`; local sources use
`{"source": {"source": "local", "path": "./plugins/<name>"}}`. Paths are relative to the
marketplace root, which is the repository root.

**Plugin manifests** — each supported host has its own `plugin.json`. Keep their shared metadata
and release version aligned, while allowing host-specific component registration.

## Plugin Components

`github-mcp` uses two component types:

- **MCP Servers** (`.mcp.json`, `.codex-plugin/plugin.json`, and `mcp-server-gh/`) — a read server
  (always active) and a write server (gated by `enable_write_server`).
- **Hooks** (`hooks/hooks.json` + scripts) — a SessionStart directive plus PreToolUse enforcement
  that redirects `gh` bash calls to the MCP tools.

`plugin-setup` is a Claude Code-only skill plugin: it bundles the `github-mcp-setting-up` skill,
whose reference file is a byte-identical copy of `plugins/github-mcp/SETUP.md`. It has no MCP
servers or hooks and is meant to be installed for setup and uninstalled afterward.

For adding or modifying tools, the authoritative guide is the plugin's own navigation doc:
`plugins/github-mcp/AGENTS.md` (tool dispatch convention, where each `tool_*()` lives, how to
wire a new read/write tool and its schema). Start there for any change inside the plugin.

## mcpserver_core.sh

`plugins/github-mcp/shared/mcpserver_core.sh` is the JSON-RPC protocol handler. It is vendored
verbatim from [shopwareLabs/bash-mcp-sdk](https://github.com/shopwareLabs/bash-mcp-sdk)
(`lib/mcpserver_core.sh`); `.mcp-sdk.lock` records the release it came from, and `renovate.json`
watches that lock for new releases.

Do not edit it here — a local change is overwritten by the next update. Protocol changes go to
the SDK repository and arrive as a lock bump plus a refreshed copy of the file. The SDK owns the
tests for its own surface (argument validation, logging); `plugin-tests/` covers this plugin's
tools and schemas.

```bash
.github/scripts/vendor-mcp-sdk.sh            # re-vendor at the pinned release
.github/scripts/vendor-mcp-sdk.sh --check    # compare only; what CI runs
```

After Renovate bumps `.mcp-sdk.lock`, run the script without `--check` and commit the refreshed
file in the same PR — the lock and the vendored copy have to move together or CI fails.

## Commit Messages

Use conventional-commit format. The `commit-message-writer:writing-commit-messages` skill is
available globally and can generate them. If project-specific rules are needed, put the shared
overlay at `.claude/hook-contexts/writing-commit-messages.md`: Claude Code delivers it through
project hooks, while Codex requires a root `AGENTS.override.md` reference. Do not `git add` or
commit until asked.

## Development Workflow

### Modifying the plugin

Read `plugins/github-mcp/AGENTS.md` first — it maps every task (add read tool, add write tool,
edit the SessionStart prompt, add a blocked command, modify the protocol) to the exact file and
convention. Update `plugins/github-mcp/README.md` and `REFERENCE.md` when tool behavior changes.

### Version bumps

Edit the version in both `plugins/github-mcp/.claude-plugin/plugin.json` and
`plugins/github-mcp/.codex-plugin/plugin.json`, then add a matching
`plugins/github-mcp/CHANGELOG.md` entry. `plugin-setup` is versioned independently in its own
Claude Code manifest and `CHANGELOG.md`; keep the `version` in each of its skills' SKILL.md
frontmatter equal to that manifest version.

### Issue templates

The GitHub issue forms in `.github/ISSUE_TEMPLATE/` have component dropdowns (plugins, MCP servers,
skills, agents, commands) generated from the repo's actual components. After adding or removing a
plugin, skill, agent, command, MCP server, or hook, regenerate them:

```bash
.github/scripts/update-issue-templates.sh   # rewrites the dropdowns; leaves .bak files
```

CI runs `.github/scripts/validate-issue-templates.sh` (via `.github/workflows/validate.yml`) and
fails the build if any dropdown is out of date.

### Adding another plugin

Choose the supported hosts first. Add the corresponding `.claude-plugin/plugin.json` and/or
`.codex-plugin/plugin.json`, then register the plugin only in each compatible host marketplace.
Keep shared runtime files host-neutral and keep host-specific launch wiring in the manifests. Run
the relevant host validation and `.github/scripts/update-issue-templates.sh`.

## Testing & Validation

### Local

```bash
# Claude Code
claude plugin validate .                 # validate marketplace + plugin structure
/plugin marketplace add /path/to/github-agent-tools   # install locally to smoke-test

# Codex
codex plugin marketplace add /path/to/github-agent-tools
codex plugin list --available --json     # inspect the resolved Codex marketplace
codex plugin add github-mcp@github-agent-tools
```

### BATS

```bash
./.github/scripts/setup-bats.sh          # one-time: installs bats-core/support/assert to .bats/
.bats/bats-core/bin/bats -r plugin-tests/
```

Tests live in `plugin-tests/<name>/` mirroring the plugin structure and load the shared helper at
`plugin-tests/test_helper/common_setup.bash` (it resolves the repo root by walking up to `.bats/`).
CI (`.github/workflows/ci.yml`) runs ShellCheck over `plugins plugin-tests .github/scripts`,
`vendor-mcp-sdk.sh --check` for the vendored SDK copy, and BATS over `plugin-tests/`; a separate
`validate.yml` checks the issue-template dropdowns.

### Pre-release checklist

- [ ] `claude plugin validate .` passes
- [ ] Codex marketplace add, list, and plugin install smoke test passes
- [ ] Plugin version bumped in both host manifests with a CHANGELOG entry
- [ ] BATS green (`.bats/bats-core/bin/bats -r plugin-tests/`)
- [ ] ShellCheck clean
- [ ] Issue-template dropdowns up to date (`.github/scripts/validate-issue-templates.sh`)
- [ ] Vendored SDK matches its lock (`.github/scripts/vendor-mcp-sdk.sh --check`)
- [ ] Docs updated (`plugins/github-mcp/README.md`, `REFERENCE.md`)

## Distribution

The repository must be public with both marketplace files at their documented paths for GitHub
distribution. Claude Code installs with `/plugin marketplace add shopwareLabs/github-agent-tools`
then `/plugin install github-mcp@github-agent-tools`. Codex installs with
`codex plugin marketplace add shopwareLabs/github-agent-tools` then
`codex plugin add github-mcp@github-agent-tools`.

## Using Anthropic dev plugins

When developing here with Anthropic's official `plugin-dev`/`feature-dev` plugins, invoke their
skills and agents through the Task tool for context isolation, e.g.
`Task(subagent_type="plugin-validator", prompt="Validate this plugin before commit")`. The ones
that match this plugin's surface: `plugin-dev:mcp-integration` (MCP config), `plugin-dev:hook-development`
(hooks), and the `plugin-validator` agent (before publishing). These are optional aids, not required.
