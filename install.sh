#!/usr/bin/env bash
#
# Kedulab installer — bootstrap a GPU JupyterLab stack on this host.
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/keduka-ai/kedulab/main/install.sh | bash
#   curl -fsSL https://raw.githubusercontent.com/keduka-ai/kedulab/main/install.sh | bash -s -- --help
#
# Flags:
#   --ref <git-ref>        Branch or tag to clone (default: main)
#   --dir <path>           Where to clone (default: ./kedulab)
#   --no-prereq-check      Skip Docker / Compose / NVIDIA Toolkit checks
#   --yes                  Accept defaults non-interactively
#   --help, -h             Show this help
#
# GPU vs CPU: by default the installer probes for an NVIDIA GPU. If none is
# usable it informs you and defaults to CPU (pins COMPOSE_FILE=docker-compose.cpu.yml
# in .env). Force the mode with KEDULAB_GPU=on|off (default: auto).
#
# Non-interactive env-var overrides (skip the matching prompt):
#   KEDULAB_REPO_URL, KEDULAB_PROJECT, KEDULAB_REQUIREMENTS_FILE, KEDULAB_MOUNT_PATH,
#   KEDULAB_HOST_PORT, KEDULAB_GPU

set -euo pipefail

if [ -z "${BASH_VERSION:-}" ]; then
    echo "[kedulab] error: this installer requires bash. Re-run with: bash install.sh" >&2
    exit 1
fi

REPO_URL="${KEDULAB_REPO_URL:-https://github.com/keduka-ai/kedulab.git}"
REPO_URL_RAW="https://raw.githubusercontent.com/keduka-ai/kedulab/main"
NVIDIA_DOCS_URL="https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/install-guide.html"
GPU_PROBE_IMAGE="nvidia/cuda:12.4.1-base-ubuntu22.04"

REF="main"
DIR="./kedulab"
PREREQ_CHECK=1
ASSUME_YES=0

if [ -t 1 ]; then
    C_RED=$'\033[31m'; C_YELLOW=$'\033[33m'; C_GREEN=$'\033[32m'; C_BLUE=$'\033[34m'; C_RESET=$'\033[0m'
else
    C_RED=""; C_YELLOW=""; C_GREEN=""; C_BLUE=""; C_RESET=""
fi

info() { printf '%s[kedulab]%s %s\n' "$C_BLUE" "$C_RESET" "$*"; }
ok()   { printf '%s[kedulab]%s %s\n' "$C_GREEN" "$C_RESET" "$*"; }
warn() { printf '%s[kedulab]%s %s\n' "$C_YELLOW" "$C_RESET" "$*" >&2; }
err()  { printf '%s[kedulab]%s %s\n' "$C_RED" "$C_RESET" "$*" >&2; }

on_error() {
    err "installation failed at line $1"
    err "re-run with --help for usage, or open an issue at $REPO_URL/issues"
}
trap 'on_error $LINENO' ERR

