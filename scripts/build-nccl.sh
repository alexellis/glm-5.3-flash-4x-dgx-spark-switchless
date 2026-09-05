#!/usr/bin/env bash
# Build the switchless NCCL library from pinned source. No GPU is required.
set -euo pipefail

OUTPUT_DIR="${1:-$PWD/nccl-patched}"
NCCL_COMMIT=73cf112295c33aee2b895f329f592f2a9b4b0f97
PATCH_COMMIT=b70e127e8bda797e38afd9a1cefe1eb3ca790d2f
PATCH_SHA256=097656d07a5774919f0d51558b51ec05de8168c0097ed6cb7764c33230ba6eb2
CUDA_IMAGE=nvidia/cuda@sha256:450d11555d20ac8ebbbc13ebf17589c2bd42869171a90179ce7098b4a5e64c6a

case "$(uname -m)" in
    aarch64 | arm64) ;;
    *)
        echo "this builder produces the native DGX Spark ARM64 library" >&2
        echo "run it on an ARM64 Linux host or the Actuated ARM runner" >&2
        exit 2
        ;;
esac

for command in curl docker file git install ln patch sha256sum strings; do
    command -v "$command" >/dev/null || {
        echo "missing required command: $command" >&2
        exit 1
    }
done

BUILD_DIR=$(mktemp -d)
cleanup() { rm -rf -- "$BUILD_DIR"; }
trap cleanup EXIT

git clone --quiet https://github.com/NVIDIA/nccl.git "$BUILD_DIR/nccl"
git -C "$BUILD_DIR/nccl" checkout --quiet "$NCCL_COMMIT"

PATCH_URL="https://raw.githubusercontent.com/FujitsuPolycom/sparkring/$PATCH_COMMIT/spark_transport/nccl/nccl-2.30.7-skip-tree-pat.patch"
curl -fsSL "$PATCH_URL" -o "$BUILD_DIR/nccl-skip-tree.patch"
echo "$PATCH_SHA256  $BUILD_DIR/nccl-skip-tree.patch" | sha256sum -c -
git -C "$BUILD_DIR/nccl" apply "$BUILD_DIR/nccl-skip-tree.patch"

docker run --rm \
    --entrypoint bash \
    -e HOME=/tmp \
    -e BUILD_JOBS="$(nproc)" \
    -v "$BUILD_DIR/nccl:/src" \
    -w /src \
    "$CUDA_IMAGE" \
    -ceu '
        apt-get update
        DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends python3-minimal
        rm -rf /var/lib/apt/lists/*
        make -j"$BUILD_JOBS" src.build \
            CUDA_HOME=/usr/local/cuda \
            NVCC_GENCODE="-gencode=arch=compute_121,code=sm_121"
    '

install -d -m 0755 "$OUTPUT_DIR"
install -m 0755 "$BUILD_DIR/nccl/build/lib/libnccl.so.2.30.7" \
    "$OUTPUT_DIR/libnccl.so.2.30.7"
ln -sfn libnccl.so.2.30.7 "$OUTPUT_DIR/libnccl.so.2"
ln -sfn libnccl.so.2 "$OUTPUT_DIR/libnccl.so"

file "$OUTPUT_DIR/libnccl.so.2.30.7" | grep -Eq 'ARM aarch64|ARM64'
strings "$OUTPUT_DIR/libnccl.so.2.30.7" |
    grep -Fq 'NCCL version 2.30.7 compiled with CUDA 13.0'
strings "$OUTPUT_DIR/libnccl.so.2.30.7" |
    grep -Fq 'SWITCHLESS: skipping ncclTransportTreeConnect'
strings "$OUTPUT_DIR/libnccl.so.2.30.7" |
    grep -Fq 'SWITCHLESS: skipping ncclTransportPatConnect'

sha256sum "$OUTPUT_DIR/libnccl.so.2.30.7"
echo "built $OUTPUT_DIR/libnccl.so.2.30.7"
