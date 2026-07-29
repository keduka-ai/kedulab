#!/usr/bin/env bash
# Resolve the base image tag to an immutable digest.
#
# Why: every Python dependency in this repo is pinned, but the container's base
# image is referenced by tag (nvidia/cuda:12.4.1-cudnn-runtime-ubuntu22.04).
# Tags are mutable — the same name can be re-pushed with different contents, so
# two builds a month apart can start from different bytes. Pinning the digest
# closes that hole.
#
# Usage:
#   scripts/pin-base.sh                  # print the BASE_IMAGE line to paste
#   scripts/pin-base.sh --write          # write/replace it in ./.env
#   scripts/pin-base.sh --write .env.nlp # ...in a specific env file
#   scripts/pin-base.sh nvidia/cuda:12.6.0-cudnn-runtime-ubuntu24.04
#
# To go back to floating on the tag, delete the BASE_IMAGE line from the env
# file; the Dockerfile default takes over again.
#
# Requires a working Docker daemon with network access to the registry.
set -euo pipefail

cd "$(dirname "$0")/.."

WRITE=0
ENV_FILE=".env"
IMAGE=""

while [ $# -gt 0 ]; do
    case "$1" in
        --write)
            WRITE=1
            # An optional filename may follow --write.
            case "${2:-}" in
                ""|--*) shift ;;
                *) ENV_FILE="$2"; shift 2 ;;
            esac
            ;;
        -h|--help)
            sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        -*)
            echo "unknown flag: $1" >&2
            exit 2
            ;;
        *)
            IMAGE="$1"; shift
            ;;
    esac
done

# Default to whatever the Dockerfile currently declares, so this script never
# drifts from the build.
if [ -z "$IMAGE" ]; then
    IMAGE="$(sed -n 's/^ARG BASE_IMAGE=//p' Dockerfile | head -1)"
    [ -n "$IMAGE" ] || {
        echo "could not read 'ARG BASE_IMAGE=' from Dockerfile" >&2
        exit 1
    }
fi

case "$IMAGE" in
    *@sha256:*)
        echo "$IMAGE is already digest-pinned — nothing to resolve." >&2
        exit 0
        ;;
esac

command -v docker >/dev/null 2>&1 || {
    echo "docker not found — this script resolves the digest from the registry." >&2
    exit 1
}
docker version >/dev/null 2>&1 || {
    echo "docker daemon unreachable — start it (or fix permissions) and retry." >&2
    exit 1
}

# Strip the tag to get the repository. The tag is whatever follows the last ':'
# that comes after the last '/', so registry:port/repo forms survive.
repo="${IMAGE%:*}"
case "${IMAGE##*/}" in
    *:*) ;;            # had a tag; ${IMAGE%:*} already removed it
    *) repo="$IMAGE" ;; # untagged (implicitly :latest)
esac

digest=""
if docker buildx version >/dev/null 2>&1; then
    digest="$(docker buildx imagetools inspect "$IMAGE" \
        --format '{{.Manifest.Digest}}' 2>/dev/null || true)"
fi
if [ -z "$digest" ]; then
    # Fallback for hosts without buildx.
    digest="$(docker manifest inspect --verbose "$IMAGE" 2>/dev/null \
        | sed -n 's/.*"digest": *"\(sha256:[0-9a-f]*\)".*/\1/p' | head -1 || true)"
fi

[ -n "$digest" ] || {
    echo "could not resolve a digest for $IMAGE." >&2
    echo "check the image name and that the daemon can reach the registry." >&2
    exit 1
}

PINNED="${repo}@${digest}"
LINE="BASE_IMAGE=${PINNED}"

if [ "$WRITE" -eq 0 ]; then
    echo "# resolved $IMAGE"
    echo "$LINE"
    echo "# add the line above to your env file, or re-run with --write" >&2
    exit 0
fi

touch "$ENV_FILE"
if grep -q '^BASE_IMAGE=' "$ENV_FILE"; then
    tmp="$(mktemp)"
    grep -v '^BASE_IMAGE=' "$ENV_FILE" > "$tmp"
    printf '%s\n' "$LINE" >> "$tmp"
    cat "$tmp" > "$ENV_FILE"
    rm -f "$tmp"
    echo "updated BASE_IMAGE in $ENV_FILE -> $PINNED"
else
    printf '%s\n' "$LINE" >> "$ENV_FILE"
    echo "appended BASE_IMAGE to $ENV_FILE -> $PINNED"
fi
echo "rebuild to pick it up: docker compose up -d --build"