usage() {
    cat <<'EOF'
Kedulab installer — bootstrap a GPU JupyterLab stack on this host.

Usage:
  curl -fsSL https://raw.githubusercontent.com/keduka-ai/kedulab/main/install.sh | bash
  curl -fsSL https://raw.githubusercontent.com/keduka-ai/kedulab/main/install.sh | bash -s -- --help

Flags:
  --ref <git-ref>        Branch or tag to clone (default: main)
  --dir <path>           Where to clone (default: ./kedulab)
  --no-prereq-check      Skip Docker / Compose / NVIDIA Toolkit checks
  --yes, -y              Accept defaults non-interactively
  --help, -h             Show this help

Non-interactive env-var overrides:
  KEDULAB_REPO_URL
      Git repository to clone.
      Default: https://github.com/keduka-ai/kedulab.git

  KEDULAB_PROJECT
      Compose project name written to .env.

  KEDULAB_REQUIREMENTS_FILE
      Requirements file baked into the image.
      Default: requirements.txt

  KEDULAB_MOUNT_PATH
      Host path mounted at /home/workspace.
      Default: ./workspace

  KEDULAB_HOST_PORT
      Host port mapped to JupyterLab.
      Default: 8888

  KEDULAB_GPU
      GPU mode: auto (probe), on (force GPU), off (force CPU).
      When no GPU is found, the installer defaults to CPU and pins
      COMPOSE_FILE=docker-compose.cpu.yml in .env.
      Default: auto

  KEDULAB_USER_UID / KEDULAB_USER_GID
      UID/GID the container's non-root user is built with, written to .env.
      Defaults to this host's `id -u` / `id -g` so files created in the
      mounted workspace stay owned by you and the mount is writable from
      inside the container. Falls back to 1000 when run as root.

Verifying this installer:
  Piping a script from a branch runs whatever is on that branch right now.
  For a reviewable install, download it, check the hash, then run it:

    curl -fsSLO https://raw.githubusercontent.com/keduka-ai/kedulab/main/install.sh
    sha256sum install.sh        # compare against the value in the release notes
    less install.sh             # read it
    bash install.sh --ref <tag>

  Passing --ref <tag> pins an immutable release; --ref main (the default)
  tracks a moving branch and will warn.

Examples:
  # Default: clone main into ./kedulab, prompt for stack config
  curl -fsSL https://raw.githubusercontent.com/keduka-ai/kedulab/main/install.sh | bash

  # Show help from the streamed installer
  curl -fsSL https://raw.githubusercontent.com/keduka-ai/kedulab/main/install.sh | bash -s -- --help

  # Pin to a tag, custom directory
  curl -fsSL https://raw.githubusercontent.com/keduka-ai/kedulab/main/install.sh \
    | bash -s -- --ref v1.0.0 --dir ~/projects/kedulab

  # CI / scripted use — accept all defaults, skip prereq checks
  KEDULAB_PROJECT=nlp KEDULAB_HOST_PORT=5679 \
    curl -fsSL https://raw.githubusercontent.com/keduka-ai/kedulab/main/install.sh \
      | bash -s -- --yes --no-prereq-check

  # Use a fork or alternate remote
  KEDULAB_REPO_URL=https://github.com/your-org/kedulab.git \
    curl -fsSL https://raw.githubusercontent.com/keduka-ai/kedulab/main/install.sh \
      | bash -s -- --yes
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        --ref)              REF="${2:?--ref needs a value}"; shift 2 ;;
        --dir)              DIR="${2:?--dir needs a value}"; shift 2 ;;
        --no-prereq-check)  PREREQ_CHECK=0; shift ;;
        --yes|-y)           ASSUME_YES=1; shift ;;
        --help|-h)          usage; exit 0 ;;
        *)                  err "unknown flag: $1"; usage; exit 2 ;;
    esac
done

check_prereqs() {
    info "checking prerequisites..."

    if ! command -v git >/dev/null 2>&1; then
        err "git not found. Install git and re-run."
        exit 1
    fi

    if ! command -v docker >/dev/null 2>&1; then
        err "docker not found. Install Docker Engine 24+ and re-run."
        err "see: https://docs.docker.com/engine/install/"
        exit 1
    fi

    if ! docker version >/dev/null 2>&1 </dev/null; then
        err "docker is installed but 'docker version' failed."
        err "is the daemon running? are you in the 'docker' group? (try: sudo usermod -aG docker \$USER && newgrp docker)"
        exit 1
    fi

    if ! docker compose version >/dev/null 2>&1 </dev/null; then
        err "Compose v2 plugin not found. This installer requires 'docker compose' (not 'docker-compose' v1)."
        err "see: https://docs.docker.com/compose/install/linux/"
        exit 1
    fi

    ok "prerequisites OK"
}

