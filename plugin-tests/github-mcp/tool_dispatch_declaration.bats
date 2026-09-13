#!/usr/bin/env bats
# bats file_tags=github-mcp,dispatch,gating
# A server must run only the tools its own tools list declares.
#
# api.sh, label.sh, and project.sh are shared by both servers and each carries
# tools the other does not declare. Dispatch resolves a tools/call to a shell
# function by name, so without _gh_unset_undeclared_tools every sourced tool is
# callable — which put the write-side label_add, label_remove, project_item_add,
# project_status_set, and api on the always-active read server, each running
# with no schema to validate its arguments against.
bats_require_minimum_version 1.11.0

load 'test_helper/common_setup'

setup() {
    PROJECT_DIR="${BATS_TEST_TMPDIR}/project"
    mkdir -p "${PROJECT_DIR}"
}

# Ask a server to run one tool with no arguments. A tool that is not dispatchable
# answers "Tool not found"; one that is reports a missing parameter of its own.
call_tool() {
    local server="$1" tool="$2" project_root="$3"
    printf '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"%s","arguments":{}}}\n' "$tool" \
        | env PROJECT_ROOT="$project_root" bash "${GH_SERVER_DIR}/${server}" 2>/dev/null \
        | tail -1 \
        | jq -r '.result.content[0].text // .error.message // "no answer"'
}

# Every tool_* function the given server sources but does not declare.
undeclared_tools() {
    local server="$1" tools_file="$2" lib sourced declared
    sourced=$(
        for lib in $(grep -o 'lib/[a-z_]*\.sh' "${GH_SERVER_DIR}/${server}" | sort -u); do
            grep -h -o '^tool_[a-z_0-9]*' "${GH_SERVER_DIR}/${lib}" 2>/dev/null
        done | sed 's/^tool_//' | sort -u
    )
    declared=$(jq -r '.tools[].name' "${GH_SERVER_DIR}/${tools_file}" | sort -u)
    comm -23 <(printf '%s\n' "$sourced") <(printf '%s\n' "$declared")
}

@test "read server does not dispatch any tool it does not declare" {
    local tool found=0
    while read -r tool; do
        [[ -n "$tool" ]] || continue
        found=$(( found + 1 ))
        run call_tool "server-read.sh" "$tool" "${PROJECT_DIR}"
        assert_success
        assert_output --partial "Tool not found: ${tool}"
    done < <(undeclared_tools "server-read.sh" "tools-read.json")

    # The read server sources write tools today; if that ever stops being true
    # this test would pass while checking nothing.
    [[ "$found" -gt 0 ]]
}

@test "read server still dispatches a tool it declares" {
    run call_tool "server-read.sh" "api_read" "${PROJECT_DIR}"
    assert_success
    refute_output --partial "Tool not found"
    assert_output --partial "endpoint"
}

@test "write server dispatches nothing while it is disabled" {
    printf '%s\n' '{"enable_write_server": false}' > "${PROJECT_DIR}/.mcp-gh-tooling.json"

    local tool
    for tool in pr_create issue_create label_add label_list api; do
        run call_tool "server-write.sh" "$tool" "${PROJECT_DIR}"
        assert_success
        assert_output --partial "Tool not found: ${tool}"
    done
}

@test "enabled write server dispatches its own tools but not undeclared ones" {
    printf '%s\n' '{"enable_write_server": true}' > "${PROJECT_DIR}/.mcp-gh-tooling.json"

    run call_tool "server-write.sh" "pr_create" "${PROJECT_DIR}"
    assert_success
    refute_output --partial "Tool not found"

    local tool found=0
    while read -r tool; do
        [[ -n "$tool" ]] || continue
        found=$(( found + 1 ))
        run call_tool "server-write.sh" "$tool" "${PROJECT_DIR}"
        assert_success
        assert_output --partial "Tool not found: ${tool}"
    done < <(undeclared_tools "server-write.sh" "tools-write.json")

    [[ "$found" -gt 0 ]]
}

@test "disabled write server writes no tools list of its own" {
    printf '%s\n' '{"enable_write_server": false}' > "${PROJECT_DIR}/.mcp-gh-tooling.json"

    printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"tools/list"}' \
        | env PROJECT_ROOT="${PROJECT_DIR}" bash "${GH_SERVER_DIR}/server-write.sh" >/dev/null 2>&1

    run find "${GH_SERVER_DIR}" -maxdepth 1 -name 'tools-empty.*.json'
    assert_success
    assert_output ""
}
