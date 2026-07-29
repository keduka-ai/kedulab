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

# --- Writable cache / dataset dirs for the ML frameworks ---------------------
#
# The rootfs is read_only and only a handful of dirs under /home/jovyan are
# tmpfs, which splits the pinned dependency set into two failure modes:
#
#   Hard failure — these default to a $HOME path that is NOT tmpfs, so the
#   first write hits the read-only rootfs:
#     nltk.download(...)             -> ~/nltk_data
#     keras.datasets.*.load_data()   -> ~/.keras
#     tfds.load(...)                 -> ~/tensorflow_datasets
#
#   Silent RAM burn — these default under ~/.cache, which IS tmpfs. tmpfs is
#   RAM, it counts against the container's memory limit, and it is discarded on
#   every restart. Pulling a multi-GB checkpoint there is an OOM kill, not a
#   cache:
#     transformers / datasets        -> ~/.cache/huggingface
#     torch.hub                      -> ~/.cache/torch
#     matplotlib font cache          -> ~/.cache/matplotlib
#
# So point all of them at the bind-mounted workspace — the one persistent,
# disk-backed, writable surface — under KEDULAB_CACHE_DIR. Downloads then
# survive restarts and rebuilds, and can be wiped from the host with `rm -rf`.
#
# Same conventions as the pip overlay above: `-` not `:-` so an explicitly
# empty value disables the redirection, and failure is never fatal.
KEDULAB_CACHE_DIR="${KEDULAB_CACHE_DIR-/home/workspace/.kedulab-cache}"

if [ -n "$KEDULAB_CACHE_DIR" ]; then
  if mkdir -p "$KEDULAB_CACHE_DIR" 2>/dev/null; then
    # VAR:subdirectory. Keep in sync with tests/cache_dirs_test.sh.
    for _pair in \
      HF_HOME:huggingface \
      TORCH_HOME:torch \
      NLTK_DATA:nltk_data \
      KERAS_HOME:keras \
      TFDS_DATA_DIR:tensorflow_datasets \
      MPLCONFIGDIR:matplotlib \
      XDG_CACHE_HOME:xdg
    do
      _var="${_pair%%:*}"
      _sub="${_pair#*:}"
      # An explicitly-set value wins: a user who points HF_HOME at a shared
      # dataset volume must not have it silently rewritten.
      eval "_cur=\${${_var}-}"
      if [ -z "$_cur" ]; then
        _dir="${KEDULAB_CACHE_DIR}/${_sub}"
        if mkdir -p "$_dir" 2>/dev/null; then
          eval "export ${_var}=\"\$_dir\""
        fi
      fi
    done
    unset _pair _var _sub _cur _dir
  else
    echo "kedulab: could not prepare ${KEDULAB_CACHE_DIR} — model/dataset" \
         "downloads will fall back to the read-only rootfs (nltk, keras and" \
         "tensorflow-datasets will fail) or to RAM-backed tmpfs (huggingface," \
         "torch). Usual cause: the workspace mount is not writable by the" \
         "container user — set USER_UID/USER_GID to your host 'id -u'/'id -g'" \
         "and rebuild." >&2
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
