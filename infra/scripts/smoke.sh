#!/usr/bin/env bash
# Post-converge smoke test, run from the operator workstation over the LAN.
# Proves each resident endpoint answers, requires auth, and reports the
# pinned revision it is serving. Exit non-zero on any failure.
set -euo pipefail

root=$(git rev-parse --show-toplevel)
outputs=$(cd "$root/infra/terraform/envs/prd" && terraform output -json)
fail=0

check() { # name, command...
  local name=$1; shift
  if "$@" >/dev/null 2>&1; then printf 'ok    %s\n' "$name"; else printf 'FAIL  %s\n' "$name"; fail=1; fi
}

while IFS=$'\t' read -r alias url placement; do
  if [[ $placement != resident ]]; then
    printf 'skip  %s (on-demand)\n' "$alias"
    continue
  fi
  check "$alias rejects missing key" \
    bash -c "[[ \$(curl -s -o /dev/null -w '%{http_code}' '$url/models') == 401 ]]"
  check "$alias lists its model" \
    bash -c "curl -fsS -H 'Authorization: Bearer $CLANKER_INFERENCE_API_KEY' '$url/models' | jq -e '.data[0].id == \"$alias\"'"
  root_path=$(curl -fsS -H "Authorization: Bearer $CLANKER_INFERENCE_API_KEY" "$url/models" | jq -r '.data[0].root' || true)
  printf '      serving %s\n' "${root_path:-?}"
done < <(jq -r '.endpoints.value | to_entries[] | [.key, .value.url, .value.placement] | @tsv' <<<"$outputs")

qdrant=$(jq -r '.qdrant_url.value' <<<"$outputs")
check "qdrant rejects missing key" bash -c "[[ \$(curl -s -o /dev/null -w '%{http_code}' '$qdrant/collections') == 401 ]]"
check "qdrant ready" curl -fsS -H "api-key: $CLANKER_QDRANT_API_KEY" "$qdrant/readyz"

exit $fail
