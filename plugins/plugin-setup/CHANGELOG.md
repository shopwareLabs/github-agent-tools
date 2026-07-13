# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.0.0] - 2026-07-13

### Added
- Initial release. Bundles the `github-mcp-setting-up` skill, which walks users through
  configuring the `github-mcp` plugin: verifies the `gh` CLI is installed and authenticated,
  checks `jq`, optionally creates `.mcp-gh-tooling.json` (default repo, write server, label
  definitions), pre-approves the MCP tool permissions in `.claude/settings.local.json`, and
  reports remaining manual steps. The skill's `references/plugin-setup.md` is a byte-identical
  copy of `plugins/github-mcp/SETUP.md`. Extracted from the `plugin-setup` plugin in
  `shopwareLabs/ai-coding-tools`, trimmed to the github-mcp skill only.
