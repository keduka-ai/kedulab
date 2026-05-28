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
# Stage: uv-bin — pinned uv binary, replaces the unverified install.sh fetch.
# Bump UV_VERSION to upgrade uv across every downstream stage.
# -----------------------------------------------------------------------------
ARG UV_VERSION=0.5.11
FROM ghcr.io/astral-sh/uv:${UV_VERSION} AS uv-bin


# -----------------------------------------------------------------------------
# Stage: base — common to shell + jupyter targets.
# -----------------------------------------------------------------------------
FROM nvidia/cuda:12.4.1-cudnn-runtime-ubuntu22.04 AS base

ARG REQUIREMENTS_FILE=requirements.txt
ARG PYTHON_VERSION=3.12
# Match these to your host user's `id -u` / `id -g` so files written into
# MOUNT_PATH from inside the container are owned by your host user.
ARG USER_UID=1000
ARG USER_GID=1000

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
# - apt-get upgrade refreshes ~14 months of accumulated Ubuntu CVEs that
#   the upstream CUDA base image hasn't been rebuilt to pick up.
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt,sharing=locked \
    rm -f /etc/apt/apt.conf.d/docker-clean \
    && apt-get update \
    && apt-get -y upgrade --no-install-recommends \
    && apt-get install -y --no-install-recommends \
        build-essential ca-certificates curl \
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

COPY --chown=${USER_UID}:${USER_GID} ${REQUIREMENTS_FILE} /tmp/requirements.txt

USER jovyan

RUN --mount=type=cache,target=/home/jovyan/.cache/uv,uid=${USER_UID},gid=${USER_GID} \
    uv pip install -r /tmp/requirements.txt


# -----------------------------------------------------------------------------
# Stage: jupyter — base + jupyter-base.txt + project deps + HEALTHCHECK + CMD.
# This is the default target — docker-compose.yml builds it.
# -----------------------------------------------------------------------------
FROM base AS jupyter

# When set to "1" or "true", runs pip-audit --strict after deps install and
# fails the build if any flagged CVE is present. Off by default so day-to-day
# rebuilds don't block on an unpatched transitive; flip on in CI.
ARG PIP_AUDIT_STRICT=0

COPY --chown=${USER_UID}:${USER_GID} jupyter-base.txt /tmp/jupyter-base.txt
COPY --chown=${USER_UID}:${USER_GID} ${REQUIREMENTS_FILE} /tmp/requirements.txt

USER jovyan

# Single uv invocation: resolver runs once across both files. Cache mount
# keeps the wheel cache across builds — a requirements.txt edit no longer
# redownloads the entire wheel set. --sys-prefix installs the ipykernel
# spec into /opt/venv/share/jupyter/kernels/ml/ so it survives the
# read_only:true rootfs + tmpfs mask of /home/jovyan/.local at runtime.
RUN --mount=type=cache,target=/home/jovyan/.cache/uv,uid=${USER_UID},gid=${USER_GID} \
    uv pip install -r /tmp/jupyter-base.txt -r /tmp/requirements.txt \
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
