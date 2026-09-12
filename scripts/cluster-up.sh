#!/usr/bin/env bash
# Deterministic four-node transition into GLM-5.3-Flash TP4.
set -euo pipefail
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=cluster-lib.sh
source "$SCRIPT_DIR/cluster-lib.sh"
cluster_load_config

preflight() {
  local rank actual_name launcher_hash template_hash gpu_procs active_links nccl_hash
  for rank in 0 1 2 3; do
    actual_name=$(cluster_remote "$rank" hostname)
    if [ "$actual_name" != "${NODE_NAMES[$rank]}" ]; then
      echo "rank $rank identity mismatch: expected ${NODE_NAMES[$rank]}, got $actual_name" >&2
      return 1
    fi
    launcher_hash=$(cluster_remote "$rank" \
      "sha256sum '$REMOTE_LAUNCHER' | cut -d ' ' -f1")
    if [ -n "${EXPECTED_LAUNCHER_SHA256:-}" ] && \
      [ "$launcher_hash" != "$EXPECTED_LAUNCHER_SHA256" ]; then
      echo "launcher hash mismatch on $actual_name: $launcher_hash" >&2
      return 1
    fi
    if ! cluster_remote "$rank" \
      "grep -q -- 'NCCL_IB_MERGE_NICS=0' '$REMOTE_LAUNCHER'"; then
      echo "launcher on $actual_name does not disable NCCL HCA merging" >&2
      return 1
    fi
    if [ -n "${REMOTE_NCCL_DIR:-}" ]; then
      nccl_hash=$(cluster_remote "$rank" \
        "sha256sum '$REMOTE_NCCL_DIR/libnccl.so.2.30.7' | cut -d ' ' -f1")
      if [ -n "${EXPECTED_NCCL_SHA256:-}" ] && \
        [ "$nccl_hash" != "$EXPECTED_NCCL_SHA256" ]; then
        echo "NCCL hash mismatch on $actual_name: $nccl_hash" >&2
        return 1
      fi
    else
      nccl_hash=launcher-default
    fi
    template_hash=$(cluster_remote "$rank" \
      "sha256sum '$REMOTE_TEMPLATE' | cut -d ' ' -f1")
    if [ "$template_hash" != "$EXPECTED_TEMPLATE_SHA256" ]; then
      echo "vision template hash mismatch on $actual_name: $template_hash" >&2
      return 1
    fi
    gpu_procs=$(cluster_remote "$rank" \
      "nvidia-smi --query-compute-apps=pid,process_name,used_memory --format=csv,noheader 2>/dev/null || true")
    if [ -n "$gpu_procs" ]; then
      echo "GPU is not empty on $actual_name: $gpu_procs" >&2
      return 1
    fi
    active_links=$(cluster_remote "$rank" \
      "rdma link show | grep -c 'state ACTIVE' || true")
    if [ "$active_links" -lt 2 ]; then
      echo "fewer than two active RDMA links on $actual_name" >&2
      return 1
    fi
    echo "preflight rank=$rank host=$actual_name launcher=$launcher_hash nccl=$nccl_hash template=OK rdma=$active_links"
  done
}

launch_rank() {
  local rank=$1
  echo "launching rank $rank on ${NODE_NAMES[$rank]}"
  if [ -n "${REMOTE_NCCL_DIR:-}" ]; then
    cluster_remote "$rank" \
      "NCCL_DIR='$REMOTE_NCCL_DIR' EXPECTED_NCCL_SHA256='${EXPECTED_NCCL_SHA256:-}' '$REMOTE_LAUNCHER' '$rank'"
  else
    cluster_remote "$rank" "$REMOTE_LAUNCHER '$rank'"
  fi
}

wait_for_collective() {
  local deadline state line now
  deadline=$(( $(date +%s) + COLLECTIVE_TIMEOUT ))
  while :; do
    state=$(cluster_remote 0 \
      "docker inspect -f '{{.State.Status}}' '$CONTAINER_NAME' 2>/dev/null || echo absent")
    line=$(cluster_remote 0 \
      "docker logs '$CONTAINER_NAME' 2>&1 | tr '\\r' '\\n' | grep -E 'Loading safetensors checkpoint shards:|Application startup complete|NCCL WARN|RuntimeError' | tail -n 1" || true)
    printf 'collective state=%s %s\n' "$state" "$line"
    case "$line" in
      *"Loading safetensors checkpoint shards:"*|*"Application startup complete"*) return 0 ;;
    esac
    if [ "$state" != running ]; then
      echo "rank exited before the first collective completed" >&2
      cluster_dump_failure
      return 1
    fi
    now=$(date +%s)
    if [ "$now" -ge "$deadline" ]; then
      echo "no shard progress within ${COLLECTIVE_TIMEOUT}s; refusing to wait indefinitely" >&2
      cluster_dump_failure
      return 1
    fi
    sleep 5
  done
}

wait_for_api() {
  local deadline state line now
  deadline=$(( $(date +%s) + STARTUP_TIMEOUT ))
  while ! curl -fsS --max-time 2 "$HEAD_URL/v1/models" >/dev/null 2>&1; do
    state=$(cluster_remote 0 \
      "docker inspect -f '{{.State.Status}}' '$CONTAINER_NAME' 2>/dev/null || echo absent")
    if [ "$state" != running ]; then
      echo "rank exited during model initialisation" >&2
      cluster_dump_failure
      return 1
    fi
    line=$(cluster_remote 0 \
      "docker logs '$CONTAINER_NAME' 2>&1 | tr '\\r' '\\n' | grep -E 'Loading safetensors checkpoint shards:|Loading weights took|GPU KV cache size:|Graph capturing finished|Application startup complete' | tail -n 1" || true)
    printf 'startup %s\n' "$line"
    now=$(date +%s)
    if [ "$now" -ge "$deadline" ]; then
      echo "API did not become ready within ${STARTUP_TIMEOUT}s" >&2
      cluster_dump_failure
      return 1
    fi
    sleep 15
  done
  echo "API ready: $HEAD_URL"
}

cluster_stop_units
cluster_remove_ranks
cluster_apply_fabric
preflight
launch_rank 3
launch_rank 2
launch_rank 1
launch_rank 0
wait_for_collective
wait_for_api
BASE_URL="$HEAD_URL/v1" bash "$SCRIPT_DIR/gate.sh"
