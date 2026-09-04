#!/usr/bin/env bats
# bats file_tags=github-mcp,mcp-tools
# Tests for gh's --allow-escape-sequences guard: the capability probe, the flag
# reaching the raw-body call sites, and the ANSI strip applied to what the text
# tools return.
bats_require_minimum_version 1.11.0

load 'test_helper/common_setup'

setup() {
    log() { :; }

    GH_DEFAULT_REPO="shopware/shopware"
    GH_TOOLING_CONFIG_FILE=""

    source "${GH_LIB_DIR}/common.sh"
    source "${GH_LIB_DIR}/job.sh"
    source "${GH_LIB_DIR}/api.sh"
    source "${GH_LIB_DIR}/repo.sh"

    GH_ARGS_FILE="${BATS_TEST_TMPDIR}/gh_args"

    # `gh api --help` answers from GH_HELP_OUTPUT so a test can present a gh that
    # advertises the flag or one that does not; every other call captures its
    # arguments one per line, like the other tool suites.
    gh() {
        if [[ "$1" == "api" && "$2" == "--help" ]]; then
            printf '%s\n' "${GH_HELP_OUTPUT:-}"
            return 0
        fi
        printf '%s\n' "$@" > "${GH_ARGS_FILE}"
        [[ -n "${GH_STUB_STDERR:-}" ]] && echo "${GH_STUB_STDERR}" >&2
        [[ -n "${GH_STUB_OUTPUT:-}" ]] && printf '%s\n' "${GH_STUB_OUTPUT}"
        return "${GH_STUB_EXIT:-0}"
    }

    GH_HELP_OUTPUT="      --allow-escape-sequences   Allow printing terminal escape sequences"
    GH_STUB_OUTPUT=""
    GH_STUB_STDERR=""
    GH_STUB_EXIT=0
}

# Assert the captured gh argument list contains an exact argument.
assert_gh_arg() {
    run grep -x -F -- "$1" "${GH_ARGS_FILE}"
    assert_success
}

# Assert the captured gh argument list does not contain an exact argument.
refute_gh_arg() {
    run grep -x -F -- "$1" "${GH_ARGS_FILE}"
    assert_failure
}

# =============================================================================
# Capability probe
# =============================================================================

@test "probe reports the flag when gh api advertises it" {
    _gh_probe_allow_escape_flag
    assert_equal "${_GH_ALLOW_ESCAPE_FLAG}" "--allow-escape-sequences"
}

@test "probe reports nothing when gh api does not advertise the flag" {
    GH_HELP_OUTPUT="      --paginate   Make additional HTTP requests to fetch all pages"
    _gh_probe_allow_escape_flag
    assert_equal "${_GH_ALLOW_ESCAPE_FLAG}" ""
}

@test "probe still finds the flag under pipefail with a long help body" {
    # Regression: reading the help through `grep -q` let grep close the pipe on
    # the first match, and gh's SIGPIPE status then recorded the flag as absent
    # under the servers' pipefail — inverting the answer on exactly the runs
    # that found it.
    set -o pipefail
    local filler
    filler=$(for _ in $(seq 1 5000); do printf '      --some-other-flag   padding\n'; done)
    GH_HELP_OUTPUT="      --allow-escape-sequences   Allow printing terminal escape sequences
${filler}"
    _gh_probe_allow_escape_flag
    assert_equal "${_GH_ALLOW_ESCAPE_FLAG}" "--allow-escape-sequences"
}

@test "probe caches its answer instead of re-reading gh api --help" {
    GH_HELP_COUNT_FILE="${BATS_TEST_TMPDIR}/help_calls"
    gh() {
        if [[ "$1" == "api" && "$2" == "--help" ]]; then
            printf 'x\n' >> "${GH_HELP_COUNT_FILE}"
            printf '      --allow-escape-sequences   Allow printing terminal escape sequences\n'
            return 0
        fi
        return 0
    }
    _gh_probe_allow_escape_flag
    _gh_probe_allow_escape_flag
    _gh_probe_allow_escape_flag
    assert_equal "$(wc -l < "${GH_HELP_COUNT_FILE}" | tr -d ' ')" "1"
}

# =============================================================================
# The flag reaches every raw-body call site
# =============================================================================

@test "job_logs passes the flag to gh api" {
    GH_STUB_OUTPUT="log line"
    run tool_job_logs '{"job_id":"99"}'
    assert_success
    assert_gh_arg "--allow-escape-sequences"
}

@test "job_logs omits the flag when gh does not know it" {
    GH_HELP_OUTPUT="      --paginate   Make additional HTTP requests to fetch all pages"
    GH_STUB_OUTPUT="log line"
    run tool_job_logs '{"job_id":"99"}'
    assert_success
    refute_gh_arg "--allow-escape-sequences"
}

@test "api passes the flag to gh api" {
    GH_STUB_OUTPUT='{"id":1}'
    run tool_api '{"endpoint":"repos/shopware/shopware/actions/jobs/99/logs"}'
    assert_success
    assert_gh_arg "--allow-escape-sequences"
}

@test "api_read passes the flag to gh api" {
    GH_STUB_OUTPUT='{"id":1}'
    run tool_api_read '{"endpoint":"repos/shopware/shopware/actions/jobs/99/logs"}'
    assert_success
    assert_gh_arg "--allow-escape-sequences"
}

@test "repo_file passes the flag to gh api" {
    GH_STUB_OUTPUT="file contents"
    run tool_repo_file '{"repository":"shopware/shopware","path":"README.md"}'
    assert_success
    assert_gh_arg "--allow-escape-sequences"
}

@test "_gh_download_file passes the flag to gh api" {
    GH_STUB_OUTPUT="file contents"
    run _gh_download_file "shopware" "shopware" "README.md" "${BATS_TEST_TMPDIR}/dl/README.md"
    assert_success
    assert_gh_arg "--allow-escape-sequences"
}

