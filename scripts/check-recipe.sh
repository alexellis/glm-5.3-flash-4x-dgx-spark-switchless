#!/usr/bin/env bash

set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$ROOT"

for script in scripts/*.sh; do
  bash -n "$script"
done

printf '%s  %s\n' \
  '0c4099f3382d6c92700dfb99725025360966fd73032f0ecf32377c0d9e6309c5' \
  templates/chat_template.jinja | sha256sum --check --status -

for receipt in data/rigmark/*.json; do
  jq -e . "$receipt" >/dev/null
done

if grep -En \
  '192\.168\.|/home/|/tmp/|alex@|10\.0\.0\.|spark-[0-9a-f]{4}' \
  data/rigmark/*.json; then
  echo 'A receipt contains a private endpoint, path, user, or hostname.' >&2
  exit 1
fi

grep -q 'MASTER="10.0.0.1"' scripts/rank-launcher.sh
grep -q 'SSH_USER="you"' scripts/fabric-setup.sh
grep -q 'NCCL_RELEASE=v0.0.1' scripts/install-switchless-nccl.sh
grep -q \
  'NCCL_LIBRARY_SHA256=78cb83871792ec57d763d142e4cae26fc754ae284bcc81dcb2a7d50e17d4fa57' \
  scripts/install-switchless-nccl.sh
grep -q -- '--gpu-memory-utilization 0.85' scripts/rank-launcher.sh
grep -q -- '--kv-cache-dtype fp8_e4m3 --kv-cache-memory 12884901888' \
  scripts/rank-launcher.sh
if grep -q -- '--max-num-batched-tokens 8192' scripts/rank-launcher.sh; then
  echo 'The launcher contains the retired 8192-token scheduler override.' >&2
  exit 1
fi

echo 'Recipe syntax, pins, receipts, placeholders, and privacy checks passed.'
