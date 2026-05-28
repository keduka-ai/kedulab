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
