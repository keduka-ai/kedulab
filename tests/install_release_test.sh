#!/usr/bin/env bash
# Regression test: after a streamed `curl | bash` interactive install finishes
# (the next-steps command is echoed), the installer must release the terminal and
# return to the shell — it must NOT block reading another command from /dev/tty.
#
# The actual pty mechanics live in pty_release.py, which waits on the installer
# PROCESS directly (a `script`-based harness would instead measure its own linger
# on the held-open input stream). See that file for the reproduction details.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALL="$SCRIPT_DIR/install.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

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
    || { echo "FAIL: could not seed the local source repo at $WORK/seed" >&2; exit 1; }

python3 "$SCRIPT_DIR/tests/pty_release.py" "$INSTALL" "$WORK/src.git" "$WORK/target"
