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

# Resolve for the CONTAINER's interpreter and platform, not the host's. Without
# these, running lock.sh on (say) macOS or a host Python 3.10 produces a lock
# that pins macOS wheels or 3.10-only versions and then fails — or silently
# differs — inside the linux/amd64, Python 3.12 image. Defaults mirror the
# Dockerfile's PYTHON_VERSION and the CUDA base image's platform.
# The platform target is manylinux_2_35, not the generic
# `x86_64-unknown-linux-gnu`. The generic alias implies manylinux_2_17
# compatibility, which is stricter than the actual base image: Ubuntu 22.04
# ships glibc 2.35. Packages that only publish manylinux_2_27 / 2_28 wheels —
# faiss-cpu in requirements-kais.txt is one — are then reported as
# "no compatible wheel" and the lock fails, even though they install fine in
# the container. Verified 2026-07-29.
PYTHON_VERSION="${PYTHON_VERSION:-3.12}"
LOCK_PLATFORM="${KEDULAB_LOCK_PLATFORM:-x86_64-manylinux_2_35}"

lock_one() {
  local src=$1
  local out=${src%.txt}.lock
  echo "Locking $src -> $out  (python ${PYTHON_VERSION}, ${LOCK_PLATFORM})"
  uv pip compile "$src" -o "$out" \
    --generate-hashes \
    --python-version "$PYTHON_VERSION" \
    --python-platform "$LOCK_PLATFORM" \
    --quiet
}

if [[ ${1:-} == "-a" ]]; then
  shopt -s nullglob
  for f in requirements*.txt jupyter-base.txt; do
    lock_one "$f"
  done
else
  lock_one "${1:-requirements.txt}"
fi
