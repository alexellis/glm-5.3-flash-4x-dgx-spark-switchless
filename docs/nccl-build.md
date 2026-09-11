# Switchless NCCL dependency

This model repository no longer owns the NCCL build or publish workflow.
Future patch source, ARM64 builds, release assets, loader verification, Netplan
templates, and provenance live in
[`alexellis/switchless-nccl`](https://github.com/alexellis/switchless-nccl).

## Historical v0.1.0 pin

The controlled RigMark receipt in this repository used the existing v0.1.0
release asset:

- archive: `nccl-2.30.7-skip-tree-pat-sm121-linux-arm64.tar.gz`;
- library SHA-256:
  `8733af78fa1bff0bf495bc0ba55928580327fd9696563dba265c66b222faf620`;
- patch mode: `NCCL_SKIP_TREE_CONNECT=1`; and
- content: legacy skip-Tree/PAT patch only.

That immutable release remains attached to this repository so its historical
receipts stay reproducible. It is not the same binary as the later live
two-patch build, which also contains the all-listener-GIDs change.

To reproduce that exact historical dependency on each Spark:

```bash
NCCL_RELEASE=v0.1.0
NCCL_ARCHIVE=nccl-2.30.7-skip-tree-pat-sm121-linux-arm64.tar.gz

curl -fLO \
  "https://github.com/alexellis/glm-5.3-flash-4x-dgx-spark-switchless/releases/download/${NCCL_RELEASE}/${NCCL_ARCHIVE}"
curl -fLO \
  "https://github.com/alexellis/glm-5.3-flash-4x-dgx-spark-switchless/releases/download/${NCCL_RELEASE}/${NCCL_ARCHIVE}.sha256"
sha256sum -c "${NCCL_ARCHIVE}.sha256"
tar -xzf "$NCCL_ARCHIVE"
install -d "$HOME/nccl-patched"
cp -a "${NCCL_ARCHIVE%.tar.gz}"/. "$HOME/nccl-patched/"
(cd "$HOME/nccl-patched" && sha256sum --check --ignore-missing SHA256SUMS)
```

## Future standalone build

The standalone repository uses SparkRing's independently implemented combined
patch. It adds the listener-GID behaviour and changes the opt-in variable to:

```text
NCCL_SWITCHLESS_RING_ONLY=1
```

No standalone release has been cut yet. Do not replace the library pinned by a
working deployment until the new binary has passed the complete four-Spark
collective and model gate. During migration, launchers should export both the
legacy and new variables so they can start either library deliberately.

See the standalone repository's
[variant matrix](https://github.com/alexellis/switchless-nccl/blob/master/docs/variants.md),
[runtime loading contract](https://github.com/alexellis/switchless-nccl/blob/master/docs/runtime.md),
and [fabric runbook](https://github.com/alexellis/switchless-nccl/blob/master/docs/fabric.md).
