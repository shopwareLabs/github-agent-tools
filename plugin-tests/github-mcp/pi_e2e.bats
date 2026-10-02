#!/usr/bin/env bats
# bats file_tags=github-mcp,pi,e2e
# Drives the real pi binary against the installed package with a scripted model
# (fixtures/pi/driver.ts) and a stubbed gh (fixtures/pi/gh-stub.sh), offline.
# setup_file installs each package variant, runs pi once per scenario, and keeps
# the outputs; every test asserts over those outputs.
bats_require_minimum_version 1.11.0

load 'test_helper/common_setup'

PI_BIN="${REPO_ROOT}/node_modules/.bin/pi"
FIXTURES_DIR="${BATS_TEST_DIRNAME}/fixtures/pi"
REPO_SLUG="shopwareLabs/github-agent-tools"
FILES_ENDPOINT="repos/${REPO_SLUG}/pulls/8/files"

# Resolves the GNU `timeout` binary this suite bounds each pi run with.
# Stock macOS ships neither name under PATH's `timeout`; Homebrew's coreutils
# provides it as `gtimeout`. Fails the suite outright rather than skipping.
resolve_timeout_bin() {
    if command -v timeout >/dev/null 2>&1; then
        command -v timeout
    elif command -v gtimeout >/dev/null 2>&1; then
        command -v gtimeout
    else
        printf 'pi_e2e.bats: no "timeout" or "gtimeout" on PATH. Install GNU coreutils (e.g. "brew install coreutils").\n' >&2
        return 1
    fi
}

# Reproduces offline what `pi install git:…` runs: a clone, then npm install in it.
# The cloned repository is a one-commit snapshot of the working tree (tracked and
# non-ignored untracked files that exist on disk, modes and symlinks kept), so the
# layout ships uncommitted changes exactly as the next commit would.
install_git_layout() {
    local source="${BATS_FILE_TMPDIR}/git-source" layout="${BATS_FILE_TMPDIR}/git-layout"
    local listed="${BATS_FILE_TMPDIR}/git-source-listed" present="${BATS_FILE_TMPDIR}/git-source-present"
    local path
    git -C "${REPO_ROOT}" ls-files -z --cached --others --exclude-standard >"${listed}"
    while IFS= read -r -d '' path; do
        if [[ -e "${REPO_ROOT}/${path}" || -L "${REPO_ROOT}/${path}" ]]; then
            printf '%s\0' "${path}"
        fi
    done <"${listed}" >"${present}"
    mkdir -p "${source}"
    tar -C "${REPO_ROOT}" --null -T "${present}" -cf "${BATS_FILE_TMPDIR}/git-source.tar"
    tar -C "${source}" -xf "${BATS_FILE_TMPDIR}/git-source.tar"
    git -C "${source}" init --quiet
    git -C "${source}" add --all --force
    git -C "${source}" -c user.name=pi-e2e -c user.email=pi-e2e@localhost -c commit.gpgsign=false \
        commit --quiet --no-verify -m "working tree snapshot"
    git clone --quiet "${source}" "${layout}"
    (cd "${layout}" && npm install --omit=dev --legacy-peer-deps --offline --no-audit --no-fund)
    git -C "${layout}" status --porcelain >"${BATS_FILE_TMPDIR}/git-layout-status"
}

# Reproduces offline what `pi install npm:…` runs: npm install of the tarball under a prefix.
install_npm_layout() {
    local pack_dir="${BATS_FILE_TMPDIR}/npm-pack" prefix="${BATS_FILE_TMPDIR}/npm-prefix" tarball
    mkdir -p "${pack_dir}" "${prefix}"
    tarball=$(cd "${REPO_ROOT}" && npm pack --json --pack-destination "${pack_dir}" | jq -er '.[0].filename')
    npm install "${pack_dir}/${tarball}" --prefix "${prefix}" --legacy-peer-deps --offline --no-audit --no-fund
}