# GPU_MODE is "gpu" or "cpu", resolved by detect_gpu(). A missing GPU is NOT a
# hard failure: the same CUDA image runs on CPU (TensorFlow / PyTorch / JAX fall
# back to CPU), so we inform the user and default to CPU rather than aborting.
GPU_MODE=""
detect_gpu() {
    local pref="${KEDULAB_GPU:-auto}"
    case "$pref" in
        on|1|true|yes|y)
            GPU_MODE="gpu"; info "GPU mode forced on (KEDULAB_GPU=$pref)"; return ;;
        off|0|false|no|n)
            GPU_MODE="cpu"; warn "GPU mode forced off (KEDULAB_GPU=$pref) — defaulting to CPU"; return ;;
        auto) ;;
        *)  warn "unrecognized KEDULAB_GPU=$pref — treating as 'auto'" ;;
    esac

    if [ "$PREREQ_CHECK" -eq 0 ]; then
        GPU_MODE="gpu"
        warn "--no-prereq-check: skipping GPU probe; assuming GPU."
        warn "for CPU, re-run with KEDULAB_GPU=off or set COMPOSE_FILE=docker-compose.cpu.yml in .env."
        return
    fi

    info "GPU smoke test: docker run --rm --gpus all $GPU_PROBE_IMAGE nvidia-smi"
    info "  (pulls a ~70 MB image; skip with --no-prereq-check)"
    if docker run --rm --gpus all "$GPU_PROBE_IMAGE" nvidia-smi >/dev/null 2>&1 </dev/null; then
        GPU_MODE="gpu"
        ok "GPU detected — the stack will use it."
    else
        GPU_MODE="cpu"
        warn "no usable GPU detected (NVIDIA Container Toolkit missing or not configured for Docker)."
        warn "install guide: $NVIDIA_DOCS_URL"
        info "defaulting to CPU: the same image runs without a GPU and TensorFlow / PyTorch / JAX"
        info "fall back to CPU automatically (slower, but fully functional)."
        info "to switch to GPU later, install the toolkit and remove the COMPOSE_FILE line from .env."
    fi
}

clone_repo() {
    if [ -e "$DIR" ] && [ -n "$(ls -A "$DIR" 2>/dev/null || true)" ]; then
        if [ -d "$DIR/.git" ] && git -C "$DIR" remote get-url origin 2>/dev/null | grep -q "kedulab"; then
            warn "existing kedulab checkout detected at $DIR — leaving it in place (no git pull)"
            return 0
        fi
        err "target directory $DIR exists and is non-empty. Pick a different --dir or remove it."
        exit 1
    fi
    info "cloning $REPO_URL@$REF into $DIR"
    GIT_TERMINAL_PROMPT=0 git clone --depth 1 --branch "$REF" "$REPO_URL" "$DIR" </dev/null
    warn_if_mutable_ref
}

# A branch moves. Piping an installer straight from a branch means running
# whatever happened to land on it since you last looked — the classic
# `curl | bash` supply-chain exposure. Tags don't move, so pinning one makes the
# install reproducible and reviewable. We only warn: forcing a tag would break
# anyone tracking main deliberately.
warn_if_mutable_ref() {
    if git -C "$DIR" show-ref --verify --quiet "refs/tags/$REF" 2>/dev/null; then
        return 0
    fi
    warn "installing from mutable ref '$REF' — a branch can change under you between installs."
    warn "for a reproducible, reviewable install, pin a release tag instead: --ref <tag>"
    warn "and verify the installer before running it:"
    warn "  curl -fsSLO $REPO_URL_RAW/install.sh && sha256sum install.sh && bash install.sh"
}

TTY_AVAILABLE=0
open_tty() {
    if [ "$ASSUME_YES" -eq 1 ]; then return; fi
    if [ -r /dev/tty ] && exec 3</dev/tty 2>/dev/null; then
        TTY_AVAILABLE=1
    else
        warn "no terminal available for prompts — accepting defaults (equivalent to --yes)"
        ASSUME_YES=1
    fi
}

release_tty() {
    if [ "$TTY_AVAILABLE" -eq 1 ]; then
        exec 3<&-
        TTY_AVAILABLE=0
    fi
}

# prompt VAR_NAME "Question" "default" [env-var-override]
prompt() {
    local var="$1" question="$2" default="$3" override="${4:-}"
    local answer=""
    if [ -n "$override" ] && [ -n "${!override:-}" ]; then
        answer="${!override}"
        info "  $var = $answer  (from \$$override)"
    elif [ "$ASSUME_YES" -eq 1 ] || [ "$TTY_AVAILABLE" -eq 0 ]; then
        answer="$default"
    else
        printf '%s[?]%s %s [%s]: ' "$C_BLUE" "$C_RESET" "$question" "$default"
        IFS= read -r answer <&3 || answer=""
        [ -z "$answer" ] && answer="$default"
    fi
    printf -v "$var" '%s' "$answer"
}

confirm_overwrite_env() {
    if [ ! -f "$DIR/.env" ]; then return 0; fi
    if [ "$ASSUME_YES" -eq 1 ]; then
        warn "overwriting existing $DIR/.env (--yes)"
        return 0
    fi
    if [ "$TTY_AVAILABLE" -eq 0 ]; then
        warn "leaving existing $DIR/.env in place"
        return 1
    fi
    printf '%s[?]%s %s/.env already exists. Overwrite? [y/N]: ' "$C_BLUE" "$C_RESET" "$DIR"
    local answer=""
    IFS= read -r answer <&3 || answer=""
    case "$answer" in
        y|Y|yes|YES) return 0 ;;
        *)           warn "keeping existing $DIR/.env"; return 1 ;;
    esac
}

