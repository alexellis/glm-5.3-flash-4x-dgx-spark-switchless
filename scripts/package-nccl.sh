#!/usr/bin/env bash
# Package a source-built NCCL library with licences and exact provenance.
set -euo pipefail

NCCL_DIR=${1:?usage: package-nccl.sh NCCL_DIR OUTPUT_DIR}
OUTPUT_DIR=${2:?usage: package-nccl.sh NCCL_DIR OUTPUT_DIR}
VERSION=2.30.7
BUNDLE="nccl-${VERSION}-skip-tree-pat-sm121-linux-arm64"
NCCL_COMMIT=73cf112295c33aee2b895f329f592f2a9b4b0f97
PATCH_COMMIT=b70e127e8bda797e38afd9a1cefe1eb3ca790d2f
PATCH_SHA256=097656d07a5774919f0d51558b51ec05de8168c0097ed6cb7764c33230ba6eb2
NCCL_LICENSE_SHA256=c1f53beabe4dbf05bd87c00f7ca6084c0cb541c3f7bf8edab7913f266018b7be
SPARKRING_LICENSE_SHA256=cfc7749b96f63bd31c3c42b5c471bf756814053e847c10f3eb003417bc523d30

for command in curl gzip install ln sha256sum tar; do
    command -v "$command" >/dev/null || {
        echo "missing required command: $command" >&2
        exit 1
    }
done

test -f "$NCCL_DIR/libnccl.so.${VERSION}" || {
    echo "missing $NCCL_DIR/libnccl.so.${VERSION}" >&2
    exit 1
}

PACKAGE_DIR=$(mktemp -d)
cleanup() { rm -rf -- "$PACKAGE_DIR"; }
trap cleanup EXIT
STAGING="$PACKAGE_DIR/$BUNDLE"
install -d -m 0755 "$STAGING" "$OUTPUT_DIR"

install -m 0755 "$NCCL_DIR/libnccl.so.${VERSION}" \
    "$STAGING/libnccl.so.${VERSION}"
ln -s "libnccl.so.${VERSION}" "$STAGING/libnccl.so.2"
ln -s libnccl.so.2 "$STAGING/libnccl.so"
install -m 0644 docs/nccl-build.md "$STAGING/PROVENANCE.md"
install -m 0644 LICENSE "$STAGING/LICENSE.recipe.txt"

curl -fsSL \
    "https://raw.githubusercontent.com/NVIDIA/nccl/$NCCL_COMMIT/LICENSE.txt" \
    -o "$STAGING/LICENSE.NCCL.txt"
echo "$NCCL_LICENSE_SHA256  $STAGING/LICENSE.NCCL.txt" | sha256sum -c -

curl -fsSL \
    "https://raw.githubusercontent.com/FujitsuPolycom/sparkring/$PATCH_COMMIT/LICENSE" \
    -o "$STAGING/LICENSE.sparkring.txt"
echo "$SPARKRING_LICENSE_SHA256  $STAGING/LICENSE.sparkring.txt" | sha256sum -c -

curl -fsSL \
    "https://raw.githubusercontent.com/FujitsuPolycom/sparkring/$PATCH_COMMIT/spark_transport/nccl/nccl-2.30.7-skip-tree-pat.patch" \
    -o "$STAGING/nccl-2.30.7-skip-tree-pat.patch"
echo "$PATCH_SHA256  $STAGING/nccl-2.30.7-skip-tree-pat.patch" | sha256sum -c -

(
    cd "$STAGING"
    sha256sum "libnccl.so.${VERSION}" \
        LICENSE.NCCL.txt LICENSE.sparkring.txt \
        nccl-2.30.7-skip-tree-pat.patch > SHA256SUMS
)

SOURCE_DATE_EPOCH=${SOURCE_DATE_EPOCH:-$(git log -1 --format=%ct)}
ASSET="$BUNDLE.tar.gz"
tar --sort=name --mtime="@$SOURCE_DATE_EPOCH" --owner=0 --group=0 \
    --numeric-owner -cf - -C "$PACKAGE_DIR" "$BUNDLE" |
    gzip -n > "$OUTPUT_DIR/$ASSET"
(
    cd "$OUTPUT_DIR"
    sha256sum "$ASSET" > "$ASSET.sha256"
)

echo "packaged $OUTPUT_DIR/$ASSET"
