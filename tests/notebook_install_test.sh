#!/usr/bin/env bash
# Regression test: a user must be able to `!pip install <lib>` from inside a
# notebook, even though the image rootfs is read_only and /opt/venv therefore
# cannot be written to.
#
# Two things have to hold:
#   1. `pip` exists in the venv at all (uv venv does NOT seed it, so a stock
#      `!pip install x` fails with "pip: not found").
#   2. pip has a WRITABLE install location that is already on sys.path. The
#      entrypoint points PIP_PREFIX at a directory on the bind-mounted
#      workspace and prepends its site-packages to PYTHONPATH.
#
# Also asserts librosa is pinned in the dep files.
#
# No docker daemon needed: the entrypoint is exercised with stub python /
# jupyter-lab binaries, and `docker compose config` parses files client-side.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }

# A real `python` (the entrypoint asks sysconfig for the install paths, so a
# dumb echo stub won't do) plus a stub jupyter-lab that dumps the env the real
# server would inherit.
mkdir -p "$WORK/bin" "$WORK/badbin"
cat > "$WORK/bin/python" <<'STUB'
#!/usr/bin/env bash
exec python3 "$@"
STUB
cat > "$WORK/bin/jupyter-lab" <<'STUB'
#!/usr/bin/env bash
{
  echo "PIP_PREFIX=${PIP_PREFIX:-}"
  echo "PYTHONPATH=${PYTHONPATH:-}"
  echo "PATH=${PATH:-}"
  echo "ARGS=$*"
} > "$DUMP"
STUB
chmod +x "$WORK/bin/python" "$WORK/bin/jupyter-lab"
export PATH="$WORK/bin:$PATH"

# This file covers the pip overlay only. Disable the cache-dir redirection so
# its (correct) warning about an unwritable /home/workspace on the test host
# doesn't leak into the assertions below; tests/cache_dirs_test.sh owns it.
export KEDULAB_CACHE_DIR=""

# ---- Case 1: pip exists in the image -------------------------------------
grep -qE '^pip[><=]' "$ROOT/jupyter-base.txt" \
    || fail "jupyter-base.txt has no pip pin — '!pip install x' dies with 'pip: not found'.
$(cat "$ROOT/jupyter-base.txt")"

# ---- Case 2: entrypoint wires a writable install prefix -------------------
PREFIX="$WORK/ws/.kedulab-packages"
# Expected paths come from the same sysconfig query pip's --prefix uses.
SITE="$(python3 -c "import sys,sysconfig; p=sys.argv[1]; print(sysconfig.get_path('purelib','posix_prefix',vars={'base':p,'platbase':p}))" "$PREFIX")"
BINDIR="$(python3 -c "import sys,sysconfig; p=sys.argv[1]; print(sysconfig.get_path('scripts','posix_prefix',vars={'base':p,'platbase':p}))" "$PREFIX")"
mkdir -p "$WORK/ws"
DUMP="$WORK/dump.env" KEDULAB_USER_PREFIX="$PREFIX" \
    sh "$ROOT/scripts/entrypoint.sh" > "$WORK/ep.out" 2>&1 \
    || fail "entrypoint exited non-zero. Output:
$(cat "$WORK/ep.out")"

[ -f "$WORK/dump.env" ] || fail "entrypoint never reached jupyter-lab. Output:
$(cat "$WORK/ep.out")"

# Read values out of the dump rather than sourcing it — ARGS holds bare
# --flags that a shell would try to execute.
val() { sed -n "s/^$1=//p" "$WORK/dump.env"; }
PIP_PREFIX="$(val PIP_PREFIX)"
PYTHONPATH="$(val PYTHONPATH)"
PATH_SEEN="$(val PATH)"
ARGS="$(val ARGS)"

[ -d "$SITE" ] || fail "entrypoint did not create the writable site-packages dir at $SITE"
[ -d "$BINDIR" ] || fail "entrypoint did not create $BINDIR for console scripts"
[ "$PIP_PREFIX" = "$PREFIX" ] \
    || fail "PIP_PREFIX is '$PIP_PREFIX', expected '$PREFIX' — bare 'pip install x' won't target the writable dir"
case "$PYTHONPATH" in
    "$SITE"|"$SITE":*) ;;
    *) fail "PYTHONPATH is '$PYTHONPATH'; expected it to start with '$SITE' so freshly installed libs are importable" ;;
esac
case "$PATH_SEEN" in
    "$BINDIR":*) ;;
    *) fail "PATH does not start with '$BINDIR' — console scripts from user installs won't resolve" ;;
esac
case "$ARGS" in
    *--ip=0.0.0.0*) ;;
    *) fail "entrypoint stopped passing the server flags through: ARGS='$ARGS'" ;;
