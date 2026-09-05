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

echo 'Recipe syntax, pins, receipts, placeholders, and privacy checks passed.'
