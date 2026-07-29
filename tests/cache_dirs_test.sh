#!/usr/bin/env bash
# Regression test: ML framework caches and datasets must land on the writable
# bind mount, not on the read-only rootfs and not in RAM-backed tmpfs.
#
# The container runs with `read_only: true`. Only /tmp and a few dirs under
# /home/jovyan are tmpfs; everything else under $HOME is read-only. That splits
# the pinned dependency set into two failure modes:
#
#   Hard failure (writes to a read-only $HOME path):
#     nltk.download(...)            -> ~/nltk_data
#     keras.datasets.*.load_data()  -> ~/.keras
#     tfds.load(...)                -> ~/tensorflow_datasets
#
#   Silent RAM burn (writes into the tmpfs at ~/.cache, which is RAM and counts
#   against MEMORY_LIMIT, and is lost on every restart):
#     transformers / datasets       -> ~/.cache/huggingface
#     torch.hub                     -> ~/.cache/torch
#     matplotlib font cache         -> ~/.cache/matplotlib
#
# The entrypoint therefore points all of them at KEDULAB_CACHE_DIR on the
# bind-mounted workspace, using the same never-fatal pattern as PIP_PREFIX.
#
# No docker daemon needed: the entrypoint is exercised with stub python /
# jupyter-lab binaries.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }

# Real `python` (the entrypoint asks sysconfig for the pip prefix paths) plus a
# stub jupyter-lab that dumps the environment the real server would inherit.
mkdir -p "$WORK/bin"
cat > "$WORK/bin/python" <<'STUB'
#!/usr/bin/env bash
exec python3 "$@"
STUB
cat > "$WORK/bin/jupyter-lab" <<'STUB'
#!/usr/bin/env bash
env > "$DUMP"
STUB
chmod +x "$WORK/bin/python" "$WORK/bin/jupyter-lab"
export PATH="$WORK/bin:$PATH"

# getval <dump-file> <VAR> -> the value the stub server saw for VAR
getval() { sed -n "s/^$2=//p" "$1"; }

# Every cache var the entrypoint must set, and the subdirectory each one gets.
# Keep in sync with scripts/entrypoint.sh.
CACHE_VARS="HF_HOME:huggingface
TORCH_HOME:torch
NLTK_DATA:nltk_data
KERAS_HOME:keras
TFDS_DATA_DIR:tensorflow_datasets
MPLCONFIGDIR:matplotlib
XDG_CACHE_HOME:xdg"

# ---- Case 1: every cache var is exported and its directory created ---------
CACHE="$WORK/ws/.kedulab-cache"
mkdir -p "$WORK/ws"
DUMP="$WORK/dump1.env" KEDULAB_CACHE_DIR="$CACHE" KEDULAB_USER_PREFIX="" \
    sh "$ROOT/scripts/entrypoint.sh" > "$WORK/ep1.out" 2>&1 \
    || fail "entrypoint exited non-zero. Output:
$(cat "$WORK/ep1.out")"

[ -f "$WORK/dump1.env" ] \
    || fail "entrypoint never reached jupyter-lab. Output:
$(cat "$WORK/ep1.out")"

while IFS=: read -r var sub; do
    [ -n "$var" ] || continue
    seen="$(getval "$WORK/dump1.env" "$var")"
    want="$CACHE/$sub"
    [ "$seen" = "$want" ] \
        || fail "$var is '$seen', expected '$want' — otherwise this cache lands on the read-only rootfs or in tmpfs"
    [ -d "$want" ] \
        || fail "entrypoint did not create $want; the library will fail on first write"
done <<EOF
$CACHE_VARS
EOF

# ---- Case 2: an explicit user override is respected, not clobbered ---------
DUMP="$WORK/dump2.env" KEDULAB_CACHE_DIR="$CACHE" KEDULAB_USER_PREFIX="" \
    HF_HOME=/home/workspace/my-own-hf \
    sh "$ROOT/scripts/entrypoint.sh" >/dev/null 2>&1
seen="$(getval "$WORK/dump2.env" HF_HOME)"
[ "$seen" = "/home/workspace/my-own-hf" ] \
    || fail "entrypoint overwrote an explicitly-set HF_HOME (got '$seen'); user intent must win"
# ...while the vars the user did NOT set are still wired up.
seen="$(getval "$WORK/dump2.env" NLTK_DATA)"
[ "$seen" = "$CACHE/nltk_data" ] \
    || fail "overriding one cache var disabled the others: NLTK_DATA='$seen'"

# ---- Case 3: empty KEDULAB_CACHE_DIR disables the redirection entirely -----
DUMP="$WORK/dump3.env" KEDULAB_CACHE_DIR="" KEDULAB_USER_PREFIX="" \
    sh "$ROOT/scripts/entrypoint.sh" > "$WORK/ep3.out" 2>&1
while IFS=: read -r var sub; do
    [ -n "$var" ] || continue
    if grep -q "^$var=" "$WORK/dump3.env"; then
        fail "an empty KEDULAB_CACHE_DIR must disable the redirection, but $var was still exported: $(getval "$WORK/dump3.env" "$var")"
    fi
done <<EOF
$CACHE_VARS
EOF
[ -s "$WORK/ep3.out" ] \
    && fail "disabling the cache redirection should be silent, not warn. Output:
$(cat "$WORK/ep3.out")"

# ---- Case 4: an unwritable cache dir warns but never kills the container ---
mkdir -p "$WORK/ro"
chmod 500 "$WORK/ro"
DUMP="$WORK/dump4.env" KEDULAB_CACHE_DIR="$WORK/ro/nope" KEDULAB_USER_PREFIX="" \
    sh "$ROOT/scripts/entrypoint.sh" > "$WORK/ep4.out" 2>&1
[ -f "$WORK/dump4.env" ] \
    || fail "entrypoint aborted instead of starting JupyterLab when the cache dir could not be created. Output:
$(cat "$WORK/ep4.out")"
grep -qi 'could not prepare' "$WORK/ep4.out" \
    || fail "entrypoint silently swallowed an unwritable cache dir; it must warn. Output:
$(cat "$WORK/ep4.out")"
chmod 700 "$WORK/ro"

# ---- Case 5: the pip overlay and the cache dir are independent -------------
# Both default on; enabling one must not require the other.
PREFIX="$WORK/ws/.kedulab-packages"
DUMP="$WORK/dump5.env" KEDULAB_CACHE_DIR="$CACHE" KEDULAB_USER_PREFIX="$PREFIX" \
    sh "$ROOT/scripts/entrypoint.sh" >/dev/null 2>&1
[ "$(getval "$WORK/dump5.env" PIP_PREFIX)" = "$PREFIX" ] \
    || fail "wiring the cache dir broke the pip overlay"
[ "$(getval "$WORK/dump5.env" HF_HOME)" = "$CACHE/huggingface" ] \
    || fail "wiring the pip overlay broke the cache dir"

echo "PASS: entrypoint redirects every ML cache onto the writable workspace, respects overrides, and degrades safely"
