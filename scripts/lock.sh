#!/usr/bin/env bash
# Compile a uv lockfile (with --generate-hashes) for a given requirements
# file. Run this on the host, commit the resulting .lock alongside its
# source .txt, and point REQUIREMENTS_FILE at the .lock for reproducible,
# hash-verified container builds.
#
# Usage:
#   scripts/lock.sh                       # locks requirements.txt
#   scripts/lock.sh requirements-kais.txt # locks requirements-kais.txt
#   scripts/lock.sh -a                    # locks every requirements*.txt
#                                         # plus jupyter-base.txt
#
# Output: <input>.lock in the repo root.
#
# Requires uv on PATH. Install with: pipx install uv  (or see
# https://docs.astral.sh/uv/getting-started/installation/).

set -euo pipefail

cd "$(dirname "$0")/.."

if ! command -v uv >/dev/null 2>&1; then
  echo "uv not found on PATH. Install: https://docs.astral.sh/uv/getting-started/installation/" >&2
  exit 1
fi

lock_one() {
  local src=$1
  local out=${src%.txt}.lock
  echo "Locking $src -> $out"
  uv pip compile "$src" -o "$out" --generate-hashes --quiet
}

if [[ ${1:-} == "-a" ]]; then
  shopt -s nullglob
  for f in requirements*.txt jupyter-base.txt; do
    lock_one "$f"
  done
else
  lock_one "${1:-requirements.txt}"
fi
