#!/usr/bin/env bash
# NVIDIA Sync custom app: Qdrant web dashboard through Sync's SSH tunnel.
#
# Paste into Sync > Custom > Add New, with:
#   Name: Qdrant dashboard    Port: 6333
#   Auto open in browser at the following path: dashboard
# The dashboard asks for the API key (CLANKER_QDRANT_API_KEY in your .env).
# Runs as you, without sudo; closing the app does not stop Qdrant.
set -euo pipefail

curl -fsS -o /dev/null http://127.0.0.1:6333/readyz \
  && echo "qdrant is ready" \
  || echo "qdrant is not answering. Check: sudo tenantctl clanker status"
exec sleep infinity
