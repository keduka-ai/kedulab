#!/bin/sh
# JupyterLab entrypoint. When JUPYTER_PASSWORD_HASH is set, switches the
# server from auto-token auth to hashed-password auth — appropriate for
# shared hosts and any deployment with BIND_ADDR != 127.0.0.1.
#
# Generate a hash on the host with:
#   python -c "from jupyter_server.auth import passwd; print(passwd())"
#
# Then export JUPYTER_PASSWORD_HASH or set it in .env.<project>.

set -eu

# --- Writable install prefix for in-notebook `!pip install <lib>` -----------
#
# The rootfs is read_only and /opt/venv lives on it, so pip cannot install
# into the venv at runtime. Point PIP_PREFIX at a directory on the
# bind-mounted workspace instead — the one persistent writable surface — and
# put its site-packages on PYTHONPATH so anything installed there is
# importable by the kernel (which inherits this environment).
#
# --prefix, NOT --target: pip's --target implies --ignore-installed and would
# re-download every transitive dep into the overlay, shadowing the pinned
# numpy/TF stack with whatever resolves latest. --prefix honours what's
# already in /opt/venv and only fetches what's genuinely missing.
#
# This dir must be created at runtime, not at build time: a build-time mkdir
# under /home/workspace is masked by the bind mount.
# `-` not `:-`: setting KEDULAB_USER_PREFIX to the empty string is the
# documented way to turn the overlay off entirely.
KEDULAB_USER_PREFIX="${KEDULAB_USER_PREFIX-/home/workspace/.kedulab-packages}"

if [ -n "$KEDULAB_USER_PREFIX" ]; then
  # Ask sysconfig for the same paths pip's --prefix will write to, rather
  # than hand-building lib/pythonX.Y/site-packages — that layout is not
  # guaranteed (Debian-patched interpreters use dist-packages).
  user_paths="$(python - "$KEDULAB_USER_PREFIX" <<'PY' 2>/dev/null || true
import sys, sysconfig
p = sys.argv[1]
v = {"base": p, "platbase": p}
for key in ("purelib", "platlib", "scripts"):
    print(sysconfig.get_path(key, "posix_prefix", vars=v))
PY
)"

  # Never fatal: a read-only or wrongly-owned bind mount must not stop
  # JupyterLab from booting — the user just loses in-notebook installs.
  purelib="$(echo "$user_paths" | sed -n 1p)"
  platlib="$(echo "$user_paths" | sed -n 2p)"
  scripts="$(echo "$user_paths" | sed -n 3p)"

  if [ -n "$purelib" ] && [ -n "$platlib" ] && [ -n "$scripts" ] \
     && mkdir -p "$purelib" "$platlib" "$scripts" 2>/dev/null; then
    PIP_PREFIX="$KEDULAB_USER_PREFIX"
    PYTHONPATH="${purelib}${PYTHONPATH:+:${PYTHONPATH}}"
    [ "$platlib" = "$purelib" ] || PYTHONPATH="${platlib}:${PYTHONPATH}"
    PATH="${scripts}:${PATH}"
    export PIP_PREFIX PYTHONPATH PATH
  else
    echo "kedulab: could not prepare ${KEDULAB_USER_PREFIX} — in-notebook" \
         "'pip install' will fail. Usual cause: the workspace mount is not" \
         "writable by the container user — set USER_UID/USER_GID to your" \
         "host 'id -u'/'id -g' and rebuild." >&2
  fi
fi

set -- \
  --ip=0.0.0.0 \
  --port="${JUPYTER_PORT:-8888}" \
  --no-browser \
  --ServerApp.iopub_data_rate_limit=1.0e10 \
  --ServerApp.max_buffer_size=1073741824

if [ -n "${JUPYTER_PASSWORD_HASH:-}" ]; then
  set -- "$@" \
    --ServerApp.password="$JUPYTER_PASSWORD_HASH" \
    --ServerApp.token=
fi

exec jupyter-lab "$@"
