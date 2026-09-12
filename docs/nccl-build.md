# Switchless NCCL dependency

This recipe consumes the sole supported implementation from
[`alexellis/switchless-nccl`](https://github.com/alexellis/switchless-nccl).
That repository owns the source pins, OpenFaaS Ltd hardening, ARM64 build,
release assets, loader verification, Netplan templates, and provenance.

## Canonical release pin

The deployment pin is:

- release: `v0.0.1`;
- archive: `nccl-2.30.7-switchless-hardened-sm121-linux-arm64.tar.gz`;
- archive SHA-256:
  `b4a686382a92e57b485ca1bf7cd0f9fde780a68f01ea902ac432b60505b2041f`;
- library SHA-256:
  `78cb83871792ec57d763d142e4cae26fc754ae284bcc81dcb2a7d50e17d4fa57`;
- NCCL: 2.30.7, CUDA 13.0, ARM64 `sm_121`; and
- patch mode: `NCCL_SWITCHLESS_RING_ONLY=1` with
  `NCCL_SKIP_TREE_CONNECT=1` retained as a compatibility alias.

Install it independently on each Spark:

```bash
./scripts/install-switchless-nccl.sh
```

The installer downloads the immutable GitHub release URL, verifies the archive
against the recipe's hard-coded SHA-256, verifies every file against the
bundle's `SHA256SUMS`, verifies the versioned library independently, and then
moves the complete directory into `$HOME/nccl-switchless-v0.0.1`.

The launcher mounts that directory read-only and selects the same library
through both `LD_PRELOAD` and `VLLM_NCCL_SO_PATH`. `cluster-up.sh` also checks
the versioned library hash on all four ranks before changing the deployment.

## Qualification

The release source passed CPU validation, a clean ARM64 CI build, binary marker
verification, packaging verification, a four-rank value-checked collective
gate, and a matched full-model GLM-5.3-Flash TP4 + DFlash2 RigMark comparison.
The complete NCCL evidence is in the standalone repository's
[qualification record](https://github.com/alexellis/switchless-nccl/blob/master/docs/qualification.md).

The historical `v0.1.0` NCCL asset attached to this model repository remains
available only to reproduce the 5 September receipt. It is not the deployment
default and contains only the older skip-Tree/PAT patch.

Project-owned NCCL hardening, tooling, documentation, and packaging are
Copyright 2026 Alex Ellis, OpenFaaS Ltd, under Apache-2.0. NVIDIA and SparkRing
retain their rights in the upstream sources recorded by the standalone
repository.
