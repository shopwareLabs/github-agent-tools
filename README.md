# GitHub Agent Tools

> **Experimental Community Project**: Maintained by Shopware Labs, not an official Shopware product. Not affiliated with, endorsed by, or sponsored by Anthropic, OpenAI, or any other AI provider. Provider and product names are used only to describe compatibility. Provided as-is without warranty.

GitHub CLI tools for AI coding agents. Wraps the GitHub CLI (`gh`) behind MCP servers — pull requests, issues, CI runs, jobs, commits, search, labels, projects, and repository file browsing — as first-class MCP tools, with hook-based enforcement that keeps the agent on the tools instead of raw `gh` bash calls.

The MCP servers use the assistant-neutral [Model Context Protocol](https://modelcontextprotocol.io/) and can be integrated with MCP-capable coding agents. This repository provides tested `github-mcp` plugin packaging for both [Claude Code](https://docs.claude.com/en/docs/claude-code/plugins) and [Codex](https://learn.chatgpt.com/docs/build-plugins).

> **Origin**: Extracted from its sibling project [shopwareLabs/ai-coding-tools](https://github.com/shopwareLabs/ai-coding-tools) — a broader AI-coding-tools marketplace — into this standalone repository. The GitHub tooling was split out so it can evolve and be installed independently.

## ⚡ Quick Start

**Packaged plugin requirements:** `gh` CLI authenticated (`gh auth login`), `jq`, and either [Claude Code](https://docs.claude.com/en/docs/claude-code) or [Codex](https://developers.openai.com/codex/cli/).

### Claude Code

```bash
/plugin marketplace add shopwareLabs/github-agent-tools
/plugin install github-mcp@github-agent-tools
```

Restart Claude Code after installation for the MCP servers to initialize.

### Codex

```bash
codex plugin marketplace add shopwareLabs/github-agent-tools
codex plugin add github-mcp@github-agent-tools
```

Start a new Codex task after installation. Open `/hooks` to review and trust the bundled enforcement hooks; Codex skips untrusted plugin hooks.

The read server (`gh-tooling`) is always active. The write server (`gh-tooling-write`) is opt-in via `enable_write_server: true` in a `.mcp-gh-tooling.json` config file. Configuration is optional — the read server works out of the box when `gh` is authenticated.

**Optional Claude Code setup:** the companion `plugin-setup` plugin remains Claude Code-only because it uses Claude Code interaction and permission settings. Install it with `/plugin install plugin-setup@github-agent-tools`, ask Claude to *"set up github-mcp"*, then uninstall it when setup is complete. Codex users configure `.mcp-gh-tooling.json` manually as described in the plugin guide.

## 🧩 What's Inside

| Component  | Description                                                                                          |
|------------|------------------------------------------------------------------------------------------------------|
| 🔌 MCP     | Two servers — `gh-tooling` (30 read tools) and `gh-tooling-write` (23 write tools, gated)             |
| 🪝 Hooks   | SessionStart directive + PreToolUse enforcement that redirects `gh` bash calls to the MCP tools       |

See [plugins/github-mcp/README.md](./plugins/github-mcp/README.md) for full configuration, the complete tool reference, and troubleshooting. See [plugins/github-mcp/REFERENCE.md](./plugins/github-mcp/REFERENCE.md) for per-tool parameter docs.

## 🧪 Testing

```bash
# One-time: install BATS locally
./.github/scripts/setup-bats.sh

# Run the suites
.bats/bats-core/bin/bats -r plugin-tests/
```

## ⚖️ License

[MIT](./LICENSE).
