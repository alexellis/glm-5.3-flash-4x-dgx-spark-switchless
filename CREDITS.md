# Credits & attribution

## Funded by OpenFaaS Ltd

This recipe exists because **OpenFaaS Ltd** invested in the hardware and the
research time to make it work: **four NVIDIA DGX Spark (GB10) nodes**, the RoCE
cabling and fabric, and the R&D hours to turn a pile of `sm_121` unknowns —
switchless multi-node NCCL, MLA KV-cache behaviour at depth, speculative decoding,
and vision enablement — into a repeatable, production-tested deployment. The recipe,
scripts, gotchas, and the measured serving numbers in this repository are the output
of that work, by **Alex Ellis**
([github.com/alexellis](https://github.com/alexellis) ·
[x.com/alexellisuk](https://x.com/alexellisuk)).

If this saves you days of your own trial and error, that is the investment paying
forward. A star on the repository, or a mention when you build on it, is
appreciated.

## What's original here

The contribution of this repository is the **switchless-ring integration** and the
end-to-end recipe around it:

- Four DGX Spark nodes joined into a **closed RoCE ring with no switch**, using
  **dual RoCE rails per node** (a pair edge and a cross edge).
- The integration of a **patched NCCL 2.30.7** (skip-tree-connect,
  `LD_PRELOAD`-ed) with the pinned runtime profile for this topology. The
  two-hunk NCCL source patch comes from **FujitsuPolycom/sparkring** under
  Apache-2.0 and is now pinned and credited in
  [`docs/nccl-build.md`](docs/nccl-build.md). Sparkring/SIRCL's custom
  transport is not part of this stack; the ring was validated without it.
- The end-to-end **TP4 + DFlash2 serve recipe**: launch order, fabric-addressing
  template, correctness gate, KV and quant choices, and the operational gotchas
  that make it repeatable — validated against real serving traffic, not just a
  benchmark.

## Standing on other people's work

This is an **integration**, and it depends on components and community knowledge
that are not ours. Credit where it is due:

- **Container image** — `ghcr.io/tonyd2wild/vllm-glm53-flash:sm121-v11-dflash2`
  (public). vLLM built for GLM-5.3 with DFlash2 support on `sm_121`. Credit to
  **tonyd2wild**.
- **Speculative drafter** — `incoai/GLM-5.3-Flash-DFlash2`. The DFlash2 drafter
  weights that make speculative decoding work for this model. Credit to **incoai**.
- **Base weights** — `LibertAIDAI/GLM-5.3-Flash-NVFP4`. The NVFP4 checkpoint of
  GLM-5.3-Flash.
- **GLM-5.3-Flash** — the underlying model, from the GLM / Z.ai lineage.
- **Community know-how** — several serve-argument and `sm_121` runtime choices are
  informed by the wider DGX Spark community's shared work on serving large MoE
  models on GB10, including **tonyd2wild**, **Mia**, and **0xdfi**. The single-node
  and 2-node DFlash2 recipes this scales up from owe a lot to that work.
- **NCCL skip-tree/PAT source patch** — the pinned Apache-2.0 patch from
  **FujitsuPolycom/sparkring**. This repository builds it against NVIDIA NCCL
  2.30.7; it does not redistribute a prebuilt NCCL binary.

## Licence

The docs and scripts in this repository are licensed **MIT** — see
[`LICENSE`](LICENSE) — © **Alex Ellis / OpenFaaS Ltd**. Treat the third-party
components (container image, drafter, base weights, and the underlying model)
under their own respective licences and terms.
