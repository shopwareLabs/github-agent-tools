#!/bin/bash
# Vendor the bash-mcp-sdk protocol handler into this repository
# =============================================================
# Reads the pinned release from .mcp-sdk.lock and writes the SDK's
# lib/mcpserver_core.sh to every consuming path.
#
#   vendor-mcp-sdk.sh            re-vendor, overwriting each target
#   vendor-mcp-sdk.sh --check    compare only; non-zero when a copy has drifted

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$(dirname "$SCRIPT_DIR")")"

LOCK_FILE="${REPO_ROOT}/.mcp-sdk.lock"
SDK_REPO="shopwareLabs/bash-mcp-sdk"
SDK_FILE="lib/mcpserver_core.sh"

# Every path in this repository holding a copy of the SDK file. Add a row here
# when a second plugin starts consuming it.
VENDOR_TARGETS=(
    "plugins/github-mcp/shared/mcpserver_core.sh"
)

# Set once the download destination exists. Global rather than a local of
# main(), because the EXIT trap runs after main() has returned and its locals
# are gone — under `set -u` that reads as an unbound variable, not an empty one.
TMPFILE=""

#######################################
# Remove the download destination, if one was created.
# Globals:
#   TMPFILE
#######################################
cleanup() {
    if [[ -n "$TMPFILE" ]]; then
        rm -f -- "$TMPFILE"
    fi
}
trap cleanup EXIT

#######################################
# Read the pinned release tag from the lock file.
# Globals:
#   LOCK_FILE
# Outputs:
#   The tag (vX.Y.Z) on stdout; diagnostics on stderr.
# Returns:
#   0 on success, 1 when the lock file is missing or its version is malformed.
#######################################
read_pinned_version() {
    if [[ ! -f "$LOCK_FILE" ]]; then
        printf 'Lock file not found: %s\n' "$LOCK_FILE" >&2
        return 1
    fi

    local version
    version=$(grep -m 1 -oE '^version=v[0-9]+\.[0-9]+\.[0-9]+$' "$LOCK_FILE" 2>/dev/null | cut -d= -f2) || true

    if [[ -z "$version" ]]; then
        printf 'No version=vX.Y.Z line in %s\n' "$LOCK_FILE" >&2
        return 1
    fi

    printf '%s\n' "$version"
}

#######################################
# Download the SDK file at a tag into a local path.
# Globals:
#   SDK_REPO, SDK_FILE
# Arguments:
#   Release tag, e.g. v1.0.0.
#   Destination path.
# Outputs:
#   Diagnostics on stderr.
# Returns:
#   0 on success, 1 when the download fails or returns something that is not
#   the SDK file.
#######################################
download_sdk() {
    local version="$1" destination="$2"
    local url="https://raw.githubusercontent.com/${SDK_REPO}/${version}/${SDK_FILE}"

    if ! curl -fsSL --retry 3 --retry-delay 2 -o "$destination" -- "$url"; then
        printf 'Download failed: %s\n' "$url" >&2
        return 1
    fi

    # A tag that exists but carries no such file, or a proxy error page, both
    # arrive as a 200 with the wrong bytes. The SDK is a shell script.
    if [[ ! -s "$destination" ]] || ! head -n 1 -- "$destination" | grep -q '^#!'; then
        printf 'Downloaded file is not a shell script: %s\n' "$url" >&2
        return 1
    fi
}

main() {
    local check_only=false
    if [[ "${1:-}" == "--check" ]]; then
        check_only=true
    elif [[ $# -gt 0 ]]; then
        printf 'Usage: %s [--check]\n' "$(basename -- "$0")" >&2
        exit 2
    fi

    local version
    version=$(read_pinned_version) || exit 1

    TMPFILE=$(mktemp "${TMPDIR:-/tmp}/mcpserver_core.XXXXXX")

    download_sdk "$version" "$TMPFILE" || exit 1

    printf '%s %s at %s\n' \
        "$([[ "$check_only" == true ]] && printf 'Checking' || printf 'Vendoring')" \
        "${SDK_REPO}/${SDK_FILE}" "$version"

    local drifted=0 target absolute
    for target in "${VENDOR_TARGETS[@]}"; do
        absolute="${REPO_ROOT}/${target}"

        if [[ "$check_only" == true ]]; then
            if [[ ! -f "$absolute" ]]; then
                printf '  MISSING  %s\n' "$target"
                drifted=$(( drifted + 1 ))
            elif cmp -s -- "$TMPFILE" "$absolute"; then
                printf '  ok       %s\n' "$target"
            else
                printf '  DRIFTED  %s\n' "$target"
                drifted=$(( drifted + 1 ))
            fi
            continue
        fi

        cp -- "$TMPFILE" "$absolute"
        # No `--` here: BSD chmod has no end-of-options marker and reads it as
        # a file name. Every target is a fixed path under REPO_ROOT.
        chmod 755 "$absolute"
        printf '  wrote    %s\n' "$target"
    done

    if [[ "$check_only" == true && $drifted -gt 0 ]]; then
        printf '\nVendored copies out of date: %d (pinned release %s).\n' \
            "$drifted" "$version" >&2
        printf 'Run .github/scripts/vendor-mcp-sdk.sh to refresh them, and send\n' >&2
        printf 'protocol changes to the SDK repository rather than editing here.\n' >&2
        exit 1
    fi
}

main "$@"