# Runs pi once for a scenario against a package variant; outputs land in
# ${BATS_FILE_TMPDIR}/<variant>-<scenario>/.
# Args: $1=variant (git|npm), $2=scenario (a driver.ts SCENARIO)
run_pi_scenario() {
    local variant="$1" scenario="$2"
    local run_dir="${BATS_FILE_TMPDIR}/${variant}-${scenario}" package_dir
    case "${variant}" in
        git) package_dir="${BATS_FILE_TMPDIR}/git-layout" ;;
        npm) package_dir="${BATS_FILE_TMPDIR}/npm-prefix/node_modules/@shopwarelabs/github-agent-tools" ;;
    esac

    mkdir -p "${run_dir}/project/.pi" "${run_dir}/bin" "${run_dir}/agent"
    git -C "${run_dir}/project" init --quiet
    git -C "${run_dir}/project" remote add origin "https://github.com/${REPO_SLUG}.git"
    printf '%s\n' '{"block_api_tool_read": true}' >"${run_dir}/project/.pi/.mcp-gh-tooling.json"
    ln -s "${FIXTURES_DIR}/gh-stub.sh" "${run_dir}/bin/gh"
    : >"${run_dir}/trace.jsonl"
    : >"${run_dir}/probe.jsonl"
    : >"${run_dir}/gh.log"

    PI_CODING_AGENT_DIR="${run_dir}/agent" "${PI_BIN}" install "${package_dir}" </dev/null

    local -a scenario_env=()
    case "${scenario}" in
        codemode)
            jq '. + {defaultTools: ["+codemode"]}' "${run_dir}/agent/settings.json" >"${run_dir}/settings.json"
            mv "${run_dir}/settings.json" "${run_dir}/agent/settings.json"
            ;;
        environment-leak)
            mkdir -p "${run_dir}/leak/.claude"
            printf '%s\n' '{"enforce_mcp_tools": false}' >"${run_dir}/leak/.claude/.mcp-gh-tooling.json"
            scenario_env=("CLAUDE_PROJECT_DIR=${run_dir}/leak")
            ;;
        mcp-override)
            printf '%s\n' '{"mcpServers": {"gh-tooling": {"command": "false", "enabled": false}}}' \
                >"${run_dir}/agent/mcp.json"
            ;;
    esac

    local status=0
    (
        cd "${run_dir}/project"
        env -u MCP_GH_TOOLING_CONFIG -u PROJECT_ROOT "${scenario_env[@]}" \
            PATH="${run_dir}/bin:${PATH}" \
            PI_CODING_AGENT_DIR="${run_dir}/agent" \
            SCENARIO="${scenario}" \
            TRACE="${run_dir}/trace.jsonl" \
            PROBE="${run_dir}/probe.jsonl" \
            GH_LOG="${run_dir}/gh.log" \
            "${TIMEOUT_BIN}" 60 "${PI_BIN}" --offline --no-session -e "${FIXTURES_DIR}/driver.ts" \
            --model faux/faux-1 --mode json -p go \
            </dev/null >"${run_dir}/stdout.jsonl" 2>"${run_dir}/stderr.log"
    ) || status=$?
    printf '%s\n' "${status}" >"${run_dir}/exit-code"
}

setup_file() {
    if [[ ! -x "${PI_BIN}" ]]; then
        printf 'pi_e2e.bats: %s not found. Run "npm ci" in %s first.\n' "${PI_BIN}" "${REPO_ROOT}" >&2
        return 1
    fi
    TIMEOUT_BIN=$(resolve_timeout_bin) || return 1
    # The environment-leak scenario sets it deliberately; no other run may inherit it.
    unset CLAUDE_PROJECT_DIR

    install_git_layout
    install_npm_layout
    run_pi_scenario git deferred
    run_pi_scenario npm deferred
    run_pi_scenario git codemode
    run_pi_scenario git environment-leak
    run_pi_scenario git mcp-override
}

