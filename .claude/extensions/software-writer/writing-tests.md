## Named-value assignments

- `project.stacks` =
  - `bash` — `plugins/**/*.sh`, `.github/scripts/*.sh`, `plugin-tests/**/*.{bats,bash,sh}`
  - `typescript` — `plugins/github-mcp/pi/*.ts`, `plugin-tests/github-mcp/{pi,fixtures/pi}/*.ts`; executed directly by Node ≥22.19 type stripping, no build step (`tsconfig.json`: `erasableSyntaxOnly`, `allowImportingTsExtensions`; relative imports keep the `.ts` extension)
- `tests.frameworks` =
  - BATS (bats-core + bats-support + bats-assert, vendored into `.bats/` by `.github/scripts/setup-bats.sh`) for every `plugin-tests/**/*.bats`. Run with `.bats/bats-core/bin/bats -r plugin-tests/`. No BATS framework reference ships with the skill: apply the universal rules. Every suite opens with `# bats file_tags=github-mcp,<area>[,<sub-area>]` and `bats_require_minimum_version 1.11.0`; keep both on new suites.
  - `node:test` for `plugin-tests/github-mcp/pi/*.test.ts`. Run with `node --test 'plugin-tests/github-mcp/pi/*.test.ts'`; type-checked by `npx tsc --noEmit -p .`.
  - End-to-end layer: `plugin-tests/github-mcp/pi_e2e.bats` drives the real `node_modules/.bin/pi` with `--offline` against the scripted faux model in `plugin-tests/github-mcp/fixtures/pi/driver.ts`. Requires `npm ci` and GNU `timeout` or `gtimeout` on PATH.
- `tests.fixture_sources` =
  - `plugin-tests/test_helper/common_setup.bash` — `run_hook`, `assert_hook_blocks`, `setup_config`, `setup_codex_config` for hook-script suites.
  - `plugin-tests/github-mcp/test_helper/common_setup.bash` — path constants `PLUGIN_DIR`, `SCRIPTS_DIR`, `SESSION_SCRIPT`, `SHARED_DIR`, `GH_SERVER_DIR`, `GH_LIB_DIR`, and the default `setup()`; load it with `load 'test_helper/common_setup'` instead of hardcoding `plugins/github-mcp/` paths.
  - Stubbing `gh` in tool-function suites: define a `gh()` function override in `setup()` driven by `GH_STUB_OUTPUT`, `GH_STUB_STDERR`, and `GH_STUB_EXIT`, reset in `setup()`.
  - pi end-to-end only: `plugin-tests/github-mcp/fixtures/pi/gh-stub.sh` (PATH-shim `gh`, logs to `$GH_LOG`) and the `$SCENARIO`-selected scripts in `fixtures/pi/driver.ts`.
  - `node:test`: per-test temp directories from `mkdtempSync(join(tmpdir(), …))` removed in `t.after`.
- `tests.parallelism` = Both runners currently execute serially: CI runs `bats --timing -r plugin-tests/` without `--jobs`, and no `plugin-tests/github-mcp/pi/*.test.ts` file sets `concurrency`. Write every test to stay correct under `bats --jobs`: per-test state lives in `BATS_TEST_TMPDIR`, `setup_file` state in `BATS_FILE_TMPDIR`, and nothing under `PLUGIN_DIR`, `GH_SERVER_DIR`, or `SCRIPTS_DIR` is mutated in place — copy it into the temp directory first, as `plugin-tests/github-mcp/server_startup_tools_list.bats` does.

## Pre-Step-2

Read `plugins/github-mcp/AGENTS.md` §Testing and place the test in the suite that table assigns to the behavior's area. When creating a new suite, add its row to that table.

## Post-Step-6

Run `shellcheck --shell=bash` on every edited `.bats` or `.bash` file; CI lints all of `plugin-tests/`. After editing a `.ts` test or fixture, run `npx tsc --noEmit -p .` and `npx eslint . --max-warnings 0`; `eslint.config.mjs` carries a dedicated block for `plugin-tests/**/*.ts`.
