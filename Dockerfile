# syntax=docker/dockerfile:1.7
#
# Single Dockerfile, multiple targets. Stages:
#   uv-bin   - pinned uv binary, copied into base
#   base     - apt deps, non-root user, uv, venv. No CMD.
#   shell    - base + project deps. No CMD. Drop in via `docker run -it`.
#   jupyter  - base + jupyter-base.txt + project deps + HEALTHCHECK + CMD.
#
# docker-compose.yml selects target=jupyter by default.

# -----------------------------------------------------------------------------
# Global build args.
#
# Every arg referenced by a `FROM` line, or shared by more than one stage, has
# to be declared HERE — above the first FROM. An ARG declared after a FROM
# belongs to that stage alone, so `FROM ${BASE_IMAGE}` would resolve against an
# empty global scope and BuildKit hard-fails with
# "base name (${BASE_IMAGE}) should not be blank".
#
# This block owns the DEFAULTS. A stage that needs one of these re-declares it
# bare (`ARG USER_UID`, no `=`), which pulls the value down from here: ARG does
# not cross a stage boundary on its own, only ENV does. Keep the defaults in
# this block alone so there is exactly one place to change them.
# Enforced by tests/dockerfile_test.sh.
#
# BASE_IMAGE defaults to the CUDA 12.4.1 runtime tag so a fresh clone builds
# with no extra setup. That tag is MUTABLE: the same name can be re-pushed with
# different contents, which silently defeats the pinning discipline applied to
# every Python dependency. For a reproducible build, resolve the digest once
# and pin it:
#
#   scripts/pin-base.sh                              # prints the digest line
#   BASE_IMAGE=nvidia/cuda@sha256:<digest>           # paste into .env
#
# The `-runtime` variant (vs `-devel`) ships only the CUDA runtime libs, not
# the toolchain (nvcc, headers) — saves ~2-3 GB, and TF wheels bundle their own
# CUDA. Switch to `-devel` if a workload compiles CUDA kernels at runtime
# (triton, cupy-from-source).
# -----------------------------------------------------------------------------
ARG BASE_IMAGE=nvidia/cuda:12.4.1-cudnn-runtime-ubuntu22.04
ARG UV_VERSION=0.5.11
ARG REQUIREMENTS_FILE=requirements.txt
ARG PYTHON_VERSION=3.12
# Match these to your host user's `id -u` / `id -g` so files written into
# MOUNT_PATH from inside the container are owned by your host user.
ARG USER_UID=1000
ARG USER_GID=1000


# -----------------------------------------------------------------------------
# Stage: uv-bin — pinned uv binary, replaces the unverified install.sh fetch.
# Bump UV_VERSION to upgrade uv across every downstream stage.
# -----------------------------------------------------------------------------
FROM ghcr.io/astral-sh/uv:${UV_VERSION} AS uv-bin


# -----------------------------------------------------------------------------
# Stage: base — common to shell + jupyter targets.
# -----------------------------------------------------------------------------
FROM ${BASE_IMAGE} AS base

ARG PYTHON_VERSION
ARG USER_UID
ARG USER_GID

ENV DEBIAN_FRONTEND=noninteractive
ENV PYTHONDONTWRITEBYTECODE=1
ENV PYTHONUNBUFFERED=1

