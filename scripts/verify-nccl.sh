#!/usr/bin/env bash
# Verify a built or restored switchless NCCL library before it is used.
set -euo pipefail

NCCL_DIR=${1:?usage: verify-nccl.sh NCCL_DIR}
VERSION=2.30.7
LIBRARY="$NCCL_DIR/libnccl.so.${VERSION}"

for command in file sha256sum strings; do
    command -v "$command" >/dev/null || {
        echo "missing required command: $command" >&2
        exit 1
    }
done

test -f "$LIBRARY" || {
    echo "missing $LIBRARY" >&2
    exit 1
}

file "$LIBRARY" | grep -E 'ARM aarch64|ARM64' >/dev/null
strings "$LIBRARY" |
    grep -F "NCCL version ${VERSION} compiled with CUDA 13.0" >/dev/null
strings "$LIBRARY" |
    grep -F 'SWITCHLESS: skipping ncclTransportTreeConnect' >/dev/null
strings "$LIBRARY" |
    grep -F 'SWITCHLESS: skipping ncclTransportPatConnect' >/dev/null

test -L "$NCCL_DIR/libnccl.so.2"
test "$(readlink "$NCCL_DIR/libnccl.so.2")" = "libnccl.so.${VERSION}"
test -L "$NCCL_DIR/libnccl.so"
test "$(readlink "$NCCL_DIR/libnccl.so")" = libnccl.so.2

sha256sum "$LIBRARY"
echo "verified $LIBRARY"
