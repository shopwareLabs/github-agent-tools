#!/usr/bin/env bats
# bats file_tags=github-mcp,mcp-tools,cancellation
# A cancelled download leaves nothing next to the destination.
#
# repo_file and search_code write to a `<dest>.partial.*` sibling and rename it
# once the body is complete. The protocol layer cancels a call by sending
# SIGTERM to the call's process group; afterwards the destination directory
# holds only files whose download finished.
bats_require_minimum_version 1.11.0

load 'test_helper/common_setup'

setup() {
    log() { :; }

    GH_DEFAULT_REPO="shopware/shopware"
    GH_TOOLING_CONFIG_FILE=""

    source "${GH_LIB_DIR}/common.sh"
    source "${GH_LIB_DIR}/search.sh"
    source "${GH_LIB_DIR}/repo.sh"

    DL_DIR="${BATS_TEST_TMPDIR}/dl"
    mkdir -p "${DL_DIR}"

    # The search answers with one match; a file download writes part of a body
    # and then blocks, so the call is still mid-write when it is cancelled.
    gh() {
        if [[ "$1" == "api" && "$2" == "--help" ]]; then
            return 0
        fi
        if [[ "$1" == "search" ]]; then
            printf '%s\n' '[{"repository":{"nameWithOwner":"shopware/shopware"},"path":"composer.json"}]'
            return 0
        fi
        printf '%s' '{"name": "shopware/'
        sleep 30
    }
}

# Run a tool the way the protocol layer does — in a background subshell leading
# its own process group, stdin closed — and set CALL_PID to the group's pid.
start_tool_call() {
    local tool_fn="$1" args="$2"
    set -m
    ( set +e; "${tool_fn}" "${args}" ) > "${BATS_TEST_TMPDIR}/call-output" 2>&1 < /dev/null &
    CALL_PID=$!
    set +m
}

# Wait up to 5 seconds for a non-empty partial file under the given directory,
# optionally one whose name starts with the given destination file name.
wait_for_partial_body() {
    local dir="$1" name="${2:-}" waited=0
    while [[ ${waited} -lt 50 ]]; do
        if find "${dir}" -name "${name}*.partial.*" -size +0 | grep -q .; then
            return 0
        fi
        sleep 0.1
        waited=$((waited + 1))
    done
    fail "no partial download appeared under ${dir} within 5 seconds"
}

# Send SIGTERM to the call's process group and wait up to 5 seconds for it to
# end. A group still alive after that is killed so the test cannot hang.
cancel_tool_call() {
    local pid="$1" waited=0
    kill -TERM -- "-${pid}"
    while kill -0 -- "-${pid}" 2>/dev/null && [[ ${waited} -lt 50 ]]; do
        sleep 0.1
        waited=$((waited + 1))
    done
    if kill -0 -- "-${pid}" 2>/dev/null; then
        kill -KILL -- "-${pid}" 2>/dev/null || true
        wait "${pid}" || true
        fail "the cancelled call was still running 5 seconds after SIGTERM"
    fi
    wait "${pid}" || true
}

@test "a cancelled repo_file download removes its partial file" {
    local dest="${DL_DIR}/composer.json"
    start_tool_call tool_repo_file '{"repository":"shopware/shopware","path":"composer.json","download_to":"'"${dest}"'"}'
    wait_for_partial_body "${DL_DIR}"

    cancel_tool_call "${CALL_PID}"

    run find "${DL_DIR}" -name '*.partial.*'
    assert_output ""
    assert [ ! -e "${dest}" ]
}

@test "a cancelled search_code download removes its partial file" {
    local dest="${DL_DIR}/shopware/shopware/composer.json"
    start_tool_call tool_search_code '{"search":"name","download_to":"'"${DL_DIR}"'"}'
    wait_for_partial_body "${DL_DIR}"

    cancel_tool_call "${CALL_PID}"

    run find "${DL_DIR}" -name '*.partial.*'
    assert_output ""
    assert [ ! -e "${dest}" ]
}

@test "a search_code download cancelled on its second file keeps the first and drops the second" {
    local dest_a="${DL_DIR}/shopware/shopware/a.json"
    local dest_b="${DL_DIR}/shopware/shopware/b.json"

    # Two matches: the first download completes, the second blocks mid-write.
    # The cancel waits for the second file's partial body, so it lands there.
    gh() {
        if [[ "$1" == "api" && "$2" == "--help" ]]; then
            return 0
        fi
        if [[ "$1" == "search" ]]; then
            printf '%s\n' '[{"repository":{"nameWithOwner":"shopware/shopware"},"path":"a.json"},{"repository":{"nameWithOwner":"shopware/shopware"},"path":"b.json"}]'
            return 0
        fi
        if [[ "$*" == *"a.json"* ]]; then
            printf '%s' '{"first":"complete"}'
            return 0
        fi
        printf '%s' '{"second":"incomplete'
        sleep 30
    }

    start_tool_call tool_search_code '{"search":"name","download_to":"'"${DL_DIR}"'"}'
    wait_for_partial_body "${DL_DIR}" "b.json"

    cancel_tool_call "${CALL_PID}"

    run find "${DL_DIR}" -name '*.partial.*'
    assert_output ""
    assert [ -e "${dest_a}" ]
    assert_equal "$(cat "${dest_a}")" '{"first":"complete"}'
    assert [ ! -e "${dest_b}" ]
}

@test "a cancelled repo_file download with suppress_errors leaves no partial or destination" {
    local dest="${DL_DIR}/composer.json"
    start_tool_call tool_repo_file '{"repository":"shopware/shopware","path":"composer.json","download_to":"'"${dest}"'","suppress_errors":true}'
    wait_for_partial_body "${DL_DIR}"

    cancel_tool_call "${CALL_PID}"

    run find "${DL_DIR}" -name '*.partial.*'
    assert_output ""
    assert [ ! -e "${dest}" ]
}