# System dependencies for the Python wheels installed downstream.
# - poppler-utils       : pdf2image
# - tesseract-ocr       : pytesseract, unstructured.pytesseract
# - libgl1, libglib2.0-0: opencv-python
# - libsndfile1         : soundfile
# - libportaudio2, portaudio19-dev: pyaudio (runtime libs + build headers)
# - build-essential     : C compiler for pyaudio (no Linux wheels published —
#                         only Windows + sdist — so it always builds from
#                         source). Adds ~250 MB; noise next to CUDA layers.
# - libmagic1           : python-magic (transitive via unstructured / langchain)
# - ffmpeg              : yt-dlp, video / audio re-encoding
# - curl, ca-certificates: HEALTHCHECK probe + general TLS trust store
# - git                 : notebooks routinely run `!git clone` and
#                         `!pip install git+https://...`, and nbdime (pinned in
#                         requirements.txt) is a git notebook-diff driver that
#                         is inert without it
# - apt-get upgrade refreshes ~14 months of accumulated Ubuntu CVEs that
#   the upstream CUDA base image hasn't been rebuilt to pick up.
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt,sharing=locked \
    rm -f /etc/apt/apt.conf.d/docker-clean \
    && apt-get update \
    && apt-get -y upgrade --no-install-recommends \
    && apt-get install -y --no-install-recommends \
        build-essential ca-certificates curl git \
        ffmpeg libgl1 libglib2.0-0 libmagic1 \
        libportaudio2 libsndfile1 \
        poppler-utils portaudio19-dev tesseract-ocr \
    && rm -rf /var/lib/apt/lists/*

# Non-root user. /home/jovyan is masked by tmpfs at runtime when
# read_only:true is set in compose; /home/workspace is the bind-mount.
RUN groupadd --gid ${USER_GID} jovyan \
    && useradd --uid ${USER_UID} --gid ${USER_GID} -m -s /bin/bash jovyan \
    && mkdir -p /home/workspace \
    && chown -R ${USER_UID}:${USER_GID} /home/workspace

# Copy the pinned uv binary from the uv-bin stage — no network fetch at
# build time, no unverified script execution.
COPY --from=uv-bin /uv /uvx /usr/local/bin/

# UV_PYTHON_INSTALL_DIR moves uv's managed Python out of /root (mode 700,
# unreachable to jovyan). UV_LINK_MODE=copy: feed installs from the cache
# mount without leaving cache bytes in the layer. UV_COMPILE_BYTECODE=1:
# trade ~1 min build time for 10-30% faster first imports.
ENV UV_PYTHON_INSTALL_DIR=/opt/uv-python
ENV VIRTUAL_ENV=/opt/venv
ENV UV_LINK_MODE=copy
ENV UV_COMPILE_BYTECODE=1
RUN uv venv --python ${PYTHON_VERSION} ${VIRTUAL_ENV} \
    && chown -R ${USER_UID}:${USER_GID} ${VIRTUAL_ENV} ${UV_PYTHON_INSTALL_DIR}
ENV PATH="${VIRTUAL_ENV}/bin:${PATH}"

WORKDIR /home/workspace


# -----------------------------------------------------------------------------
# Stage: shell — base + project deps. No Jupyter, no CMD.
# Build with: docker build --target shell -t init-docker-shell .
# Run with:   docker run --rm -it init-docker-shell bash
# -----------------------------------------------------------------------------
FROM base AS shell

# Bare re-declarations: values come from the global block. ARG does not cross a
# stage boundary, so without these the COPY below expands to `--chown=:` with
# no source and the build fails.
ARG REQUIREMENTS_FILE
ARG USER_UID
ARG USER_GID

COPY --chown=${USER_UID}:${USER_GID} ${REQUIREMENTS_FILE} /tmp/requirements.txt

USER jovyan

RUN --mount=type=cache,target=/home/jovyan/.cache/uv,uid=${USER_UID},gid=${USER_GID} \
    uv pip install -r /tmp/requirements.txt


# -----------------------------------------------------------------------------
# Stage: jupyter — base + jupyter-base.txt + project deps + HEALTHCHECK + CMD.
# This is the default target — docker-compose.yml builds it.
# -----------------------------------------------------------------------------
FROM base AS jupyter

# Bare re-declarations: values come from the global block. ARG does not cross a
# stage boundary, so without these the COPYs below expand to `--chown=:` with
# no source and the build fails.
ARG REQUIREMENTS_FILE
ARG USER_UID
ARG USER_GID

# When set to "1" or "true", runs pip-audit --strict after deps install and
# fails the build if any flagged CVE is present. Off by default so day-to-day
# rebuilds don't block on an unpatched transitive; flip on in CI.
ARG PIP_AUDIT_STRICT=0

# Both input files are resolved in a single uv pass, so a hash-checked build
# needs hashes in BOTH of them. Pointing REQUIREMENTS_FILE at requirements.lock
# is therefore not sufficient on its own — JUPYTER_BASE_FILE has to move to
# jupyter-base.lock at the same time. Fully locked, hash-verified build:
#
#   scripts/lock.sh -a
#   REQUIREMENTS_FILE=requirements.lock \
#   JUPYTER_BASE_FILE=jupyter-base.lock \
#   REQUIRE_HASHES=1 \
#     docker compose -p locked up -d --build
ARG JUPYTER_BASE_FILE=jupyter-base.txt
ARG REQUIRE_HASHES=0

COPY --chown=${USER_UID}:${USER_GID} ${JUPYTER_BASE_FILE} /tmp/jupyter-base.txt
COPY --chown=${USER_UID}:${USER_GID} ${REQUIREMENTS_FILE} /tmp/requirements.txt

USER jovyan

# Single uv invocation: resolver runs once across both files. Cache mount
# keeps the wheel cache across builds — a requirements.txt edit no longer
# redownloads the entire wheel set. --sys-prefix installs the ipykernel
# spec into /opt/venv/share/jupyter/kernels/ml/ so it survives the
# read_only:true rootfs + tmpfs mask of /home/jovyan/.local at runtime.
RUN --mount=type=cache,target=/home/jovyan/.cache/uv,uid=${USER_UID},gid=${USER_GID} \
    if [ "$REQUIRE_HASHES" = "1" ] || [ "$REQUIRE_HASHES" = "true" ]; then \
        set -- --require-hashes; \
    else \
        set --; \
    fi \
    && uv pip install "$@" -r /tmp/jupyter-base.txt -r /tmp/requirements.txt \
    && python -m ipykernel install --sys-prefix --name=ml

# Opt-in CVE gate. Skipped unless PIP_AUDIT_STRICT is "1" or "true". A
# strict run fails the build on any vulnerable resolved package — flip on
# in CI, leave off for iterative local rebuilds.
RUN --mount=type=cache,target=/home/jovyan/.cache/uv,uid=${USER_UID},gid=${USER_GID} \
    if [ "$PIP_AUDIT_STRICT" = "1" ] || [ "$PIP_AUDIT_STRICT" = "true" ]; then \
        uv pip install pip-audit \
        && pip-audit --strict; \
    else \
        echo "pip-audit gate skipped (set PIP_AUDIT_STRICT=1 to enable)"; \
    fi

# EXPOSE is informational (Docker doesn't open ports from it). The actual
# bind port is driven at runtime by JUPYTER_PORT (defaults to 8888),
# wired through compose so host and container ports match 1:1.
EXPOSE 8888

# Probes /login over loopback — public in both token-auth and
# password-auth modes (returns 200 with the login page). /api/status was
# the previous probe but it requires auth in JupyterLab 3.x+; the
# unauthenticated curl came back 403, marking the container unhealthy and
# spamming the server log every 30s. Uses JUPYTER_PORT so the probe
# follows the configured bind. start-period is generous because cold TF
# imports can stretch the boot window.
HEALTHCHECK --interval=30s --timeout=10s --start-period=60s --retries=3 \
  CMD curl -fsS "http://localhost:${JUPYTER_PORT:-8888}/login" || exit 1

# Entrypoint wraps jupyter-lab so JUPYTER_PASSWORD_HASH at runtime can
# flip the server from auto-token to hashed-password auth without a
# rebuild. iopub_data_rate_limit / max_buffer_size raised here.
USER root
COPY scripts/entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh
USER jovyan

# No --allow-root: the container runs as jovyan, so JupyterLab will start
# without complaining and refuses to fall back to root.
CMD ["/usr/local/bin/entrypoint.sh"]