@test "job_view leaves the flag off its JSON endpoint" {
    GH_STUB_OUTPUT='{"id":99}'
    run tool_job_view '{"job_id":"99"}'
    assert_success
    refute_gh_arg "--allow-escape-sequences"
}

# =============================================================================
# ANSI stripping
# =============================================================================

@test "_gh_strip_ansi removes CSI colour sequences" {
    run _gh_strip_ansi "$(printf 'a\033[31mred\033[0mb')"
    assert_success
    assert_output "aredb"
}

@test "_gh_strip_ansi removes a BEL-terminated OSC sequence" {
    run _gh_strip_ansi "$(printf '\033]0;window title\007kept')"
    assert_success
    assert_output "kept"
}

@test "_gh_strip_ansi removes an ST-terminated OSC sequence" {
    run _gh_strip_ansi "$(printf '\033]8;;https://example.com\033\\kept')"
    assert_success
    assert_output "kept"
}

@test "_gh_strip_ansi removes a two-character escape sequence" {
    run _gh_strip_ansi "$(printf '\033Mkept')"
    assert_success
    assert_output "kept"
}

@test "_gh_strip_ansi removes escapes outside the Fe range" {
    # ESC c (reset), ESC 7 (save cursor) and ESC ( B (charset select) all sit
    # outside 0x40-0x5F, so a rule written for Fe sequences alone leaves them.
    run _gh_strip_ansi "$(printf 'a\033cb\0337c\033(Bd')"
    assert_success
    assert_output "abcd"
}

@test "_gh_strip_ansi removes a trailing bare ESC" {
    run _gh_strip_ansi "$(printf 'kept\033')"
    assert_success
    assert_output "kept"
}

@test "_gh_strip_ansi keeps text between OSC runs with different terminators" {
    # The BEL-terminated rule must not consume from an earlier ST-terminated
    # run through to a later BEL, which would delete the text in between.
    run _gh_strip_ansi "$(printf 'A\033]0;first\033\\KEEP\033]1;second\007Z')"
    assert_success
    assert_output "AKEEPZ"
}

@test "_gh_strip_ansi leaves no ESC byte in its output" {
    local dirty
    dirty=$(printf 'x\033[31my\033]0;t\007z\033(B\0337\033c\033')
    run _gh_strip_ansi "${dirty}"
    assert_success
    printf '%s' "${output}" > "${BATS_TEST_TMPDIR}/stripped"
    run grep -c "$(printf '\033')" "${BATS_TEST_TMPDIR}/stripped"
    assert_failure
}

@test "_gh_strip_ansi leaves bracket and digit text alone" {
    run _gh_strip_ansi 'PHPStan [31m] found 12 errors in src/[Core]/Foo.php at 2026-09-04'
    assert_success
    assert_output 'PHPStan [31m] found 12 errors in src/[Core]/Foo.php at 2026-09-04'
}

@test "_gh_strip_ansi keeps multi-line text on its own lines" {
    run _gh_strip_ansi "$(printf 'first\n\033[32msecond\033[0m\nthird')"
    assert_success
    assert_line --index 0 "first"
    assert_line --index 1 "second"
    assert_line --index 2 "third"
}

# =============================================================================
# Stripping at the tools that return text
# =============================================================================

@test "job_logs returns log text with escape sequences removed" {
    GH_STUB_OUTPUT="$(printf '\033[31mERROR\033[0m assertion failed')"
    run tool_job_logs '{"job_id":"99"}'
    assert_success
    assert_output "ERROR assertion failed"
}

@test "job_logs greps the stripped text, not the coloured bytes" {
    GH_STUB_OUTPUT="$(printf 'ok line\n\033[31mERROR\033[0m boom')"
    run tool_job_logs '{"job_id":"99","grep_pattern":"^ERROR"}'
    assert_success
    assert_output "ERROR boom"
}

@test "api returns body text with escape sequences removed" {
    GH_STUB_OUTPUT="$(printf '\033[33mwarning\033[0m raised')"
    run tool_api '{"endpoint":"repos/shopware/shopware/actions/jobs/99/logs"}'
    assert_success
    assert_output "warning raised"
}

@test "repo_file returns file text with escape sequences removed" {
    GH_STUB_OUTPUT="$(printf '\033[36mline one\033[0m')"
    run tool_repo_file '{"repository":"shopware/shopware","path":"README.md"}'
    assert_success
    assert_output "line one"
}

@test "repo_file download_to writes the body byte-for-byte" {
    GH_STUB_OUTPUT="$(printf 'plain \033[31mred\033[0m')"
    printf '%s\n' "${GH_STUB_OUTPUT}" > "${BATS_TEST_TMPDIR}/expected"
    run tool_repo_file "{\"repository\":\"shopware/shopware\",\"path\":\"a.bin\",\"download_to\":\"${BATS_TEST_TMPDIR}/a.bin\"}"
    assert_success
    run cmp -s "${BATS_TEST_TMPDIR}/expected" "${BATS_TEST_TMPDIR}/a.bin"
    assert_success
}

@test "_gh_download_file writes the body byte-for-byte" {
    GH_STUB_OUTPUT="$(printf 'plain \033[31mred\033[0m')"
    printf '%s\n' "${GH_STUB_OUTPUT}" > "${BATS_TEST_TMPDIR}/expected"
    run _gh_download_file "shopware" "shopware" "a.bin" "${BATS_TEST_TMPDIR}/dl/a.bin"
    assert_success
    run cmp -s "${BATS_TEST_TMPDIR}/expected" "${BATS_TEST_TMPDIR}/dl/a.bin"
    assert_success
}