configure_stack() {
    open_tty

    local default_project
    default_project="$(basename "$(cd "$DIR" && pwd)")"

    info "configure your stack (press enter to accept the default):"

    local project requirements_file mount_path host_port
    prompt project           "Project name (compose -p)" "$default_project"      KEDULAB_PROJECT
    prompt requirements_file "Requirements file"         "requirements.txt"      KEDULAB_REQUIREMENTS_FILE
    prompt mount_path        "Host mount path"           "./workspace"           KEDULAB_MOUNT_PATH
    prompt host_port         "Host port"                 "8888"                  KEDULAB_HOST_PORT

    # The container runs as the non-root user `jovyan`, built at USER_UID /
    # USER_GID (image default 1000:1000). Files written into the bind mount get
    # that ownership, so if it doesn't match the host user the workspace is not
    # writable from inside the container: notebook saves fail, and the
    # entrypoint cannot create the pip-overlay or model-cache directories.
    # We're already running as the host user, so just record the right values.
    local user_uid user_gid
    user_uid="${KEDULAB_USER_UID:-$(id -u)}"
    user_gid="${KEDULAB_USER_GID:-$(id -g)}"
    # Never bake root into the image: USER_UID=0 would undo the non-root
    # posture the whole container security model rests on.
    if [ "$user_uid" = "0" ]; then
        warn "running as root — writing USER_UID/USER_GID=1000 instead of 0 so the container stays non-root."
        warn "if your workspace is owned by a different user, set USER_UID/USER_GID in .env by hand."
        user_uid=1000
        user_gid=1000
    fi
    info "  USER_UID = $user_uid, USER_GID = $user_gid  (matched to this host so the mount stays writable)"

    if confirm_overwrite_env; then
        cat > "$DIR/.env" <<EOF
COMPOSE_PROJECT_NAME=$project
REQUIREMENTS_FILE=$requirements_file
MOUNT_PATH=$mount_path
HOST_PORT=$host_port
USER_UID=$user_uid
USER_GID=$user_gid
EOF
        if [ "$GPU_MODE" = "cpu" ]; then
            cat >> "$DIR/.env" <<'EOF'
# No usable GPU detected at install time — select the CPU-only compose file.
# Remove this line (or set it to docker-compose.yml) once an NVIDIA GPU +
# Container Toolkit are available to switch the stack back to GPU.
COMPOSE_FILE=docker-compose.cpu.yml
EOF
        fi
        ok "wrote $DIR/.env"
    fi

    (cd "$DIR" && mkdir -p "$mount_path")
    info "ensured mount path exists: $DIR/$mount_path"

    info "BIND_ADDR stays 127.0.0.1 and JUPYTER_PASSWORD_HASH stays empty."
    info "For remote access, see README § Security posture."

    PROJECT_OUT="$project"
    release_tty
}

print_next_steps() {
    local mode_note=""
    if [ "$GPU_MODE" = "cpu" ]; then
        mode_note="${C_YELLOW}[kedulab] CPU mode:${C_RESET} no GPU detected, so .env pins COMPOSE_FILE=docker-compose.cpu.yml.
The stack runs on CPU. Install the NVIDIA Container Toolkit and drop that line to enable GPU.
"
    fi
    cat <<EOF

${C_GREEN}[kedulab] install complete.${C_RESET}
$mode_note
Next steps:

  cd $DIR
  docker compose --env-file .env -p $PROJECT_OUT up -d --build
  docker compose -p $PROJECT_OUT logs -f jupyter   # grab the URL/token

Configuration knobs: README.md § Configuration
Running multiple stacks in parallel: README.md § Running multiple stacks in parallel

EOF
}

main() {
    info "kedulab installer (ref=$REF, dir=$DIR)"
    if [ "$PREREQ_CHECK" -eq 1 ]; then
        check_prereqs
    else
        warn "--no-prereq-check: skipping Docker / Compose / NVIDIA Toolkit checks"
    fi
    detect_gpu
    clone_repo
    configure_stack
    print_next_steps
}

main "$@"

exit 0
