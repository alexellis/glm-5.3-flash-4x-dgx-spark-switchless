#!/usr/bin/env bash
# Read-only status for all ranks and the served API.
set -euo pipefail
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=cluster-lib.sh
source "$SCRIPT_DIR/cluster-lib.sh"
cluster_load_config

for rank in 0 1 2 3; do
  state=$(cluster_remote "$rank" \
    "docker inspect -f '{{.State.Status}}' '$CONTAINER_NAME' 2>/dev/null || echo absent")
  gpu=$(cluster_remote "$rank" \
    "nvidia-smi --query-compute-apps=used_memory --format=csv,noheader,nounits 2>/dev/null | paste -sd, -")
  [ -n "$gpu" ] || gpu=idle
  printf 'rank=%s host=%s container=%s gpu_mib=%s\n' \
    "$rank" "${NODE_NAMES[$rank]}" "$state" "$gpu"
done

if curl -fsS --max-time 3 "$HEAD_URL/v1/models" >/dev/null 2>&1; then
  echo "API ready: $HEAD_URL"
else
  echo "API not ready: $HEAD_URL"
  exit 1
fi
