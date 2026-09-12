#!/usr/bin/env bash
# Install the exact switchless-nccl release qualified by this recipe.
set -euo pipefail

NCCL_RELEASE=v0.0.1
NCCL_PACKAGE=nccl-2.30.7-switchless-hardened-sm121-linux-arm64
NCCL_ARCHIVE="$NCCL_PACKAGE.tar.gz"
NCCL_ARCHIVE_SHA256=b4a686382a92e57b485ca1bf7cd0f9fde780a68f01ea902ac432b60505b2041f
NCCL_LIBRARY_SHA256=78cb83871792ec57d763d142e4cae26fc754ae284bcc81dcb2a7d50e17d4fa57
DESTINATION=${1:-"$HOME/nccl-switchless-$NCCL_RELEASE"}
BASE_URL="https://github.com/alexellis/switchless-nccl/releases/download/$NCCL_RELEASE"

test ! -e "$DESTINATION" || {
  echo "destination already exists: $DESTINATION" >&2
  exit 2
}

for command in curl mv readlink sha256sum tar; do
  command -v "$command" >/dev/null || {
    echo "missing required command: $command" >&2
    exit 1
  }
done

DOWNLOAD_DIR=$(mktemp -d)
cleanup() {
  case "$DOWNLOAD_DIR" in
    /tmp/*) rm -rf -- "$DOWNLOAD_DIR" ;;
    *) echo "refusing to remove unexpected download path: $DOWNLOAD_DIR" >&2 ;;
  esac
}
trap cleanup EXIT

curl -fsSLo "$DOWNLOAD_DIR/$NCCL_ARCHIVE" "$BASE_URL/$NCCL_ARCHIVE"
printf '%s  %s\n' "$NCCL_ARCHIVE_SHA256" \
  "$DOWNLOAD_DIR/$NCCL_ARCHIVE" | sha256sum --check --status -
tar -xzf "$DOWNLOAD_DIR/$NCCL_ARCHIVE" -C "$DOWNLOAD_DIR"

STAGED="$DOWNLOAD_DIR/$NCCL_PACKAGE"
test -d "$STAGED"
(
  cd "$STAGED"
  sha256sum --check SHA256SUMS
)
printf '%s  %s\n' "$NCCL_LIBRARY_SHA256" \
  "$STAGED/libnccl.so.2.30.7" | sha256sum --check --status -
test "$(readlink "$STAGED/libnccl.so.2")" = libnccl.so.2.30.7
test "$(readlink "$STAGED/libnccl.so")" = libnccl.so.2

mkdir -p "$(dirname "$DESTINATION")"
mv "$STAGED" "$DESTINATION"
echo "installed switchless-nccl $NCCL_RELEASE at $DESTINATION"
