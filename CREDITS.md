# Credits & attribution

This recipe is an **integration** built on top of other people's work. It exists
because of the components and community knowledge below, and it is only fair to
say so clearly.

## Components (the fixed parts of the recipe)

- **Container image** — `radixark/vllm-glm53-flash:dflash2`. vLLM built for GLM-5.3
  with DFlash2 support on `sm_121`. Credit to **radixark** for the image.
- **Speculative drafter** — `incoai/GLM-5.3-Flash-DFlash2`. The DFlash2 drafter
  weights that make speculative decoding work for this model. Credit to **incoai**.
- **Base weights** — `LibertAIDAI/GLM-5.3-Flash-NVFP4`. The NVFP4 checkpoint of
  GLM-5.3-Flash.
- **GLM-5.3-Flash** — the underlying model, from the GLM / Z.ai lineage.

## Recipe influences (the tuning that informed the serve args)

Several serve-argument and runtime choices are informed by the wider DGX Spark
community's shared work on serving large MoE models on GB10 / `sm_121`,
including contributions and discussion from **tonyd2wild**, **Mia**, and
**0xdfi**. The single-node / 2-node DFlash2 recipe that this scales up from, and
the general `sm_121` serving know-how, owe a lot to that community.

## Original contribution here

What is new in this repository is the **switchless-ring integration**:

- Four DGX Spark nodes joined into a **closed RoCE ring with no switch**, using
  **dual RoCE rails per node** (a pair edge and a cross edge).
- A **patched NCCL 2.30.7** (skip-tree-connect, `LD_PRELOAD`-ed) that lets the
  collectives form reliably on a switch-free point-to-point fabric.
- The end-to-end **TP4 + DFlash2 serve recipe**, launch order, fabric-addressing
  template, correctness gate, and the operational gotchas that make it repeatable.

## Licence & use

This recipe (the docs and scripts in this repository) is licensed **MIT** — see
[`LICENSE`](LICENSE) — authored by **Alex Ellis**
([github.com/alexellis](https://github.com/alexellis) ·
[x.com/alexellisuk](https://x.com/alexellisuk)). Treat the third-party components
(container image, drafter, base weights, and the underlying model) under their
own respective licences and terms.
