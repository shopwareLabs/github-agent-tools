#!/bin/bash
# Stand-in for the gh CLI in pi_e2e.bats, linked as `gh` first on PATH so no
# call reaches GitHub. Logs every invocation to $GH_LOG. Answers only
# `pr view <n> --repo <r> --json <fields>`, with {"number":<n>,"title":"stub"}
# restricted to the requested fields; anything else fails.

set -euo pipefail

printf '%s\n' "$*" >> "${GH_LOG:?GH_LOG must point at the invocation log}"

if [[ $# -eq 7 && "$1" == "pr" && "$2" == "view" && "$4" == "--repo" && "$6" == "--json" ]]; then
    jq -cn --argjson number "$3" --arg fields "$7" \
        '{number: $number, title: "stub"} | with_entries(select(.key as $key | $fields | split(",") | index($key)))'
    exit 0
fi

printf 'gh-stub: unsupported invocation: %s\n' "$*" >&2
exit 1
