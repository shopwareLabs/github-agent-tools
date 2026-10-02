#!/usr/bin/env bats
# bats file_tags=github-mcp,pi,package
# The files `npm pack` puts into the pi package tarball: everything the
# extension, the gates, and the MCP servers need at runtime, nothing from the
# tests, CI, or the other hosts' manifests, and executable server entry points.
bats_require_minimum_version 1.11.0

load 'test_helper/common_setup'

setup_file() {
    (cd "${REPO_ROOT}" && npm pack --dry-run --json) >"${BATS_FILE_TMPDIR}/pack.json"
}

# Prints every tarball path, one per line.
packed_paths() {
    jq -r '.[0].files[].path' "${BATS_FILE_TMPDIR}/pack.json"
}

# Prints, relative to the repository root, the plugin files matching a find
# expression below a plugin subdirectory.
# Args: $1=subdirectory of the plugin, remaining=find expression
plugin_files() {
    local subdirectory="$1"
    shift
    (cd "${REPO_ROOT}" && find "plugins/${PLUGIN_NAME}/${subdirectory}" "$@" -type f)
}

@test "the tarball contains package.json and every runtime file of the plugin" {
    local prefix="plugins/${PLUGIN_NAME}"
    local -a expected=(
        "package.json"
        "${prefix}/pi/index.ts"
        "${prefix}/pi/gate.ts"
        "${prefix}/mcp-server-gh/server-read.sh"
        "${prefix}/mcp-server-gh/server-write.sh"
        "${prefix}/mcp-server-gh/tools-read.json"
        "${prefix}/mcp-server-gh/tools-write.json"
        "${prefix}/mcp-server-gh/tools-empty.json"
        "${prefix}/mcp-server-gh/config-read.json"
        "${prefix}/mcp-server-gh/config-write.json"
        "${prefix}/shared/mcpserver_core.sh"
        "${prefix}/shared/config-dirs.sh"
    )
    local -a globbed
    mapfile -t globbed < <(
        plugin_files mcp-server-gh/lib -maxdepth 1 -name '*.sh'
        plugin_files hooks/scripts -name '*.sh'
        plugin_files hooks/prompts -maxdepth 1 -name '*.md'
    )
    assert [ "${#globbed[@]}" -gt 0 ]

    run comm -23 <(printf '%s\n' "${expected[@]}" "${globbed[@]}" | sort -u) <(packed_paths | sort -u)
    assert_success
    assert_output ""
}

@test "the tarball contains no logs, tests, CI files, plugin-setup, or host manifests" {
    run jq -r '
        .[0].files[].path
        | select(test("\\.log$") or test("^(plugin-tests|\\.github|plugins/plugin-setup)/")
                 or test("(^|/)\\.(claude|codex)-plugin/"))
    ' "${BATS_FILE_TMPDIR}/pack.json"
    assert_success
    assert_output ""
}

@test "the server entry points and the session-start hook are packed with mode 0755" {
    # npm reports modes in decimal: 493 is 0755.
    run jq -c --arg prefix "plugins/${PLUGIN_NAME}" '
        [.[0].files[]
         | select(.path == "\($prefix)/mcp-server-gh/server-read.sh"
                  or .path == "\($prefix)/mcp-server-gh/server-write.sh"
                  or .path == "\($prefix)/hooks/scripts/session-start.sh")
         | [.path, .mode]]
        | sort
    ' "${BATS_FILE_TMPDIR}/pack.json"
    assert_success
    assert_output "[[\"plugins/${PLUGIN_NAME}/hooks/scripts/session-start.sh\",493],[\"plugins/${PLUGIN_NAME}/mcp-server-gh/server-read.sh\",493],[\"plugins/${PLUGIN_NAME}/mcp-server-gh/server-write.sh\",493]]"
}
