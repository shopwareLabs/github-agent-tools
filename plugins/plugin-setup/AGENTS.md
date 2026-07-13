@README.md

## Directory Structure

```
plugins/plugin-setup/
├── .claude-plugin/plugin.json    # Plugin metadata
├── CHANGELOG.md                  # Version history
├── CLAUDE.md                     # Points to AGENTS.md
├── AGENTS.md                     # This file
├── README.md                     # User documentation
└── skills/
    └── github-mcp-setting-up/
        ├── SKILL.md              # Interactive setup workflow
        └── references/
            └── plugin-setup.md   # Byte-identical copy of plugins/github-mcp/SETUP.md
```

## The skill

`github-mcp-setting-up` is a thin shell around the source plugin's `SETUP.md`. The interactive
workflow lives in `SKILL.md`; everything plugin-specific (prerequisites, config questions,
permission groups, validation) is read at runtime from `references/plugin-setup.md`.

- **Workflow changes** → Edit `skills/github-mcp-setting-up/SKILL.md`.
- **Setup procedure for github-mcp** → Edit `plugins/github-mcp/SETUP.md` (the source of truth), then copy it over `skills/github-mcp-setting-up/references/plugin-setup.md`. The two must stay byte-identical.
- **Skill description / trigger phrasing** → Edit the `description` field in the skill's `SKILL.md` frontmatter.

## Adding a new setup skill

When another plugin in this repo gains a `SETUP.md`:

1. Create `plugins/<source-plugin>/SETUP.md` in the source plugin (source of truth).
2. Add `skills/<source-plugin>-setting-up/SKILL.md` here with plugin-specific frontmatter (`name`, `description`) and the same interactive workflow body.
3. Create `skills/<source-plugin>-setting-up/references/plugin-setup.md` as a copy of the source plugin's `SETUP.md`.
4. Update this plugin's `README.md` skills table.

## Key design decisions

- **SETUP.md stays in the source plugin**, not here. The source plugin owns its setup procedure; this plugin only hosts the interactive skill that consumes it.
- **Skill version matches this plugin's version**, not the source plugin's. Bump the skill's `version` frontmatter and `.claude-plugin/plugin.json` together.
- **Plugin-specific description** drives auto-routing. The description must name the source plugin (`github-mcp`) and likely user phrasing ("set up github-mcp") so the skill activates.
- **No runtime components** — only a skill. No MCP server, no hooks, no commands, no agents. This keeps the plugin safe to uninstall after setup without disrupting `github-mcp`.
