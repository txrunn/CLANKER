#!/usr/bin/env bash
# NVIDIA Sync custom app: open a model's API docs through Sync's SSH tunnel.
#
# Paste into Sync > Custom > Add New, with:
#   Name: Inference <alias>    Port: <model port, e.g. 8000>
#   Auto open in browser at the following path: docs
# and set PORT below to the same port.
#
# The model is owned by svc-inference and runs 24/7. This script only checks
# it is healthy and holds the tunnel open; closing the app in Sync does NOT
# stop the model. Runs as you, without sudo (Sync scripts cannot prompt).
set -euo pipefail
PORT=${PORT:-8000}

for _ in $(seq 1 30); do
  if curl -fsS -o /dev/null "http://127.0.0.1:$PORT/health"; then
    echo "model on :$PORT is healthy"
    break
  fi
  sleep 2
done
curl -fsS -o /dev/null "http://127.0.0.1:$PORT/health" \
  || echo "model on :$PORT is not answering. Check: sudo tenantctl inference status"

# Keep the tunnel alive until Sync stops the app.
exec sleep infinity