esac

# ---- Case 3: a pre-set PYTHONPATH is preserved, not clobbered -------------
DUMP="$WORK/dump2.env" KEDULAB_USER_PREFIX="$PREFIX" PYTHONPATH="/opt/extra" \
    sh "$ROOT/scripts/entrypoint.sh" >/dev/null 2>&1
grep -q "^PYTHONPATH=$SITE:/opt/extra$" "$WORK/dump2.env" \
    || fail "entrypoint clobbered a pre-existing PYTHONPATH: $(grep '^PYTHONPATH=' "$WORK/dump2.env")"

# ---- Case 4: an unwritable prefix must not kill the container -------------
mkdir -p "$WORK/ro"
chmod 500 "$WORK/ro"
DUMP="$WORK/dump3.env" KEDULAB_USER_PREFIX="$WORK/ro/nope" \
    sh "$ROOT/scripts/entrypoint.sh" > "$WORK/ep3.out" 2>&1
[ -f "$WORK/dump3.env" ] \
    || fail "entrypoint aborted instead of starting JupyterLab when the prefix dir could not be created. Output:
$(cat "$WORK/ep3.out")"
grep -qi 'could not prepare' "$WORK/ep3.out" \
    || fail "entrypoint silently swallowed an unwritable prefix; it must warn. Output:
$(cat "$WORK/ep3.out")"
grep -q '^PIP_PREFIX=$' "$WORK/dump3.env" \
    || fail "PIP_PREFIX was exported despite the prefix dir being uncreatable: $(grep '^PIP_PREFIX=' "$WORK/dump3.env")"
chmod 700 "$WORK/ro"

# ---- Case 4b: empty KEDULAB_USER_PREFIX disables the overlay --------------
DUMP="$WORK/dump4.env" KEDULAB_USER_PREFIX="" \
    sh "$ROOT/scripts/entrypoint.sh" > "$WORK/ep4.out" 2>&1
grep -q '^PIP_PREFIX=$' "$WORK/dump4.env" \
    || fail "an empty KEDULAB_USER_PREFIX must disable the overlay, but PIP_PREFIX was still set: $(grep '^PIP_PREFIX=' "$WORK/dump4.env")"
[ -s "$WORK/ep4.out" ] \
    && fail "disabling the overlay should be silent, not warn. Output:
$(cat "$WORK/ep4.out")"

# ---- Case 4c: a broken python query degrades, it does not crash -----------
cat > "$WORK/badbin/python" <<'STUB'
#!/usr/bin/env bash
exit 1
STUB
chmod +x "$WORK/badbin/python"
cp "$WORK/bin/jupyter-lab" "$WORK/badbin/jupyter-lab"
DUMP="$WORK/dump5.env" KEDULAB_USER_PREFIX="$PREFIX" PATH="$WORK/badbin:$PATH" \
    sh "$ROOT/scripts/entrypoint.sh" > "$WORK/ep5.out" 2>&1
[ -f "$WORK/dump5.env" ] \
    || fail "entrypoint died instead of degrading when the sysconfig query failed. Output:
$(cat "$WORK/ep5.out")"
grep -q '^PIP_PREFIX=$' "$WORK/dump5.env" \
    || fail "PIP_PREFIX was exported off a failed sysconfig query: $(grep '^PIP_PREFIX=' "$WORK/dump5.env")"

# ---- Case 5: librosa is pinned in the dep files ---------------------------
grep -qE '^librosa>=' "$ROOT/requirements.txt" \
    || fail "librosa is not pinned in requirements.txt"
grep -qE '"librosa>=' "$ROOT/pyproject.toml" \
    || fail "librosa is missing from pyproject.toml (requirements.txt and pyproject must stay in sync)"

# ---- Case 6: GPU/CPU compose lockstep still holds -------------------------
if docker compose version >/dev/null 2>&1; then
    gpu="$(cd "$ROOT" && docker compose config 2>/dev/null)"
    cpu="$(cd "$ROOT" && COMPOSE_FILE=docker-compose.cpu.yml docker compose config 2>/dev/null)"
    drift="$(diff <(echo "$gpu") <(echo "$cpu") | grep -E '^[<>]' | grep -viE 'devices|driver|nvidia|capabilities|count|reservations|^[<>][[:space:]]*-?[[:space:]]*gpu' )"
    [ -z "$drift" ] || fail "docker-compose.cpu.yml drifted from docker-compose.yml beyond the GPU reservation:
$drift"
else
    echo "SKIP: docker compose unavailable — lockstep check not run"
fi

echo "PASS: pip is installed, the entrypoint wires a writable install prefix, and librosa is pinned"
