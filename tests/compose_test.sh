#!/usr/bin/env bash
# Compose-level regression tests. All of these are client-side (`docker compose
# config` parses and interpolates without contacting a daemon), so they run in
# CI without Docker privileges.
#
# Covers:
#   - GPU/CPU lockstep (the CPU file may differ ONLY by the GPU reservation)
#   - init: true            — jupyter-lab must not be PID 1 with no reaper
#   - GPU_COUNT             — lets parallel stacks share a multi-GPU host
#   - tmpfs size caps       — tmpfs is RAM and counts against MEMORY_LIMIT
#   - cache/prefix env vars — must use ${VAR-default} so an empty value survives
#   - BASE_IMAGE build arg  — lets the base image be pinned by digest
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || exit 1

fail() { echo "FAIL: $*" >&2; exit 1; }

if ! docker compose version >/dev/null 2>&1; then
    echo "SKIP: docker compose CLI unavailable — compose tests not run"
    exit 0
fi

cfg() { docker compose config 2>/dev/null; }
cfg_cpu() { COMPOSE_FILE=docker-compose.cpu.yml docker compose config 2>/dev/null; }

GPU="$(cfg)"
CPU="$(cfg_cpu)"
[ -n "$GPU" ] || fail "docker-compose.yml failed to parse:
$(docker compose config 2>&1 | head -20)"
[ -n "$CPU" ] || fail "docker-compose.cpu.yml failed to parse:
$(COMPOSE_FILE=docker-compose.cpu.yml docker compose config 2>&1 | head -20)"

# ---- Case 1: lockstep — only the GPU reservation may differ ---------------
drift="$(diff <(echo "$GPU") <(echo "$CPU") | grep -E '^[<>]' \
    | grep -viE 'devices|driver|nvidia|capabilities|count|reservations|^[<>][[:space:]]*-?[[:space:]]*gpu')"
[ -z "$drift" ] || fail "docker-compose.cpu.yml drifted beyond the GPU reservation:
$drift"

# ---- Case 2: init: true in both files -------------------------------------
# Without an init process, jupyter-lab is PID 1 and never reaps the zombies
# left behind by killed kernels and notebook subprocesses.
for f in docker-compose.yml docker-compose.cpu.yml; do
    COMPOSE_FILE="$f" docker compose config 2>/dev/null | grep -qE '^\s*init:\s*true' \
        || fail "$f does not set 'init: true' — jupyter-lab runs as PID 1 and leaks zombie processes"
done

# ---- Case 3: GPU_COUNT is honoured by the device reservation --------------
# Default must stay "all" so existing single-stack users see no change.
# Compose canonicalises `count: all` to `count: -1` in its rendered config.
default_count="$(echo "$GPU" | grep -E '^\s*count:' | head -1)"
echo "$default_count" | grep -qE 'count:\s*"?(all|-1)"?\s*$' \
    || fail "default GPU reservation is no longer 'all' (rendered as -1); got '$default_count'"
one="$(GPU_COUNT=1 docker compose config 2>/dev/null | grep -E '^\s*count:' | head -1)"
echo "$one" | grep -qE 'count:\s*"?1"?\s*$' \
    || fail "GPU_COUNT=1 did not reach the device reservation (got '$one') — parallel stacks on a multi-GPU host cannot be separated"

# ---- Case 4: every tmpfs mount carries a size cap -------------------------
# An uncapped tmpfs defaults to half of host RAM, and those pages count against
# the container memory limit — a large model download becomes an OOM kill.
# Compose renders the short syntax back as "<path>:<options>" strings.
for f in docker-compose.yml docker-compose.cpu.yml; do
    entries="$(COMPOSE_FILE="$f" docker compose config 2>/dev/null \
        | sed -n '/^    tmpfs:/,/^    [a-z]/p' | sed -n 's/^ *- //p')"
    [ -n "$entries" ] || fail "$f declares no tmpfs mounts at all"
    while IFS= read -r entry; do
        [ -n "$entry" ] || continue
        case "$entry" in
            *:*size=*) ;;
            *) fail "$f has an uncapped tmpfs mount '$entry' — it can grow to half of host RAM and count against MEMORY_LIMIT" ;;
        esac
    done <<EOF
$entries
EOF
done

# ---- Case 5: cache + prefix vars use ${VAR-default}, not ${VAR:-default} ---
# The documented way to disable either overlay is to set it to the empty
# string; ${VAR:-default} would silently fall back to the default instead.
for var in KEDULAB_USER_PREFIX KEDULAB_CACHE_DIR; do
    for f in docker-compose.yml docker-compose.cpu.yml; do
        grep -qE "\\\$\\{$var-" "$f" \
            || fail "$f must interpolate $var with \${$var-default} (no colon) so an explicitly empty value disables it"
    done
    empty="$(env "$var=" docker compose config 2>/dev/null | grep -E "^\s*$var:" | head -1)"
    echo "$empty" | grep -qE "$var:\s*\"?\"?\s*$" \
        || fail "setting $var to the empty string did not survive interpolation (got '$empty')"
done

# ---- Case 6: BASE_IMAGE is a build arg so it can be digest-pinned ---------
for f in docker-compose.yml docker-compose.cpu.yml; do
    grep -qE '^\s*BASE_IMAGE:' "$f" \
        || fail "$f does not pass a BASE_IMAGE build arg — the base image cannot be pinned by digest from .env"
done

echo "PASS: compose lockstep, init, GPU_COUNT, tmpfs caps, cache vars and BASE_IMAGE all hold"
