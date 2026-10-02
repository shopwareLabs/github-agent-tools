#!/usr/bin/env bash
# Common utilities for gh-tooling MCP server
# Provides input validation and repo resolution helpers

source "$(dirname "${BASH_SOURCE[0]}")/../../shared/config-dirs.sh"

#######################################
# Locate .mcp-gh-tooling.json. MCP_GH_TOOLING_CONFIG wins outright; otherwise
# the last existing file of the list wins: project root, editor directories,
# then the host directories of github_mcp_config_dirs in reverse, so the
# active host's directory is checked last.
# Globals:
#   MCP_GH_TOOLING_CONFIG, GITHUB_MCP_HOST (read); GH_TOOLING_CONFIG_FILE (set)
# Arguments:
#   $1 project root, $2 log line when no config is found.
#######################################
_load_gh_config() {
    local project_root="$1"
    local no_config_message="$2"
    local config_name=".mcp-gh-tooling.json"

    if [[ -n "${MCP_GH_TOOLING_CONFIG:-}" ]]; then
        if [[ -f "${MCP_GH_TOOLING_CONFIG}" ]]; then
            GH_TOOLING_CONFIG_FILE="${MCP_GH_TOOLING_CONFIG}"
            log "INFO" "Config from MCP_GH_TOOLING_CONFIG: ${GH_TOOLING_CONFIG_FILE}"
        else
            log "WARN" "MCP_GH_TOOLING_CONFIG set but file not found: ${MCP_GH_TOOLING_CONFIG}"
        fi
        return 0
    fi

    local -a locations=(
        "${project_root}/${config_name}"
        "${project_root}/.aiassistant/${config_name}"
        "${project_root}/.amazonq/${config_name}"
        "${project_root}/.cline/${config_name}"
        "${project_root}/.cursor/${config_name}"
        "${project_root}/.kiro/${config_name}"
        "${project_root}/.windsurf/${config_name}"
        "${project_root}/.zed/${config_name}"
    )

    local -a host_dirs=()
    local dir
    while IFS= read -r dir; do
        host_dirs+=("${dir}")
    done < <(github_mcp_config_dirs "${GITHUB_MCP_HOST:-}")

    local i
    for (( i = ${#host_dirs[@]} - 1; i >= 0; i-- )); do
        locations+=("${project_root}/${host_dirs[i]}/${config_name}")
    done

    local loc
    for loc in "${locations[@]}"; do
        if [[ -f "${loc}" ]]; then
            GH_TOOLING_CONFIG_FILE="${loc}"
            log "INFO" "Found config: ${loc}"
        fi
    done

    if [[ -z "${GH_TOOLING_CONFIG_FILE}" ]]; then
        log "INFO" "${no_config_message}"
    fi
}

#######################################
# Validate a GitHub number (PR, issue, run, or job ID): digits only, non-empty.
# Arguments:
#   $1 value, $2 field name for the error message (default: number).
# Outputs:
#   An error message on stdout when the value is invalid.
# Returns:
#   0 when valid, 1 otherwise.
#######################################
_gh_validate_number() {
    local value="$1"
    local field="${2:-number}"
    if [[ -z "${value}" ]] || [[ ! "${value}" =~ ^[0-9]+$ ]]; then
        echo "Error: ${field} must be a positive integer, got: '${value}'"
        return 1
    fi
}

#######################################
# Validate a GitHub repository in owner/repo format. An empty value is valid
# and means the caller falls back to the default repository.
# Arguments:
#   $1 repository string.
# Outputs:
#   An error message on stdout when the format is invalid.
# Returns:
#   0 when valid or empty, 1 otherwise.
#######################################
_gh_validate_repo() {
    local repo="$1"
    [[ -z "${repo}" ]] && return 0
    if [[ ! "${repo}" =~ ^[a-zA-Z0-9_.-]+/[a-zA-Z0-9_.-]+$ ]]; then
        echo "Error: repo must be in 'owner/repo' format, got: '${repo}'"
        return 1
    fi
}

#######################################
# Validate a git commit SHA: 7 to 40 hex characters.
# Arguments:
#   $1 SHA string.
# Outputs:
#   An error message on stdout when the SHA is invalid.
# Returns:
#   0 when valid, 1 otherwise.
#######################################
_gh_validate_sha() {
    local sha="$1"
    if [[ -z "${sha}" ]] || [[ ! "${sha}" =~ ^[0-9a-fA-F]{7,40}$ ]]; then
        echo "Error: sha must be a valid git commit hash (7-40 hex chars), got: '${sha}'"
        return 1
    fi
}

#######################################
# Resolve the effective repository for an API call: the repo argument first,
# then GH_DEFAULT_REPO.
# Globals:
#   GH_DEFAULT_REPO (read)
# Arguments:
#   $1 repo from the tool arguments, may be empty.
# Outputs:
#   The resolved repository on stdout, empty when neither source has one.
#######################################
_gh_resolve_repo() {
    local repo_arg="${1:-}"
    echo "${repo_arg:-${GH_DEFAULT_REPO:-}}"
}

#######################################
# Require a repository, passed or configured as the default.
# Arguments:
#   $1 effective repository, as _gh_resolve_repo returns it.
# Outputs:
#   An error message on stdout when the repository is empty.
# Returns:
#   0 when a repository is set, 1 otherwise.
#######################################
_gh_require_repo() {
    local effective_repo="$1"
    if [[ -z "${effective_repo}" ]]; then
        echo "Error: repo is required. Pass 'repo' argument or set 'repo' in .mcp-gh-tooling.json"
        return 1
    fi
}

#######################################
# Require a repository, or a working directory inside a git repository.
# Tools using gh subcommands (gh pr view, gh issue list) that resolve from local
# git context call this instead of _gh_require_repo to preserve the in-repo
# "omit repo" workflow while still failing prescriptively in non-git contexts.
# Arguments:
#   $1 effective repository, from _gh_resolve_repo or _gh_resolve_owner_repo.
# Outputs:
#   An error message on stdout when neither is available.
# Returns:
#   0 when a repository or a git working directory is available, 1 otherwise.
#######################################
_gh_require_repo_or_git() {
    local effective_repo="$1"
    [[ -n "${effective_repo}" ]] && return 0
    git rev-parse --git-dir >/dev/null 2>&1 && return 0
    echo "Error: repo is required outside a git repository. Pass 'repo' / 'repository' / 'owner'+'repo' argument or set 'repo' in .mcp-gh-tooling.json"
    return 1
}

#######################################
# Reject an organization login that is not one path segment of GitHub's login
# charset, so it cannot steer the request to a different API path.
# Arguments:
#   $1 candidate login, $2 tool name for the error message.
# Outputs:
#   An error message on stdout when the login is malformed.
# Returns:
#   0 when the login is usable, 1 otherwise.
#######################################
_gh_validate_org() {
    local org="$1" tool="$2"
    if [[ ! "${org}" =~ ^[A-Za-z0-9][A-Za-z0-9-]*$ ]]; then
        printf '%s\n' "Error: invalid organization '${org}' for ${tool}. Expected a GitHub organization login."
        return 1
    fi
}

#######################################
# Resolve the organization owning org-level resources (issue types, issue fields).
# Priority: org > owner > repo-shaped args > GH_DEFAULT_REPO > git remote.
# Globals:
#   GH_DEFAULT_REPO, _GH_OWNER
# Arguments:
#   $1 JSON args string, $2 tool name for the error message.
# Outputs:
#   Organization login on stdout, or an error message on stdout.
# Returns:
#   0 when an organization was resolved, 1 otherwise.
#######################################
_gh_resolve_org() {
    local args="$1" tool="$2"

    local org owner
    org=$(printf '%s\n' "${args}" | jq -r '.org // empty')
    owner=$(printf '%s\n' "${args}" | jq -r '.owner // empty')

    if [[ -n "${org}" ]]; then
        _gh_validate_org "${org}" "${tool}" || return 1
        printf '%s\n' "${org}"
        return 0
    fi
    if [[ -n "${owner}" ]]; then
        _gh_validate_org "${owner}" "${tool}" || return 1
        printf '%s\n' "${owner}"
        return 0
    fi

    # Not run in a command substitution: the resolver reports through globals,
    # which a subshell would discard. Its own error text goes to our stdout.
    if ! _gh_resolve_owner_repo_optional "${args}"; then
        return 1
    fi
    if [[ -n "${_GH_OWNER}" ]]; then
        _gh_validate_org "${_GH_OWNER}" "${tool}" || return 1
        printf '%s\n' "${_GH_OWNER}"
        return 0
    fi

    local name_with_owner
    name_with_owner=$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null) || true
    if [[ -n "${name_with_owner}" ]]; then
        _gh_validate_org "${name_with_owner%%/*}" "${tool}" || return 1
        printf '%s\n' "${name_with_owner%%/*}"
        return 0
    fi

    printf '%s\n' "Error: org is required for ${tool}. Pass 'org', 'owner', or a repository ('repository', 'repo', or 'owner'+'repo'), or set 'repo' in .mcp-gh-tooling.json"
    return 1
}

# Read a value from the gh-tooling config file
# Args: $1 = jq path (e.g. '.repo'), $2 = default value
_gh_config_value() {
    local path="$1"
    local default="${2:-}"
    [[ -f "${GH_TOOLING_CONFIG_FILE:-}" ]] || { echo "${default}"; return 0; }
    local value
    value=$(jq -r "${path} // empty" "${GH_TOOLING_CONFIG_FILE}" 2>/dev/null || echo "")
    [[ -n "${value}" ]] && echo "${value}" || echo "${default}"
}

# Validate jq filter syntax before execution.
# Only rejects definitive compile/parse/lexical errors; runtime errors on null are acceptable.
# Args: $1 = filter expression, $2 = field name for error message (default: jq_filter)
# Outputs error message to stdout and returns 1 on compile-time syntax failure.
_gh_validate_jq_filter() {
    local filter="$1"
    local field="${2:-jq_filter}"
    [[ -z "${filter}" ]] && return 0
    local err
    err=$(jq -n "${filter}" 2>&1 1>/dev/null) || true
    if [[ -n "${err}" ]] && echo "${err}" | grep -qiE "compile error|unexpected \\\$end|parse error|lexical error"; then
        echo "Error: Invalid ${field}: ${err}"
        return 1
    fi
}

#######################################
# Determine whether the installed gh accepts `gh api --allow-escape-sequences`
# and record the answer in a global.
#
# gh 2.97.0 made `gh api` refuse to print a raw non-JSON body containing ESC
# bytes unless the flag is passed; an older gh rejects the flag as unknown and
# has no such refusal, so omitting it there reaches the same output rather than
# a degraded one. This is the only capability-conditional behavior here.
#
# The result is reported through a global rather than stdout: a command
# substitution would run the probe in a subshell and discard the cache, turning
# a once-per-process `gh api --help` into one per tool call.
#
# The help text is captured and matched in the shell rather than piped to
# `grep -q`. Under the servers' `pipefail`, `grep -q` closing the pipe on the
# first match kills gh with SIGPIPE, and the pipeline's non-zero status would
# then record the flag as absent on exactly the runs that found it.
# Globals:
#   _GH_ALLOW_ESCAPE_FLAG — set to the flag, or to the empty string.
#######################################
_gh_probe_allow_escape_flag() {
    [[ -n "${_GH_ALLOW_ESCAPE_FLAG+set}" ]] && return 0
    local help_text
    help_text=$(gh api --help 2>/dev/null) || help_text=""
    if [[ "${help_text}" == *"--allow-escape-sequences"* ]]; then
        _GH_ALLOW_ESCAPE_FLAG="--allow-escape-sequences"
    else
        _GH_ALLOW_ESCAPE_FLAG=""
    fi
}

#######################################
# Strip terminal escape sequences from text.
#
# Passing --allow-escape-sequences without this would put raw ESC bytes into a
# tool result the host renders in a terminal, which is the hazard gh's refusal
# guards against; stripping keeps that guarantee and leaves the text greppable.
#
# The sed program is plain BRE with no alternation, because BSD sed has no
# `\|`, and uses `|` as the delimiter so the CSI intermediate range can contain
# `/`. LC_ALL=C makes the byte ranges byte ranges: BSD sed collates them under
# the ambient locale and rejects `[@-_]`.
#
# The expressions run in this order:
#   1. OSC terminated by BEL, 2. OSC terminated by ST. Neither payload class
#      admits BEL or ESC, so a run with one terminator cannot swallow the text
#      up to a later run with the other.
#   3. CSI. 4. nF sequences (intermediates then a final), which is what
#      `ESC ( B` is. 5. any other ESC plus one final byte, covering `ESC c`,
#      `ESC 7` and `ESC M`. 6. a bare trailing ESC.
# Rule 6 is what makes the guarantee absolute: no ESC byte reaches the caller,
# whatever gh emitted.
# Arguments:
#   $1 text to clean.
# Outputs:
#   The text with escape sequences removed, on stdout.
#######################################
_gh_strip_ansi() {
    printf '%s\n' "$1" | LC_ALL=C sed \
        -e $'s|\033\\][^\007\033]*\007||g' \
        -e $'s|\033\\][^\007\033]*\033\\\\||g' \
        -e $'s|\033\\[[0-9;:<=>?]*[ -/]*[@-~]||g' \
        -e $'s|\033[ -/][ -/]*[0-~]||g' \
        -e $'s|\033[0-~]||g' \
        -e $'s|\033||g'
}

# Apply optional pipeline post-processing steps in order: jq → grep → head → tail.
# Each step is a no-op when its controlling parameter is empty/zero.
# Args: $1=output $2=jq_filter $3=grep_pattern $4=grep_before $5=grep_after
#       $6=grep_ignore_case $7=grep_invert $8=max_lines $9=tail_lines
# Outputs processed text to stdout; returns 1 if jq filter fails on the output.
_gh_post_process() {
    local output="$1"
    local jq_filter="${2:-}"
    local grep_pattern="${3:-}"
    local grep_before="${4:-0}"
    local grep_after="${5:-0}"
    local grep_ignore_case="${6:-false}"
    local grep_invert="${7:-false}"
    local max_lines="${8:-}"
    local tail_lines="${9:-}"

    if [[ -n "${jq_filter}" ]]; then
        output=$(echo "${output}" | jq "${jq_filter}") || {
            echo "Error: jq filter failed on output: ${jq_filter}"
            return 1
        }
    fi

    if [[ -n "${grep_pattern}" ]]; then
        local -a gcmd=("grep" "-E")
        [[ "${grep_ignore_case}" == "true" ]] && gcmd+=("-i")
        [[ "${grep_invert}" == "true" ]]      && gcmd+=("-v")
        [[ "${grep_before}" -gt 0 ]]          && gcmd+=("-B" "${grep_before}")
        [[ "${grep_after}" -gt 0 ]]           && gcmd+=("-A" "${grep_after}")
        gcmd+=("--" "${grep_pattern}")
        output=$(echo "${output}" | "${gcmd[@]}") || true
    fi

    if [[ -n "${max_lines}" && "${max_lines}" -gt 0 ]]; then
        output=$(echo "${output}" | head -n "${max_lines}")
    fi

    if [[ -n "${tail_lines}" && "${tail_lines}" -gt 0 ]]; then
        output=$(echo "${output}" | tail -n "${tail_lines}")
    fi

    echo "${output}"
}

#######################################
# Parse a GitHub URL into owner, repo, ref, and path components.
# Handles /tree/{ref}/{path} and /blob/{ref}/{path} URLs.
# Limitation: refs with slashes (e.g. feature/branch) take only the first segment.
# Globals:
#   _GH_URL_OWNER, _GH_URL_REPO, _GH_URL_REF, _GH_URL_PATH (set)
# Arguments:
#   $1 URL.
# Returns:
#   0 when parsed, 1 for non-GitHub URLs or unrecognized formats.
#######################################
_gh_parse_github_url() {
    local url="$1"
    _GH_URL_OWNER="" _GH_URL_REPO="" _GH_URL_REF="" _GH_URL_PATH=""

    # Must be a github.com URL
    if [[ ! "${url}" =~ ^https?://github\.com/ ]]; then
        return 1
    fi

    # Strip scheme and host
    local path_part="${url#*github.com/}"

    # Extract owner/repo (first two segments)
    local owner repo remainder
    owner="${path_part%%/*}"
    remainder="${path_part#*/}"
    repo="${remainder%%/*}"
    remainder="${remainder#*/}"

    if [[ -z "${owner}" || -z "${repo}" ]]; then
        return 1
    fi

    # Strip .git suffix if present
    repo="${repo%.git}"

    _GH_URL_OWNER="${owner}"
    _GH_URL_REPO="${repo}"

    # If there's nothing beyond owner/repo, we're done
    if [[ "${path_part}" == "${owner}/${repo}" || "${remainder}" == "${repo}" ]]; then
        return 0
    fi

    # Check for tree/ or blob/ prefix
    local kind="${remainder%%/*}"
    if [[ "${kind}" == "tree" || "${kind}" == "blob" ]]; then
        remainder="${remainder#*/}"
        # First segment after tree/blob is the ref
        _GH_URL_REF="${remainder%%/*}"
        # Everything after ref is the path
        local after_ref="${remainder#*/}"
        if [[ "${after_ref}" != "${_GH_URL_REF}" ]]; then
            _GH_URL_PATH="${after_ref}"
        fi
    fi

    return 0
}

#######################################
# Reject a repository path with a leading slash or a '..' anywhere in it, so
# it cannot leave the repository. The substring check also refuses names such
# as a..b.txt. An empty path is valid and means the root.
# Arguments:
#   $1 path string.
# Outputs:
#   An error message on stdout when the path is rejected.
# Returns:
#   0 when valid or empty, 1 otherwise.
#######################################
_gh_validate_path() {
    local path="$1"
    [[ -z "${path}" ]] && return 0
    if [[ "${path}" == /* ]]; then
        echo "Error: path must not start with '/': ${path}"
        return 1
    fi
    if [[ "${path}" == *".."* ]]; then
        echo "Error: path must not contain '..': ${path}"
        return 1
    fi
}

# Partial-download helper state (see _gh_partial_create). Each tool call runs
# in its own subshell, so these never leak between calls.
_GH_DL_TMP=""
_GH_DL_TRAP_INSTALLED=""

#######################################
# EXIT handler installed by _gh_partial_create. Removes the in-flight partial
# file, if any.
#
# No earlier EXIT handler is captured or chained here. Each tool call runs in
# a subshell of the server (`( … ) &` in the vendored protocol layer), and a
# subshell that has not set an EXIT trap of its own reports its parent's
# handler to `trap -p` — here, the server's own teardown trap. A captured
# handler can't be told apart from that inherited one, so running it on
# cancellation would run the server's teardown inside the tool's shell. A
# tool's shell has no EXIT handler of its own to preserve today.
# Globals:
#   _GH_DL_TMP
#######################################
_gh_partial_cleanup() {
    [[ -n "${_GH_DL_TMP}" ]] && rm -f -- "${_GH_DL_TMP}"
}

#######################################
# Create a download's `<dest>.partial.*` sibling and, on first use in this
# shell, install the EXIT trap that removes it on cancellation.
#
# The file is created with `noclobber` in this shell rather than via
# `mktemp`, whose command substitution creates the file in a subshell well
# before this shell can name it for the trap. What remains is the single
# assignment after creation: a SIGTERM there leaves an empty partial file.
# Globals:
#   _GH_DL_TMP (set to the created path on success), _GH_DL_TRAP_INSTALLED
# Arguments:
#   $1 destination path the partial file sits beside.
# Outputs:
#   An error naming the directory on failure.
# Returns:
#   0 on success, 1 after 5 failed attempts or a non-collision failure.
#######################################
_gh_partial_create() {
    local dest="$1"

    if [[ -z "${_GH_DL_TRAP_INSTALLED}" ]]; then
        trap '_gh_partial_cleanup' EXIT
        _GH_DL_TRAP_INSTALLED=1
    fi

    local had_noclobber=1
    [[ -o noclobber ]] || had_noclobber=0
    set -o noclobber

    # The name is recorded only after noclobber has created the file, so the
    # trap never removes a file another process left under the same name.
    local attempt=0 candidate
    _GH_DL_TMP=""
    while (( attempt < 5 )); do
        attempt=$(( attempt + 1 ))
        candidate="${dest}.partial.${BASHPID}.${RANDOM}${RANDOM}"
        if { : > "${candidate}"; } 2>/dev/null; then
            _GH_DL_TMP="${candidate}"
            break
        fi
        # Not a name collision — e.g. the parent directory is missing.
        [[ -e "${candidate}" ]] || break
    done

    [[ ${had_noclobber} -eq 1 ]] || set +o noclobber

    if [[ -z "${_GH_DL_TMP}" ]]; then
        echo "Error: cannot create a temporary file in $(dirname "${dest}")"
        return 1
    fi
}

#######################################
# Clear partial-download state after a rename or an explicit removal. The
# EXIT trap installed by _gh_partial_create stays in place — see that
# function and _gh_partial_cleanup for why nothing is restored in its place.
# Globals:
#   _GH_DL_TMP
#######################################
_gh_partial_finish() {
    _GH_DL_TMP=""
}

#######################################
# Download a file from GitHub to a local path, byte for byte.
# Arguments:
#   $1 owner, $2 repo, $3 remote path, $4 local path, $5 ref (optional).
# Outputs:
#   An error message on stdout when the download or the write fails.
# Returns:
#   0 when the file is in place at the local path, 1 otherwise.
#######################################
_gh_download_file() {
    local owner="$1" repo="$2" remote_path="$3" local_path="$4" ref="${5:-}"
    local -a cmd=("gh" "api" "repos/${owner}/${repo}/contents/${remote_path}")
    [[ -n "${ref}" ]] && cmd+=("-f" "ref=${ref}")
    cmd+=("-H" "Accept: application/vnd.github.raw+json")
    # Raw file bytes: gh refuses to emit a body carrying ESC without the flag.
    # The bytes are written verbatim to disk, so nothing strips them afterwards.
    _gh_probe_allow_escape_flag
    [[ -n "${_GH_ALLOW_ESCAPE_FLAG}" ]] && cmd+=("${_GH_ALLOW_ESCAPE_FLAG}")

    local parent_dir
    parent_dir=$(dirname "${local_path}")
    mkdir -p "${parent_dir}" 2>/dev/null || {
        echo "Error: cannot create directory ${parent_dir}"
        return 1
    }

    # Write to a sibling and rename once the body is complete. A cancelled call
    # has its process group killed mid-write, and a half-written file at the
    # target path reads as a complete one.
    _gh_partial_create "${local_path}" || return 1
    local tmp_path="${_GH_DL_TMP}"

    # stderr is captured apart from the body so gh's own diagnostics never
    # become the file's contents; a warning on an otherwise successful
    # download is logged instead of discarded.
    local dl_err="" dl_exit=0
    dl_err=$({ "${cmd[@]}" > "${tmp_path}"; } 2>&1) || dl_exit=$?
    if [[ ${dl_exit} -ne 0 ]]; then
        rm -f -- "${tmp_path}"
        _gh_partial_finish
        if [[ -n "${dl_err}" ]]; then
            echo "Error: failed to download ${owner}/${repo}/${remote_path}: ${dl_err}"
        else
            echo "Error: failed to download ${owner}/${repo}/${remote_path}"
        fi
        return 1
    fi
    [[ -n "${dl_err}" ]] && log "WARN" "gh reported during download of ${owner}/${repo}/${remote_path}: ${dl_err}"

    mv -- "${tmp_path}" "${local_path}" || {
        rm -f -- "${tmp_path}"
        _gh_partial_finish
        echo "Error: cannot write ${local_path}"
        return 1
    }
    _gh_partial_finish
}

#######################################
# Resolve owner/repo from multiple sources with priority:
# url > owner+repo > repository (owner/repo) > repo (owner/repo) > GH_DEFAULT_REPO
# Globals:
#   GH_DEFAULT_REPO (read); _GH_OWNER, _GH_REPO, _GH_REF, _GH_PATH (set)
# Arguments:
#   $1 JSON args string.
# Outputs:
#   An error message on stdout when no source resolves or one is malformed.
# Returns:
#   0 when owner and repo are set, 1 otherwise.
#######################################
_gh_resolve_owner_repo() {
    local args="$1"
    _GH_OWNER="" _GH_REPO="" _GH_REF="" _GH_PATH=""

    local url owner repo repository ref path
    url=$(echo "${args}" | jq -r '.url // empty')
    owner=$(echo "${args}" | jq -r '.owner // empty')
    repo=$(echo "${args}" | jq -r '.repo // empty')
    repository=$(echo "${args}" | jq -r '.repository // empty')
    ref=$(echo "${args}" | jq -r '.ref // empty')
    path=$(echo "${args}" | jq -r '.path // empty')

    # Priority 1: URL
    if [[ -n "${url}" ]]; then
        _gh_parse_github_url "${url}" || {
            echo "Error: could not parse GitHub URL: ${url}"
            return 1
        }
        _GH_OWNER="${_GH_URL_OWNER}"
        _GH_REPO="${_GH_URL_REPO}"
        [[ -n "${_GH_URL_REF}" ]] && _GH_REF="${_GH_URL_REF}"
        [[ -n "${_GH_URL_PATH}" ]] && _GH_PATH="${_GH_URL_PATH}"
        # Explicit params override URL-extracted values
        [[ -n "${ref}" ]] && _GH_REF="${ref}"
        [[ -n "${path}" ]] && _GH_PATH="${path}"
        return 0
    fi

    # Priority 2: explicit owner + repo (split form). `repo` must be a bare
    # repo name; a slash here indicates the caller meant `repository` instead.
    if [[ -n "${owner}" && -n "${repo}" ]]; then
        if [[ "${repo}" == */* ]]; then
            echo "Error: when 'owner' is set, 'repo' must be the bare repository name (no slash). Got owner='${owner}', repo='${repo}'. Either pass 'repo' as the name only, or drop 'owner' and pass 'repository' (owner/repo) instead."
            return 1
        fi
        _GH_OWNER="${owner}"
        _GH_REPO="${repo}"
        _GH_REF="${ref}"
        _GH_PATH="${path}"
        return 0
    fi

    # Priority 3: repository (owner/repo format)
    if [[ -n "${repository}" ]]; then
        _gh_validate_repo "${repository}" || return 1
        _GH_OWNER="${repository%%/*}"
        _GH_REPO="${repository#*/}"
        _GH_REF="${ref}"
        _GH_PATH="${path}"
        return 0
    fi

    # Priority 4: bare `repo` in owner/repo form (legacy alias of `repository`,
    # preserves the historical issue/PR tool param shape).
    if [[ -n "${repo}" ]]; then
        _gh_validate_repo "${repo}" || return 1
        _GH_OWNER="${repo%%/*}"
        _GH_REPO="${repo#*/}"
        _GH_REF="${ref}"
        _GH_PATH="${path}"
        return 0
    fi

    # Priority 5: GH_DEFAULT_REPO
    if [[ -n "${GH_DEFAULT_REPO:-}" ]]; then
        _GH_OWNER="${GH_DEFAULT_REPO%%/*}"
        _GH_REPO="${GH_DEFAULT_REPO#*/}"
        _GH_REF="${ref}"
        _GH_PATH="${path}"
        return 0
    fi

    echo "Error: repository is required. Provide 'url', 'owner'+'repo', 'repository', or 'repo' (owner/repo), or set 'repo' in .mcp-gh-tooling.json"
    return 1
}

#######################################
# Verify the running server's own tools list is present and well-formed
# before startup completes. The protocol layer reads MCP_TOOLS_LIST_FILE
# lazily, once per tools/list or tools/call request, so nothing else catches
# a missing or corrupt list before the first call — the server would start
# cleanly and then fail every tools/list and tools/call request.
# Globals:
#   MCP_TOOLS_LIST_FILE
# Outputs:
#   An error naming the file, to stderr.
# Returns:
#   0 when the file holds exactly one JSON object, whose `tools` is an array
#   (the protocol layer's own reader requires the single object); 1 otherwise.
#######################################
_gh_require_tools_list() {
    if ! jq -e -s 'length == 1 and (.[0] | type) == "object" and (.[0].tools | type) == "array"' \
        -- "${MCP_TOOLS_LIST_FILE}" >/dev/null 2>&1; then
        log "ERROR" "Tools list is missing or invalid: ${MCP_TOOLS_LIST_FILE}"
        echo "Error: tools list is missing or invalid: ${MCP_TOOLS_LIST_FILE}" >&2
        return 1
    fi
}

#######################################
# Like _gh_resolve_owner_repo, but returns success with empty globals when no
# repo source is provided. Use for tools that have a valid no-repo fallback
# (e.g. gh's own git-context resolution for issue/PR subcommands inside a clone).
# Globals:
#   GH_DEFAULT_REPO (read); _GH_OWNER, _GH_REPO, _GH_REF, _GH_PATH (set)
# Arguments:
#   $1 JSON args string.
# Outputs:
#   An error message on stdout when a provided source is malformed.
# Returns:
#   0 when resolved or when no source is provided, 1 otherwise.
#######################################
_gh_resolve_owner_repo_optional() {
    local args="$1"
    _GH_OWNER="" _GH_REPO="" _GH_REF="" _GH_PATH=""

    local has_source
    has_source=$(echo "${args}" | jq -r '
        if (.url // "") != "" then "1"
        elif (.owner // "") != "" then "1"
        elif (.repo // "") != "" then "1"
        elif (.repository // "") != "" then "1"
        else "" end
    ')
    if [[ -z "${has_source}" && -z "${GH_DEFAULT_REPO:-}" ]]; then
        return 0
    fi

    _gh_resolve_owner_repo "${args}"
}
