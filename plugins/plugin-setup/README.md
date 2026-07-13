# Plugin Setup

Claude Code-only interactive setup skill for the [`github-mcp`](../github-mcp) plugin. Install this plugin alongside `github-mcp` and ask Claude to walk you through configuration. Uninstall it once setup is complete to keep the skill description surface small.

## ⚡ Quick Start

```bash
/plugin install plugin-setup@github-agent-tools
```

Then ask Claude to set up the plugin you just installed:

```
Help me set up github-mcp
```

## 🧩 Skills

| Skill                    | Trigger                   | Source plugin |
|--------------------------|---------------------------|---------------|
| `github-mcp-setting-up`  | "set up github-mcp"       | `github-mcp`  |

The skill checks prerequisites (`gh`, `jq`), creates or updates `.mcp-gh-tooling.json`, pre-approves the MCP tool permissions in `.claude/settings.local.json`, validates the result, and reports any remaining manual steps.

## 🔗 How it stays in sync

The skill's reference file (`skills/github-mcp-setting-up/references/plugin-setup.md`) is a byte-identical copy of the source plugin's `SETUP.md`. To update the setup guide, edit `plugins/github-mcp/SETUP.md`, then copy it over the reference file.

## ⚖️ License

MIT
