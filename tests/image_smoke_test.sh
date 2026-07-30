#!/usr/bin/env bash
# End-to-end smoke test of the built image. This is the only test that needs a
# Docker daemon; it SKIPs cleanly without one so the rest of the suite stays
# runnable in a sandbox.
#
# What it protects: CLAUDE.md flags TensorFlow + PyTorch + JAX co-installation
# as a fragile CUDA combination, and the entrypoint now wires several cache and
# install paths that only exist at runtime. Nothing else in tests/ ever builds
# or runs the actual image, so a broken pin set or a broken entrypoint would
# only surface on a user's first notebook.
#
# Usage:
#   tests/image_smoke_test.sh                 # build + probe the jupyter target
#   KEDULAB_SMOKE_BUILD=0 tests/image_smoke_test.sh   # probe an existing image
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || exit 1

fail() { echo "FAIL: $*" >&2; exit 1; }

if ! docker version >/dev/null 2>&1; then
    echo "SKIP: no Docker daemon reachable — image smoke test not run"
    exit 0
fi

IMAGE="${KEDULAB_SMOKE_IMAGE:-kedulab-smoke:test}"
BUILD="${KEDULAB_SMOKE_BUILD:-1}"

if [ "$BUILD" = "1" ]; then
    echo "building $IMAGE (target=jupyter) — this pulls ~5 GB on a cold cache"
    docker build --target jupyter -t "$IMAGE" \
        --build-arg REQUIREMENTS_FILE="${REQUIREMENTS_FILE:-requirements.txt}" \
        . >/dev/null || fail "image build failed"
fi

# ---- Case 1: the three frameworks import together -------------------------
# The co-install of TF + torch + JAX shares CUDA libs across three wheel sets;
# a mismatched pin surfaces here as an import-time CUDA init error.
out="$(docker run --rm --entrypoint python "$IMAGE" -c '
import tensorflow as tf, torch, jax, transformers, nltk, librosa
print("tf", tf.__version__)
print("torch", torch.__version__)
print("jax", jax.__version__)
print("transformers", transformers.__version__)
' 2>&1)" || fail "framework imports failed:
$out"

for pkg in tf torch jax transformers; do
    echo "$out" | grep -q "^$pkg " || fail "$pkg did not import cleanly:
$out"
done

# ---- Case 2: the ipykernel spec survives the read-only rootfs -------------
out="$(docker run --rm --entrypoint jupyter "$IMAGE" kernelspec list 2>&1)" \
    || fail "jupyter kernelspec list failed:
$out"
echo "$out" | grep -q 'ml' \
    || fail "the 'ml' kernel spec is missing — --sys-prefix registration regressed:
$out"

# ---- Case 3: caches and the pip overlay land on the writable mount --------
# Run with the same read-only rootfs + tmpfs layout compose uses, so a
# regression in the entrypoint's degradation path shows up here.
ws="$(mktemp -d)"
trap 'rm -rf "$ws"' EXIT
chmod 777 "$ws"

# Shadow jupyter-lab with a stub that dumps the environment the real server
# would have inherited, then let the real entrypoint run to completion.
readonly_run() { # $1 = shell snippet to run instead of jupyter-lab
    docker run --rm \
        --read-only \
        --tmpfs /tmp --tmpfs /home/jovyan/.cache --tmpfs /home/jovyan/.local \
        --tmpfs /home/jovyan/.jupyter --tmpfs /home/jovyan/.ipython \
        -v "$ws:/home/workspace" \
        --entrypoint sh "$IMAGE" -c "
          mkdir -p /tmp/stub
          printf '%s\n' '#!/bin/sh' '$1' > /tmp/stub/jupyter-lab
          chmod +x /tmp/stub/jupyter-lab
          PATH=/tmp/stub:\$PATH /usr/local/bin/entrypoint.sh
        " 2>&1
}

out="$(readonly_run 'env')" \
    || fail "entrypoint failed under a read-only rootfs:
$out"

for var in HF_HOME NLTK_DATA KERAS_HOME TFDS_DATA_DIR TORCH_HOME MPLCONFIGDIR PIP_PREFIX; do
    echo "$out" | grep -qE "^$var=/home/workspace/" \
        || fail "$var does not point at the writable workspace mount:
$(echo "$out" | grep -E '^(HF_HOME|NLTK_DATA|KERAS_HOME|TFDS_DATA_DIR|TORCH_HOME|MPLCONFIGDIR|PIP_PREFIX)=' || echo '(none set)')"
done

# ---- Case 4: those redirected dirs are genuinely writable ----------------
# Proves the read-only rootfs is not in the way — this is the exact operation
# nltk.download() / keras.datasets / tfds.load() perform on first use.
out="$(readonly_run 'python -c "
import os, pathlib
for v in (\"NLTK_DATA\", \"KERAS_HOME\", \"TFDS_DATA_DIR\", \"HF_HOME\"):
    d = pathlib.Path(os.environ[v])
    (d / \".probe\").write_text(\"ok\")
    print(\"writable\", v, d)
"')" || fail "a redirected cache dir was not writable under the read-only rootfs:
$out"

for var in NLTK_DATA KERAS_HOME TFDS_DATA_DIR HF_HOME; do
    echo "$out" | grep -q "writable $var" \
        || fail "$var was not writable — this is what makes nltk.download() / tfds.load() fail:
$out"
done

echo "PASS: image builds, TF/torch/JAX import together, kernel spec present, caches writable"
