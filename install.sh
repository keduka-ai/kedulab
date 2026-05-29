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
# Non-interactive env-var overrides (skip the matching prompt):
#   KEDULAB_REPO_URL, KEDULAB_PROJECT, KEDULAB_REQUIREMENTS_FILE, KEDULAB_MOUNT_PATH, KEDULAB_HOST_PORT

set -euo pipefail

if [ -z "${BASH_VERSION:-}" ]; then
    echo "[kedulab] error: this installer requires bash. Re-run with: bash install.sh" >&2
    exit 1
fi

REPO_URL="${KEDULAB_REPO_URL:-https://github.com/keduka-ai/kedulab.git}"
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

    info "GPU smoke test: docker run --rm --gpus all $GPU_PROBE_IMAGE nvidia-smi"
    info "  (pulls a ~70 MB image; skip with --no-prereq-check)"
    if ! docker run --rm --gpus all "$GPU_PROBE_IMAGE" nvidia-smi >/dev/null 2>&1 </dev/null; then
        err "GPU smoke test failed. NVIDIA Container Toolkit not installed or not configured for Docker."
        err "install guide: $NVIDIA_DOCS_URL"
        exit 1
    fi

    ok "prerequisites OK"
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

    if confirm_overwrite_env; then
        cat > "$DIR/.env" <<EOF
COMPOSE_PROJECT_NAME=$project
REQUIREMENTS_FILE=$requirements_file
MOUNT_PATH=$mount_path
HOST_PORT=$host_port
EOF
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
    cat <<EOF

${C_GREEN}[kedulab] install complete.${C_RESET}

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
    clone_repo
    configure_stack
    print_next_steps
}

main "$@"

exit 0
