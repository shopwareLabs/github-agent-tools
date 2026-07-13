#!/usr/bin/env bats
# bats file_tags=github-mcp,codex,launcher
bats_require_minimum_version 1.11.0

load 'test_helper/common_setup'

CODEX_MANIFEST="${PLUGIN_DIR}/.codex-plugin/plugin.json"

@test "Codex launcher locates the cached plugin and preserves project cwd" {
    local codex_home="${BATS_TEST_TMPDIR}/codex-home"
    local cached_plugin="${codex_home}/plugins/cache/github-agent-tools/github-mcp/3.5.0"
    local project_dir="${BATS_TEST_TMPDIR}/project"
    mkdir -p "${cached_plugin}/mcp-server-gh" "$project_dir"
    printf '%s\n' '#!/usr/bin/env bash' 'pwd' > "${cached_plugin}/mcp-server-gh/server-read.sh"
    chmod +x "${cached_plugin}/mcp-server-gh/server-read.sh"

    local launcher arg0 mode
    launcher=$(jq -r '.mcpServers["gh-tooling"].args[1]' "$CODEX_MANIFEST")
    arg0=$(jq -r '.mcpServers["gh-tooling"].args[2]' "$CODEX_MANIFEST")
    mode=$(jq -r '.mcpServers["gh-tooling"].args[3]' "$CODEX_MANIFEST")

    run bash -c 'cd "$1" && CODEX_HOME="$2" bash -c "$3" "$4" "$5"' \
        _ "$project_dir" "$codex_home" "$launcher" "$arg0" "$mode"

    assert_success
    assert_output "$project_dir"
}
