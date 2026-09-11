#!/usr/bin/env bash
# Stop all four TP4 ranks. Optionally restore the site's normal supervised stacks.
set -euo pipefail
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=cluster-lib.sh
source "$SCRIPT_DIR/cluster-lib.sh"
cluster_load_config

restore=0
case "${1:-}" in
  "") ;;
  --restore-defaults) restore=1 ;;
  *) echo "usage: $0 [--restore-defaults]" >&2; exit 2 ;;
esac

cluster_remove_ranks

if [ "$restore" -eq 1 ]; then
  for rank in 0 1 2 3; do
    units=${RESTORE_UNITS[$rank]}
    [ -z "$units" ] && continue
    echo "restoring supervised stack on ${NODE_NAMES[$rank]}: $units"
    # shellcheck disable=SC2086
    cluster_remote "$rank" "sudo systemctl start $units"
  done
fi