# Prints {"isError": …, "text": …} for one finished tool call, text being the
# concatenated text parts of its result.
# Args: $1=run (<variant>-<scenario>), $2=toolCallId
tool_result() {
    jq -c --arg id "$2" '
        select(.type == "tool_execution_end" and .toolCallId == $id)
        | {isError, text: ([.result.content[] | select(.type == "text") | .text] | join(""))}
    ' "${BATS_FILE_TMPDIR}/$1/stdout.jsonl"
}

# Prints {"isError": …, "json": …} for a tool call whose result text is JSON.
# Args: $1=run, $2=toolCallId
tool_result_json() {
    tool_result "$1" "$2" | jq -c '{isError, json: (.text | fromjson)}'
}

# Fails unless the tool call ended as an error whose text contains the fragment.
# Args: $1=run, $2=toolCallId, $3=fragment
assert_tool_error_contains() {
    local result
    result=$(tool_result "$1" "$2")
    run jq -r '.isError' <<<"${result}"
    assert_output "true"
    run jq -r '.text' <<<"${result}"
    assert_output --partial "$3"
}

# Fails if the gh stub logged an invocation matching the regex.
# Args: $1=run, $2=regex over one logged argv line
refute_gh_invoked() {
    run grep -E "$2" "${BATS_FILE_TMPDIR}/$1/gh.log"
    assert_failure 1
}

# ============================================================================
# Scenario `deferred` — asserted for both package variants
# ============================================================================

assert_tools_deferred_until_searched() {
    local probe="${BATS_FILE_TMPDIR}/$1/probe.jsonl" expected_count
    expected_count=$(jq '.tools | length' "${GH_SERVER_DIR}/tools-read.json")

    run jq -nc 'first(inputs | select(.tool == "tool_search")) | .active' "${probe}"
    assert_output "0"
    run jq -nc 'first(inputs | select(.tool == "mcp__gh_tooling__pr_view")) | {all, exposures}' "${probe}"
    assert_output "{\"all\":${expected_count},\"exposures\":[\"deferred\"]}"
}

assert_tool_search_loads_pr_view() {
    local result
    result=$(tool_result "$1" search-pr-view)
    run jq -r '.isError' <<<"${result}"
    assert_output "false"
    run jq -r '.text' <<<"${result}"
    assert_output --partial "mcp__gh_tooling__pr_view"
}

assert_pr_view_returns_stub() {
    run tool_result_json "$1" pr-view-8
    assert_output '{"isError":false,"json":{"number":8,"title":"stub"}}'
}

assert_bash_gh_blocked() {
    assert_tool_error_contains "$1" bash-gh-pr-view "mcp__gh_tooling__pr_view"
    refute_gh_invoked "$1" '^pr view 8$'
}

assert_api_read_blocked() {
    assert_tool_error_contains "$1" api-read-files "pr_files"
    refute_gh_invoked "$1" '^api( |$)'
}

assert_parallel_pr_views_succeed() {
    local number
    for number in 11 12 13; do
        run tool_result_json "$1" "pr-view-${number}"
        assert_output "{\"isError\":false,\"json\":{\"number\":${number},\"title\":\"stub\"}}"
    done
}

assert_first_request_carries_sections() {
    local host_pi_text
    host_pi_text=$(<"${PLUGIN_DIR}/hooks/prompts/host-pi.md")
    local first_system
    first_system=$(jq -nc 'first(inputs) | .[0]' "${BATS_FILE_TMPDIR}/$1/trace.jsonl")

    run jq -r '.role' <<<"${first_system}"
    assert_output "system"
    run jq -r '.sections.github_mcp' <<<"${first_system}"
    assert_output --partial "${host_pi_text}"
    run jq -r '.sections.mcp_servers' <<<"${first_system}"
    assert_output --partial "mcp__gh_tooling (tool_search): "
}

assert_pi_exits_cleanly() {
    run cat "${BATS_FILE_TMPDIR}/$1/exit-code"
    assert_output "0"
}

