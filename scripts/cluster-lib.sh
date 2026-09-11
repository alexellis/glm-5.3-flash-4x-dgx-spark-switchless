#!/usr/bin/env bash
# shellcheck disable=SC2034,SC2153

cluster_load_config() {
  local script_dir config
  script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[1]}")" && pwd)
  config=${GLM53_CLUSTER_CONFIG:-$script_dir/cluster.env}
  if [ ! -f "$config" ]; then
    echo "missing cluster config: $config" >&2
    echo "copy $script_dir/cluster.env.example to $script_dir/cluster.env" >&2
    return 1
  fi
  # shellcheck disable=SC1090
  source "$config"

  local required
  for required in SSH_USER NODE0 NODE1 NODE2 NODE3 NODE0_NAME NODE1_NAME \
    NODE2_NAME NODE3_NAME REMOTE_LAUNCHER REMOTE_TEMPLATE \
    EXPECTED_TEMPLATE_SHA256 CONTAINER_NAME HEAD_URL FABRIC_COMMAND; do
    if [ -z "${!required:-}" ]; then
      echo "missing required cluster setting: $required" >&2
      return 1
    fi
  done

  # Values are loaded dynamically from the operator-owned config and the
  # arrays are consumed by the other scripts which source this library.
  NODES=("$NODE0" "$NODE1" "$NODE2" "$NODE3")
  NODE_NAMES=("$NODE0_NAME" "$NODE1_NAME" "$NODE2_NAME" "$NODE3_NAME")
  STOP_UNITS=("${STOP_UNITS_NODE0:-}" "${STOP_UNITS_NODE1:-}" \
    "${STOP_UNITS_NODE2:-}" "${STOP_UNITS_NODE3:-}")
  RESTORE_UNITS=("${RESTORE_UNITS_NODE0:-}" "${RESTORE_UNITS_NODE1:-}" \
    "${RESTORE_UNITS_NODE2:-}" "${RESTORE_UNITS_NODE3:-}")
  COLLECTIVE_TIMEOUT=${COLLECTIVE_TIMEOUT:-90}
  STARTUP_TIMEOUT=${STARTUP_TIMEOUT:-900}
  CLUSTER_SCRIPT_DIR=$script_dir
}

cluster_remote() {
  local rank=$1
  shift
  ssh -o BatchMode=yes -o ConnectTimeout=5 \
    "$SSH_USER@${NODES[$rank]}" "$@"
}

cluster_stop_units() {
  local rank units
  for rank in 0 1 2 3; do
    units=${STOP_UNITS[$rank]}
    [ -z "$units" ] && continue
    echo "stopping supervised stack on ${NODE_NAMES[$rank]}: $units"
    # The config is operator-owned and intentionally supplies unit arguments.
    # shellcheck disable=SC2086
    cluster_remote "$rank" "sudo systemctl stop $units"
  done
}

cluster_remove_ranks() {
  local rank
  for rank in 3 2 1 0; do
    echo "removing $CONTAINER_NAME on ${NODE_NAMES[$rank]}"
    cluster_remote "$rank" \
      "docker rm -f '$CONTAINER_NAME' >/dev/null 2>&1 || true"
  done
}

cluster_apply_fabric() {
  echo "applying fabric after Docker churn"
  if [ -n "${FABRIC_HOST:-}" ]; then
    ssh -o BatchMode=yes -o ConnectTimeout=5 \
      "$SSH_USER@$FABRIC_HOST" "$FABRIC_COMMAND"
  else
    (cd "$CLUSTER_SCRIPT_DIR/.." && bash "$FABRIC_COMMAND")
  fi
}

cluster_dump_failure() {
  local rank
  for rank in 0 1 2 3; do
    echo "== ${NODE_NAMES[$rank]} ==" >&2
    cluster_remote "$rank" \
      "docker inspect -f '{{.State.Status}} {{.State.ExitCode}}' '$CONTAINER_NAME' 2>/dev/null || true; docker logs --tail 35 '$CONTAINER_NAME' 2>&1 || true" >&2 || true
  done
}
