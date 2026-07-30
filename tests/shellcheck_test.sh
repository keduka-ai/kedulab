#!/usr/bin/env bash
# Shell lint gate. This mirrors the ShellCheck job in .github/workflows/ci.yml
# exactly — same file list, same flags — so a lint regression surfaces from
# `tests/run_all.sh` instead of only after a push. Keep the two in lockstep: if
# one grows a path or changes an exclusion, so must the other.
#
# Why the flags: install.sh is piped into bash from the internet by real users
# and scripts/entrypoint.sh runs as PID 1 in every container, so quoting and
# `cd` bugs in either are expensive. SC1091 (can't follow non-constant source)
# is not useful here.
#
# SKIPs cleanly when shellcheck is not installed, so the suite still runs on a
# host without it. Note the CI runner's shellcheck version and a local one can
# differ; CI remains the authority.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || exit 1

if ! command -v shellcheck >/dev/null 2>&1; then
    echo "SKIP: shellcheck not on PATH — shell lint not run"
    exit 0
fi

if ! out="$(shellcheck --severity=warning --exclude=SC1091 \
        install.sh \
        scripts/*.sh \
        tests/*.sh 2>&1)"; then
    echo "FAIL: shellcheck findings (this is the same gate CI enforces):" >&2
    printf '%s\n' "$out" >&2
    exit 1
fi

echo "PASS: shellcheck clean across install.sh, scripts/*.sh, tests/*.sh"