@test "git layout: npm install in the clone leaves the working tree clean" {
    run cat "${BATS_FILE_TMPDIR}/git-layout-status"
    assert_output ""
}

@test "git layout: gh-tooling tools stay inactive until tool_search, and all are deferred" {
    assert_tools_deferred_until_searched git-deferred
}

@test "git layout: tool_search for pr_view loads mcp__gh_tooling__pr_view" {
    assert_tool_search_loads_pr_view git-deferred
}

@test "git layout: pr_view returns the stub's JSON" {
    assert_pr_view_returns_stub git-deferred
}

@test "git layout: bash gh pr view is blocked before gh runs" {
    assert_bash_gh_blocked git-deferred
}

@test "git layout: api_read on the PR files endpoint is blocked in favor of pr_files" {
    assert_api_read_blocked git-deferred
}

@test "git layout: three pr_view calls in one turn all succeed" {
    assert_parallel_pr_views_succeed git-deferred
}

@test "git layout: the first request carries the github_mcp and mcp_servers sections" {
    assert_first_request_carries_sections git-deferred
}

@test "git layout: pi exits 0" {
    assert_pi_exits_cleanly git-deferred
}

@test "npm layout: pr_view returns the stub's JSON" {
    assert_pr_view_returns_stub npm-deferred
}

@test "npm layout: bash gh pr view is blocked before gh runs" {
    assert_bash_gh_blocked npm-deferred
}

@test "npm layout: api_read on the PR files endpoint is blocked in favor of pr_files" {
    assert_api_read_blocked npm-deferred
}

@test "npm layout: the first request carries the github_mcp and mcp_servers sections" {
    assert_first_request_carries_sections npm-deferred
}

# ============================================================================
# Additional scenarios — git layout only
# ============================================================================

# Prints the value the codemode script returned: the JSON after its "Output:" line.
codemode_output() {
    tool_result git-codemode codemode-script | jq -c '.text | split("\nOutput:\n")[1] | fromjson'
}

@test "codemode: pr_view calls through Promise.all return the stub's JSON" {
    run jq -c '[.results[] | .isError, (.content[0].text | fromjson)]' < <(codemode_output)
    assert_output '[false,{"number":11,"title":"stub"},false,{"number":12,"title":"stub"},false,{"number":13,"title":"stub"}]'
}

@test "codemode: a blocked api_read rejects with the gate's message" {
    local payload gate_message
    payload=$(jq -cn --arg endpoint "${FILES_ENDPOINT}" --arg cwd "${BATS_FILE_TMPDIR}/git-codemode/project" \
        '{tool_name: "mcp__gh_tooling__api_read", tool_input: {endpoint: $endpoint}, cwd: $cwd}')
    # The environment pi's extension gives a gate: setup() exports CLAUDE_PROJECT_DIR,
    # which would otherwise resolve the hook as Claude Code.
    run --separate-stderr env -u CLAUDE_PROJECT_DIR GITHUB_MCP_HOST=pi bash "${SCRIPTS_DIR}/check-api-tools.sh" <<<"${payload}"
    assert_failure 2
    gate_message="${stderr}"

    run jq -r '.caught' < <(codemode_output)
    assert_output "${gate_message}"
}

@test "environment leak: CLAUDE_PROJECT_DIR disabling enforcement does not unblock bash gh" {
    assert_tool_error_contains git-environment-leak bash-gh-pr-view "mcp__gh_tooling__pr_view"
    refute_gh_invoked git-environment-leak '^pr view 8$'
}

@test "mcp.json override: pr_view of the disabled server is not found" {
    run tool_result git-mcp-override pr-view-8
    assert_output '{"isError":true,"text":"Tool mcp__gh_tooling__pr_view not found"}'
}

@test "mcp.json override: bash gh pr view is still blocked" {
    assert_tool_error_contains git-mcp-override bash-gh-pr-view "mcp__gh_tooling__pr_view"
    refute_gh_invoked git-mcp-override '^pr view 8$'
}
