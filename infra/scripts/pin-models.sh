#!/usr/bin/env bash
# Resolve each model's default branch on Hugging Face to a commit SHA and
# write it into infra/catalog/models.yaml. Run from the operator workstation;
# review the diff and commit. A revision is the model's identity: stratum and
# the memory subsystem record it, so change it only through promotion
# (docs/MODEL-CATALOG.md §6).
#
#   infra/scripts/pin-models.sh              # pin entries with a null revision
#   infra/scripts/pin-models.sh llm-fast     # (re)pin one entry
set -euo pipefail

catalog="$(git rev-parse --show-toplevel)/infra/catalog/models.yaml"
only=${1:-}
auth=()
[[ -n ${HF_TOKEN:-} ]] && auth=(-H "Authorization: Bearer $HF_TOKEN")

for key in $(yq -r '.models | keys | .[]' "$catalog"); do
  [[ -n $only && $key != "$only" ]] && continue
  repo=$(yq -r ".models.\"$key\".repo" "$catalog")
  current=$(yq -r ".models.\"$key\".revision" "$catalog")

  if [[ $current != null && -z $only ]]; then
    echo "keep  $key  $repo@$current"
    continue
  fi

  sha=$(curl -fsSL "${auth[@]}" "https://huggingface.co/api/models/$repo/revision/main" | jq -r '.sha')
  [[ $sha =~ ^[0-9a-f]{40}$ ]] || { echo "could not resolve $repo (got: $sha)" >&2; exit 1; }
  yq -i ".models.\"$key\".revision = \"$sha\"" "$catalog"
  echo "pin   $key  $repo@$sha"
done
