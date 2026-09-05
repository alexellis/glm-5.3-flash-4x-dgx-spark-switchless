# Build the patched NCCL library

The switchless TP4 ring requires one source change that stock NCCL 2.30.7 does
not contain: when `NCCL_SKIP_TREE_CONNECT=1`, skip Tree and PAT transport setup.
Those algorithms try to establish connections between ranks that are not
directly cabled in the four-node cycle. Ring transport remains enabled.

Earlier revisions of this recipe said “build or obtain” the library without
giving the patch or a build path. That was incomplete.

## Provenance

The two-hunk patch is from FujitsuPolycom/sparkring and is Apache-2.0 licensed:

- NCCL tag: `v2.30.7-1`;
- NCCL commit: `73cf112295c33aee2b895f329f592f2a9b4b0f97`;
- patch repository commit: `b70e127e8bda797e38afd9a1cefe1eb3ca790d2f`;
- patch SHA256:
  `097656d07a5774919f0d51558b51ec05de8168c0097ed6cb7764c33230ba6eb2`;
  and
- target: CUDA 13.0, `sm_121`, ARM64.

This recipe uses the NCCL patch only. It does not load Sparkring/SIRCL or its
custom transport at runtime.

## Reproducible ARM64 build

Run from an ARM64 Linux host with ordinary Docker. The host does not need an
NVIDIA GPU, NVIDIA driver, CUDA installation, or NVIDIA Container Toolkit:

```bash
./scripts/build-nccl.sh "$HOME/nccl-patched"
```

The script:

1. fetches the pinned NVIDIA NCCL source;
2. downloads and verifies the pinned source patch;
3. compiles only `sm_121` inside a pinned NVIDIA CUDA 13.0.2 ARM64 development
   image;
4. checks the output architecture, NCCL/CUDA version, and both patch markers;
   and
5. prints the resulting library SHA256.

The CUDA build image is a 3.66 GiB compressed one-time pull. It is compiler
userspace, not a driver stack. Nothing in the build invokes a GPU.

The repository's ARM workflow runs the same builder on an Actuated ARM64
runner. It deliberately does **not** upload the resulting `.so` as an artefact
or release asset. Operators build the library from the pinned, inspectable
source inputs.

Copy the resulting `nccl-patched/` directory to the same path on all four
Sparks. The launcher bind-mounts it read-only and selects it through
`LD_PRELOAD` and `VLLM_NCCL_SO_PATH`.

## Runtime verification

The build proves source and binary shape, not fabric behaviour. Before serving,
run the repository's ring gate on the four real Sparks. With
`NCCL_DEBUG=INFO`, initialization should show:

```text
SWITCHLESS: skipping ncclTransportTreeConnect
SWITCHLESS: skipping ncclTransportPatConnect
```

It must also show Ring selected and complete the long-context and tool-call
gates. An ARM CI runner without a GPU cannot validate RoCE collectives.

Sources: [NVIDIA NCCL](https://github.com/NVIDIA/nccl),
[pinned switchless patch](https://github.com/FujitsuPolycom/sparkring/blob/b70e127e8bda797e38afd9a1cefe1eb3ca790d2f/spark_transport/nccl/nccl-2.30.7-skip-tree-pat.patch).

