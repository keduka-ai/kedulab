#!/usr/bin/env bash
# Regression test: install.sh must write USER_UID / USER_GID into the .env it
# generates, and must warn when the requested ref is a mutable branch.
#
# Why UID/GID matters: the container runs as jovyan, built with USER_UID/GID
# defaulting to 1000:1000. On any host where `id -u` is not 1000, the
# bind-mounted workspace is not writable by the container user — notebook saves
# fail and the entrypoint's pip/cache overlays cannot be created. The installer
# already runs as the host user, so it can simply record the right values.
#
# The GPU probe and docker are mocked; git clones from a local bare repo.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALL="$ROOT/install.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }

# Local source repo (no network).
git init -q --bare "$WORK/src.git"
git clone -q "$WORK/src.git" "$WORK/seed" 2>/dev/null
# The `cd` is guarded: without it a failure would leave the git commands below
# running against this very checkout (`git add -A` + commit), not the seed.
( cd "$WORK/seed" || exit 1
  echo "kedulab" > README.md
  git add -A
  git -c user.email=t@t -c user.name=t commit -q -m init
  git branch -M main
  git tag v0.0.0-test
  git push -q origin main
  git push -q origin v0.0.0-test ) 2>/dev/null \
    || fail "could not seed the local source repo at $WORK/seed"

mkdir -p "$WORK/bin"
cat > "$WORK/bin/docker" <<'MOCK'
#!/usr/bin/env bash
case "${1:-} ${2:-}" in
  "version "*|"version") exit 0 ;;
  "compose version") exit 0 ;;
esac
[ "${1:-}" = "run" ] && exit "${MOCK_GPU:-0}"
exit 0
MOCK
chmod +x "$WORK/bin/docker"
export PATH="$WORK/bin:$PATH"

run_install() { # $1 = target dir, $2... = extra flags
    local dir="$1"; shift
    MOCK_GPU=0 KEDULAB_REPO_URL="$WORK/src.git" KEDULAB_MOUNT_PATH=./ws \
        bash "$INSTALL" --yes --dir "$dir" "$@" > "$dir.out" 2>&1
    echo $?
}

# ---- Case 1: USER_UID / USER_GID are written and match the host ----------
status="$(run_install "$WORK/a" --ref main)"
[ "$status" = "0" ] || fail "install exited $status. Output:
$(cat "$WORK/a.out")"

want_uid="$(id -u)"
want_gid="$(id -g)"
# Running the installer as root must NOT bake USER_UID=0 into the image — that
# would undo the non-root container posture. It falls back to 1000 instead.
if [ "$want_uid" = "0" ]; then
    want_uid=1000
    want_gid=1000
fi
grep -q "^USER_UID=${want_uid}$" "$WORK/a/.env" \
    || fail "generated .env has no USER_UID=${want_uid}; a host UID != 1000 leaves the workspace mount unwritable by the container user:
$(cat "$WORK/a/.env")"
grep -q "^USER_GID=${want_gid}$" "$WORK/a/.env" \
    || fail "generated .env has no USER_GID=${want_gid}:
$(cat "$WORK/a/.env")"

# ---- Case 2: explicit overrides win --------------------------------------
status="$(KEDULAB_USER_UID=4242 KEDULAB_USER_GID=4243 run_install "$WORK/b" --ref main)"
[ "$status" = "0" ] || fail "override install exited $status. Output:
$(cat "$WORK/b.out")"
grep -q '^USER_UID=4242$' "$WORK/b/.env" \
    || fail "KEDULAB_USER_UID override was ignored:
$(cat "$WORK/b/.env")"
grep -q '^USER_GID=4243$' "$WORK/b/.env" \
    || fail "KEDULAB_USER_GID override was ignored:
$(cat "$WORK/b/.env")"

# ---- Case 3: a mutable branch ref warns about supply-chain exposure ------
# `curl | bash` against a moving branch executes whatever HEAD happens to be.
grep -qiE 'mutable|not pinned|moving target|--ref' "$WORK/a.out" \
    || fail "installing from the 'main' branch produced no warning that the ref is mutable. Output:
$(cat "$WORK/a.out")"

# ---- Case 4: a tag ref does NOT warn -------------------------------------
status="$(run_install "$WORK/c" --ref v0.0.0-test)"
[ "$status" = "0" ] || fail "tag install exited $status. Output:
$(cat "$WORK/c.out")"
if grep -qi 'mutable ref' "$WORK/c.out"; then
    fail "installing from an immutable tag should not warn about mutability. Output:
$(cat "$WORK/c.out")"
fi

echo "PASS: install.sh records host USER_UID/USER_GID, honours overrides, and warns only on mutable refs"
