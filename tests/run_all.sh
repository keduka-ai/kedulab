#!/usr/bin/env bash
# Run the whole test suite. This is what CI invokes.
#
# Every test is written to run without a Docker daemon: the compose tests use
# `docker compose config` (client-side only), the entrypoint tests use stub
# binaries, and the installer tests mock docker and clone from a local bare
# repo. tests/image_smoke_test.sh is the one exception — it SKIPs cleanly when
# no daemon is reachable, and is opt-in via KEDULAB_RUN_SMOKE=1.
#
# Usage:
#   tests/run_all.sh                 # everything except the image build
#   KEDULAB_RUN_SMOKE=1 tests/run_all.sh   # also build and probe the image
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || exit 1

RUN_SMOKE="${KEDULAB_RUN_SMOKE:-0}"

pass=0 failed=0 skipped=0
failed_names=""

for t in tests/*_test.sh; do
    name="$(basename "$t")"
    if [ "$name" = "image_smoke_test.sh" ] && [ "$RUN_SMOKE" != "1" ]; then
        printf '  SKIP  %s (set KEDULAB_RUN_SMOKE=1 to build and probe the image)\n' "$name"
        skipped=$((skipped + 1))
        continue
    fi

    out="$(bash "$t" 2>&1)"
    status=$?
    if [ "$status" -eq 0 ]; then
        if printf '%s' "$out" | grep -q '^SKIP:'; then
            printf '  SKIP  %s — %s\n' "$name" "$(printf '%s' "$out" | sed -n 's/^SKIP: //p' | head -1)"
            skipped=$((skipped + 1))
        else
            printf '  PASS  %s\n' "$name"
            pass=$((pass + 1))
        fi
    else
        printf '  FAIL  %s\n' "$name"
        printf '%s\n' "$out" | sed 's/^/        /'
        failed=$((failed + 1))
        failed_names="$failed_names $name"
    fi
done

printf '\n%d passed, %d failed, %d skipped\n' "$pass" "$failed" "$skipped"
if [ "$failed" -ne 0 ]; then
    printf 'failing:%s\n' "$failed_names"
    exit 1
fi
