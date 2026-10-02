## Named-value assignments

- `project.stacks` =
  - `bash` — `plugins/**/*.sh`, `.github/scripts/*.sh`, `plugin-tests/**/*.{bats,bash,sh}`
  - `typescript` — `plugins/github-mcp/pi/*.ts`, `plugin-tests/github-mcp/{pi,fixtures/pi}/*.ts`; executed directly by Node ≥22.19 type stripping, no build step (`tsconfig.json`: `erasableSyntaxOnly`, `allowImportingTsExtensions`; relative imports keep the `.ts` extension)
- `code.primitives` =
  | Call shape | Raw primitive | Helper | Invariant carried |
  |---|---|---|---|
  | Resolve the target repository from tool args | `jq` reads of `repo` / `repository` / `owner` / `url` | `_gh_resolve_owner_repo`, `_gh_resolve_owner_repo_optional` (`mcp-server-gh/lib/common.sh`) | Precedence `url` > `owner`+`repo` > `repository` > `repo` > `GH_DEFAULT_REPO`; a slash in split-form `repo` is rejected |
  | Resolve an organization | `gh repo view`, raw `org` arg | `_gh_resolve_org` (`lib/common.sh`) | Result always passes `_gh_validate_org`, so it cannot steer the request to another API path |
  | Validate a number, repo, SHA, or repository path argument | Ad hoc `[[ =~ ]]` checks | `_gh_validate_number`, `_gh_validate_repo`, `_gh_validate_sha`, `_gh_validate_path` (`lib/common.sh`) | `_gh_validate_path` rejects a leading `/` and any `..` segment |
  | Apply caller-supplied `jq_filter` / `grep_pattern` / `head` / `tail` | Piping output through `jq` or `grep` directly | `_gh_validate_jq_filter`, `_gh_post_process` (`lib/common.sh`) | Filter compile-checked before use; steps run in a fixed jq → grep → head → tail order, each a no-op when unset |
  | Emit `gh` output to the model | Raw `gh` stdout | `_gh_strip_ansi` (`lib/common.sh`) | No ESC byte reaches a terminal-rendering host; BSD-`sed`-compatible BRE under `LC_ALL=C` |
  | Download file bytes to disk | `gh api … > file`, `mktemp` | `_gh_download_file` with `_gh_partial_create` / `_gh_partial_finish` / `_gh_partial_cleanup` (`lib/common.sh`) | Unique `noclobber` naming, atomic finish, partial file removed on cancellation |
  | Locate the project config file | Hand-listed `.claude` / `.codex` / `.pi` candidate paths | `_load_gh_config` (`mcp-server-gh/lib/common.sh`, servers), `find_mcp_config` (`hooks/scripts/lib/common.sh`, hooks), both ordered by `github_mcp_config_dirs` (`shared/config-dirs.sh`) | The active host's directory takes priority, and servers and hooks agree on one host order |
  | Read a config key | `jq` on `$GH_TOOLING_CONFIG_FILE` | `_gh_config_value` (`lib/common.sh`) | Returns the default when the file is missing or the key empty |
  | Run a hook script from the pi extension | `child_process.spawn` | `runScript`, `runGate` (`plugins/github-mcp/pi/gate.ts`) | Never rejects; timeout kills the whole process group; sets `GITHUB_MCP_HOST=pi` and drops `CLAUDE_PROJECT_DIR`; blocks only on exit 2 |
  | Invoke `gh` | A command string | `local -a cmd=(gh …)` then `"${cmd[@]}"` | Arguments stay array elements; never `eval` |
- `code.di_pattern` = TypeScript: the default export `githubMcp(pi: ExtensionAPI)` in `plugins/github-mcp/pi/index.ts` is the composition root; it computes script paths and timeouts and wires `pi.on(...)` handlers. Modules beside it (`gate.ts`) take script path, input, and timeout as parameters and hold no module-level state. Bash: a tool function `tool_<name>()` takes the JSON args string as `$1`; host and project context enter through environment variables set at the server or hook entry point (`GITHUB_MCP_HOST`, `CLAUDE_PROJECT_DIR`, `MCP_GH_TOOLING_CONFIG`, `GH_DEFAULT_REPO`, `PROJECT_ROOT`); `gh` resolves from PATH, so tests substitute a `gh()` function.
- `code.export_conventions` =
  - `plugins/github-mcp/pi/index.ts` exports only the default extension factory named in root `package.json` `pi.extensions`; helpers live in sibling modules as named exports.
  - Import `@earendil-works/*` packages only with `import type`; the extension carries no runtime dependency on pi (`@typescript-eslint/no-restricted-imports` in `eslint.config.mjs` enforces this for `plugins/github-mcp/pi/**/*.ts`).
  - A new MCP tool is a `tool_<name>()` in `mcp-server-gh/lib/<group>.sh` plus its schema entry in `tools-read.json` or `tools-write.json`; a server runs only the tools its list declares. Before adding one, read `plugins/github-mcp/AGENTS.md` §When to Modify What.
