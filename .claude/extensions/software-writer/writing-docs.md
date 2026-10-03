## Named-value assignments

- `docs.surfaces` =
  | Surface | Owns | Shape | Single-owner |
  |---|---|---|---|
  | `README.md` | Marketplace pitch, per-host install commands, component summary, pointers into plugin docs | Root README | enforced |
  | `AGENTS.md` | Three-host model, runtime-vs-docs file split, repository architecture, development workflow, version bumps, test commands, pre-release checklist, release and distribution | Architecture document | enforced |
  | `CLAUDE.md`, `plugins/plugin-setup/CLAUDE.md` | Nothing; a one-line `@AGENTS.md` import. Gitignored and local to each checkout: never the home for a shared fact | LLM pointer file | not applicable |
  | `plugins/github-mcp/README.md` | Configuration keys and lookup order, tool catalog and tool counts, write server, label semantics, enforcement layers, blocked commands, pi notes, troubleshooting, dependencies | Module README | enforced, except §Quick Start and the opening disclaimer callout: exempt duplicates of the root README install commands and disclaimer because this file is the npm package homepage and must stand alone |
  | `plugins/github-mcp/AGENTS.md` | Plugin file layout, config-loading internals, protocol flow, tool dispatch convention, standard execution block, task-to-file navigation, suite-to-coverage table | Module architecture and navigation document | enforced |
  | `plugins/github-mcp/REFERENCE.md` | Per-tool parameters and examples | Reference | enforced |
  | `plugins/github-mcp/SETUP.md` | Interactive setup procedure, permission groups | Guide | exempt: kept byte-identical to `plugins/plugin-setup/skills/github-mcp-setting-up/references/plugin-setup.md` |
  | `plugins/plugin-setup/README.md`, `plugins/plugin-setup/AGENTS.md` | Setup-plugin install and usage; skill layout, setup-copy sync procedure, design decisions | Module README; module navigation document | enforced |
  | `plugins/github-mcp/CHANGELOG.md`, `plugins/plugin-setup/CHANGELOG.md` | Released changes per version | Changelog | exempt: each entry restates what its release changed |

  Runtime prompt text under `plugins/github-mcp/hooks/prompts/*.md` and `plugins/plugin-setup/skills/*/SKILL.md` are runtime files, not documentation surfaces.
- `docs.pointer_file` = `CLAUDE.md` — a gitignored, per-checkout single `@AGENTS.md` line; each `AGENTS.md` in turn opens with `@README.md`
- `docs.jargon_home` = `AGENTS.md`
- `docs.changelog` = `plugins/github-mcp/CHANGELOG.md` and `plugins/plugin-setup/CHANGELOG.md`; Keep a Changelog with `## [x.y.z] - YYYY-MM-DD` entries, each version matching its plugin manifest version

## Post-Step-5

After editing `plugins/github-mcp/SETUP.md`, follow the sync procedure in `plugins/plugin-setup/AGENTS.md` §The skill, then confirm the copy with `cmp plugins/github-mcp/SETUP.md plugins/plugin-setup/skills/github-mcp-setting-up/references/plugin-setup.md`.

When the change documents altered tool behavior, confirm both `plugins/github-mcp/README.md` and `plugins/github-mcp/REFERENCE.md` were updated.
