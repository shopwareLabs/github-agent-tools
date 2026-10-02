#!/usr/bin/env bats
# bats file_tags=github-mcp,pi,package
# The root package.json that makes the repository a pi package: its version
# tracks the plugin manifests, it installs nothing at runtime, and the pi
# packages it builds against stay host-provided.
bats_require_minimum_version 1.11.0

load 'test_helper/common_setup'

setup() {
    PACKAGE_JSON="${REPO_ROOT}/package.json"
}

@test "package.json version equals both plugin manifest versions" {
    local package_version claude_version codex_version
    package_version=$(jq -er '.version' "${PACKAGE_JSON}")
    claude_version=$(jq -er '.version' "${PLUGIN_DIR}/.claude-plugin/plugin.json")
    codex_version=$(jq -er '.version' "${PLUGIN_DIR}/.codex-plugin/plugin.json")

    assert_equal "${claude_version}" "${package_version}"
    assert_equal "${codex_version}" "${package_version}"
}

@test "every pi extension entry points at an existing file" {
    local -a extensions
    mapfile -t extensions < <(jq -r '.pi.extensions[]' "${PACKAGE_JSON}")

    assert [ "${#extensions[@]}" -gt 0 ]
    local extension
    for extension in "${extensions[@]}"; do
        assert [ -f "${REPO_ROOT}/${extension}" ]
    done
}

@test "package.json declares no runtime dependencies" {
    run jq 'has("dependencies")' "${PACKAGE_JSON}"
    assert_output "false"
}

@test "package.json declares no scripts" {
    run jq 'has("scripts")' "${PACKAGE_JSON}"
    assert_output "false"
}

@test "every @earendil-works package is a \"*\" peer dependency or only a dev dependency" {
    run jq -c '
        def earendil: to_entries[] | select(.key | startswith("@earendil-works/"));
        [ (.dependencies // {}, .optionalDependencies // {} | earendil | .key),
          (.peerDependencies // {} | earendil | select(.value != "*") | .key) ]
    ' "${PACKAGE_JSON}"
    assert_success
    assert_output "[]"
}

@test "pi-coding-agent and pi-ai are pinned to the same dev version" {
    local agent_version ai_version
    agent_version=$(jq -er '.devDependencies["@earendil-works/pi-coding-agent"]' "${PACKAGE_JSON}")
    ai_version=$(jq -er '.devDependencies["@earendil-works/pi-ai"]' "${PACKAGE_JSON}")

    assert_equal "${ai_version}" "${agent_version}"
}

@test "the pi extension imports @earendil-works packages only as types" {
    local -a ts_files
    mapfile -t ts_files < <(find "${PLUGIN_DIR}/pi" -type f -name '*.ts')
    assert [ "${#ts_files[@]}" -gt 0 ]

    # Matches whole statements, so multi-line imports are covered; dynamic
    # import() is never type-only.
    run perl -0777 -ne '
        while (/^\s*((?:import|export)\b[^;]*?["\x27]\@earendil-works\/[^;]*)/mg) {
            my $statement = $1;
            print "$ARGV: $statement\n" unless $statement =~ /^(?:import|export)\s+type\s/;
        }
        print "$ARGV: $1\n" while /(\bimport\s*\(\s*["\x27]\@earendil-works\/[^)]*\))/g;
    ' "${ts_files[@]}"
    assert_success
    assert_output ""
}