- `code.footgun_additions` =
  - `plugins/github-mcp/shared/mcpserver_core.sh` is vendored from `shopwareLabs/bash-mcp-sdk`: never edit it; protocol changes go upstream and arrive via `.mcp-sdk.lock` plus `.github/scripts/vendor-mcp-sdk.sh`.
  - pi extension `.ts` files run under Node type stripping: no `enum`, `namespace`, parameter properties, or other non-erasable syntax.
  - A new runtime file outside the root `package.json` `files` globs is missing from the npm package; only `plugin-tests/github-mcp/pi_e2e.bats`, which runs pi against the packed tarball, surfaces it.
  - Host-specific behavior branches only on `GITHUB_MCP_HOST` (servers) or `HOOK_HOST` (hooks); runtime scripts stay shared across Claude Code, Codex, and pi.
  - Adding or removing a plugin, MCP server, or hook requires running `.github/scripts/update-issue-templates.sh`; CI fails on stale issue-template dropdowns.
- `comments.preserve_patterns` =
  - `# shellcheck disable=…` and `# shellcheck source=…` directives, together with the justification comment beside them
  - The `# Tools: <names>` header line in `plugins/github-mcp/mcp-server-gh/lib/*.sh`
- `domain.terms` = `read server`, `write server`, `gh-tooling`, `gh-tooling-write` (server IDs; distinct from the plugin name `github-mcp`), `host`, `SessionStart directive`, `enforcement`, `escape hatch`, `enforce_mcp_tools`, `enable_write_server`, `block_api_commands`, `block_api_tool_read`, `block_api_tool_write`
- `docs.surfaces` =
  | Surface | Owns | Shape | Single-owner |
  |---|---|---|---|
  | `README.md` | Marketplace pitch, per-host install commands, component summary, pointers into plugin docs | Root README | enforced |
  | `AGENTS.md` | Three-host model, runtime-vs-docs file split, repository architecture, development workflow, version bumps, test commands, pre-release checklist, release and distribution | Architecture document | enforced |
  | `CLAUDE.md`, `plugins/plugin-setup/CLAUDE.md` | Nothing; a one-line `@AGENTS.md` import. Gitignored and local to each checkout: never the home for a shared fact | LLM pointer file | not applicable |
  | `plugins/github-mcp/README.md` | Configuration keys and lookup order, tool catalog and tool counts, write server, label semantics, enforcement layers, blocked commands, pi notes, troubleshooting, dependencies | Module README | enforced, except §Quick Start: exempt duplicate of the root README install commands because this file is the npm package homepage and must stand alone |
  | `plugins/github-mcp/AGENTS.md` | Plugin file layout, config-loading internals, protocol flow, tool dispatch convention, standard execution block, task-to-file navigation, suite-to-coverage table | Module architecture and navigation document | enforced |
  | `plugins/github-mcp/REFERENCE.md` | Per-tool parameters and examples | Reference | enforced |
  | `plugins/github-mcp/SETUP.md` | Interactive setup procedure, permission groups | Guide | exempt: kept byte-identical to `plugins/plugin-setup/skills/github-mcp-setting-up/references/plugin-setup.md` |
  | `plugins/plugin-setup/README.md`, `plugins/plugin-setup/AGENTS.md` | Setup-plugin install and usage; skill layout, setup-copy sync procedure, design decisions | Module README; module navigation document | enforced |
  | `plugins/github-mcp/CHANGELOG.md`, `plugins/plugin-setup/CHANGELOG.md` | Released changes per version | Changelog | exempt: each entry restates what its release changed |

  Runtime prompt text under `plugins/github-mcp/hooks/prompts/*.md` and `plugins/plugin-setup/skills/*/SKILL.md` are runtime files, not documentation surfaces.

## Post-Step-6

After editing a `.sh` file, run `shellcheck --shell=bash` on it; CI lints all of `plugins/`, `plugin-tests/`, and `.github/scripts/`. After editing a `.ts` file, run `npx tsc --noEmit -p .` and `npx eslint . --max-warnings 0`.
