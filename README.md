# GitHub Agent Tools

> **Experimental Community Project**: Maintained by Shopware Labs, not an official Shopware product. Not affiliated with, endorsed by, or sponsored by Anthropic, OpenAI, or any other AI provider. "Claude" and "Claude Code" are trademarks of Anthropic. Provided as-is without warranty.

GitHub CLI tools for AI coding agents. Wraps the GitHub CLI (`gh`) behind MCP servers — pull requests, issues, CI runs, jobs, commits, search, labels, projects, and repository file browsing — as first-class MCP tools, with hook-based enforcement that keeps the agent on the tools instead of raw `gh` bash calls.

Because it is built on the assistant-neutral [Model Context Protocol](https://modelcontextprotocol.io/), it works with any MCP-capable coding agent. It ships today as a [Claude Code plugin marketplace](https://docs.claude.com/en/docs/claude-code/plugins); Codex compatibility is planned.

> **Origin**: Extracted from its sibling project [shopwareLabs/ai-coding-tools](https://github.com/shopwareLabs/ai-coding-tools) — a broader AI-coding-tools marketplace — into this standalone repository. The GitHub tooling was split out so it can evolve on its own and be used by any MCP-capable agent.

## ⚡ Quick Start

**Requirements:** [Claude Code](https://docs.claude.com/en/docs/claude-code) installed, `gh` CLI authenticated (`gh auth login`), `jq`.

```bash
/plugin marketplace add shopwareLabs/github-agent-tools
/plugin install github-mcp@github-agent-tools
```

> [!IMPORTANT]
> Restart Claude Code after installation for the MCP servers to initialize.

The read server (`gh-tooling`) is always active. The write server (`gh-tooling-write`) is opt-in via `enable_write_server: true` in a `.mcp-gh-tooling.json` config file. Configuration is optional — the read server works out of the box when `gh` is authenticated.

**Optional interactive setup:** install the companion `plugin-setup` plugin (`/plugin install plugin-setup@github-agent-tools`) and ask Claude to *"set up github-mcp"* — it checks `gh`/`jq`, optionally writes a config, and pre-approves the MCP tool permissions. Uninstall it once you're done.

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
