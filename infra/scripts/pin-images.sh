#!/usr/bin/env bash
# Resolve each image tag in infra/catalog/images.yaml to its linux/arm64
# manifest digest and write it back. Run from the operator workstation
# (needs registry access); commit the result.
#
#   infra/scripts/pin-images.sh            # pin all images with a null digest
#   infra/scripts/pin-images.sh --refresh  # re-resolve every tag
set -euo pipefail

catalog="$(git rev-parse --show-toplevel)/infra/catalog/images.yaml"
refresh=false
[[ ${1:-} == --refresh ]] && refresh=true

for name in $(yq -r '.images | keys | .[]' "$catalog"); do
  repo=$(yq -r ".images.\"$name\".repository" "$catalog")
  tag=$(yq -r ".images.\"$name\".tag" "$catalog")
  current=$(yq -r ".images.\"$name\".digest" "$catalog")

  if [[ $current != null && $refresh == false ]]; then
    echo "keep  $name  $repo:$tag  $current"
    continue
  fi

  digest=$(crane digest --platform linux/arm64 "$repo:$tag")
  [[ $digest =~ ^sha256:[0-9a-f]{64}$ ]] || { echo "bad digest for $repo:$tag: $digest" >&2; exit 1; }
  yq -i ".images.\"$name\".digest = \"$digest\"" "$catalog"
  echo "pin   $name  $repo:$tag  $digest"
done
