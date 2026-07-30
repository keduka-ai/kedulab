#!/usr/bin/env bash
# Regression test: install.sh must NOT hard-fail when no usable GPU is present.
# Instead it informs the user and defaults to CPU by pinning the CPU-only compose
# file in .env (COMPOSE_FILE=docker-compose.cpu.yml). When a GPU is detected it
# leaves .env on the GPU default (no COMPOSE_FILE override).
#
# The GPU probe (`docker run --gpus all ... nvidia-smi`) is mocked so the test
# runs on any host. git is real and clones from a local bare repo (no network).
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALL="$SCRIPT_DIR/install.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }

# A local source repo to clone from (no network).
git init -q --bare "$WORK/src.git"
git clone -q "$WORK/src.git" "$WORK/seed" 2>/dev/null
# The `cd` is guarded: without it a failure would leave the git commands below
# running against this very checkout (`git add -A` + commit), not the seed.
( cd "$WORK/seed" || exit 1
  echo "kedulab" > README.md
  git add -A
  git -c user.email=t@t -c user.name=t commit -q -m init
  git branch -M main
  git push -q origin main ) 2>/dev/null \
    || fail "could not seed the local source repo at $WORK/seed"

# Mock docker: version / compose version succeed; the `run` GPU probe exits with
# the status of $MOCK_GPU (0 = GPU present, non-zero = no GPU).
mkdir -p "$WORK/bin"
cat > "$WORK/bin/docker" <<'MOCK'
#!/usr/bin/env bash
case "${1:-} ${2:-}" in
  "version "*|"version") exit 0 ;;
  "compose version") exit 0 ;;
esac
if [ "${1:-}" = "run" ]; then
  exit "${MOCK_GPU:-1}"
fi
exit 0
MOCK
chmod +x "$WORK/bin/docker"
export PATH="$WORK/bin:$PATH"

run_install() {
    # $1 = MOCK_GPU value, $2 = target dir
    MOCK_GPU="$1" KEDULAB_MOUNT_PATH=./ws \
        bash "$INSTALL" --yes --ref main --dir "$2" \
        > "$2.out" 2>&1
    echo $?
}

# ---- Case 1: no GPU -> CPU fallback, must not hard-fail -------------------
status="$(KEDULAB_REPO_URL="$WORK/src.git" run_install 1 "$WORK/cpu")"
[ "$status" = "0" ] || fail "no-GPU install exited $status (expected 0; must not hard-fail). Output:
$(cat "$WORK/cpu.out")"
grep -q '^COMPOSE_FILE=docker-compose.cpu.yml$' "$WORK/cpu/.env" \
    || fail "no-GPU .env is missing COMPOSE_FILE=docker-compose.cpu.yml:
$(cat "$WORK/cpu/.env" 2>/dev/null)"
grep -qi 'cpu' "$WORK/cpu.out" \
    || fail "no-GPU run did not inform the user about CPU fallback"

# ---- Case 2: GPU present -> GPU default, no CPU override ------------------
status="$(KEDULAB_REPO_URL="$WORK/src.git" run_install 0 "$WORK/gpu")"
[ "$status" = "0" ] || fail "GPU install exited $status (expected 0). Output:
$(cat "$WORK/gpu.out")"
if grep -q 'docker-compose.cpu.yml' "$WORK/gpu/.env"; then
    fail "GPU .env should not pin the CPU compose file:
$(cat "$WORK/gpu/.env")"
fi

echo "PASS: install.sh GPU detection falls back to CPU and keeps GPU as default when present"
