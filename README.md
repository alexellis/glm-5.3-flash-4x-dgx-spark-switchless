# GLM-5.3-Flash NVFP4 — 4× DGX Spark switchless-ring TP4 + DFlash2

A reproducible recipe for serving **GLM-5.3-Flash (NVFP4)** with **tensor
parallelism across four NVIDIA DGX Spark (GB10 / `sm_121`) nodes**, joined by a
**switchless RoCE ring**, with the **DFlash2 speculative drafter** for faster
decode.

This repository is the **recipe and the contract** — the weights, the container
image, the patched NCCL, the serve arguments, the fabric-addressing template, the
launch order, the correctness gate, and the hard-won gotchas. It is deliberately
**infrastructure-agnostic**: every address, interface, and hostname is a
placeholder you replace with your own. Nothing here depends on any private
gateway, router, or network.

Built by **Alex Ellis** — [github.com/alexellis](https://github.com/alexellis) · [x.com/alexellisuk](https://x.com/alexellisuk). Licensed **MIT** (see [`LICENSE`](LICENSE)).

---

## At a glance

Four DGX Sparks in a **switchless RoCE ring** — each node cabled to two
neighbours. Non-adjacent nodes talk by **relaying through a neighbour**: A reaches
D via B or C (and B reaches C via A or D), using the routes + `DOCKER-USER`
forwarding that [`scripts/fabric-setup.sh`](scripts/fabric-setup.sh) applies. One
OpenAI-compatible endpoint (model id `glm-5.3-flash`) comes out of the head node.

```
        A ───────── B      Cabled ring links:  A–B · A–C · B–D · C–D
        │           │
        │           │      Diagonals (NOT cabled) relay via a neighbour:
        │           │        A ↔ D   via B or C
        C ───────── D        B ↔ C   via A or D
```

No switch on the fabric. If you would rather use one — or are deciding whether to
buy one — see [`docs/switches.md`](docs/switches.md) for the 100/400 GbE options
and the supply-chain reality.

---

## What this gets you

- One OpenAI-compatible endpoint (`/v1/...`) on the head node's port `8000`,
  backed by all four Sparks acting as a single TP4 engine.
- Served model id: `glm-5.3-flash`.
- Context window up to **262,144** tokens.
- Warm decode in the region of **48–51 tokens/s** for code (up to ~72 t/s warm),
  prefill around **1,800 t/s at 32–64K** — roughly the bottom commercial
  GLM-5.3 tier, on hardware you own.

---

## Hardware

- **4× NVIDIA DGX Spark** (GB10, compute capability `sm_121`).
- Each node contributes **one GPU** to the tensor-parallel group (TP4).
- Each node has a dual-port RoCE NIC (card `0000`) exposing two rails, plus a
  1 GbE management port.
- Enough local NVMe on each node for the checkpoint (~182 GiB) plus the drafter
  and the JIT/compile cache.

---

## Topology

A **switchless RoCE ring** — no top-of-rack switch on the fabric. Four nodes,
each cabled directly to its two ring neighbours; two RoCE rails per node carry
the NCCL collectives.

```
        pair edge                 pair edge
  node0 ─────────── node1   node2 ─────────── node3
    │                 │       │                 │
    │  cross edge     └───────┘   cross edge    │
    └──────────────── (ring closes) ───────────┘

Ring order:  node0 ─ node1 ─ node2 ─ node3 ─ back to node0
rank:         0       1       2       3
```

Three networks are in play, and keeping them straight is essential:

1. **Management LAN (1 GbE).** Ordinary Ethernet reachable from your operator
   box. Used for SSH orchestration **and** for the Torch rendezvous + NCCL
   bootstrap handshake. The head node's management IP is the `--master-addr`.
2. **RoCE fabric — pair rail (`f1`).** Point-to-point link joining the two nodes
   of a pair.
3. **RoCE fabric — cross rail (`f0`).** Point-to-point link joining the pairs
   into a closed ring.

NCCL uses **both** RoCE rails for the collectives; only the bootstrap rides the
management LAN.

> **Identify a node by its hostname / MAC, never by "left" or "right".** A common
> convention is to name each node after the last two bytes of its NIC MAC. Using
> physical position invites cabling and rank mistakes.

---

## What YOU provide vs what is fixed

| You provide (site-specific) | Fixed by the recipe (do not change) |
|---|---|
| Your 4 node **management IPs** | The **weights**: `LibertAIDAI/GLM-5.3-Flash-NVFP4` |
| Your **RoCE cabling** (which port on which node reaches which neighbour) | The **drafter**: `incoai/GLM-5.3-Flash-DFlash2` |
| Your **fabric IP scheme** (a template is supplied — use any private range) | The **container image**: `radixark/vllm-glm53-flash:dflash2` |
| Your **interface names** (defaults match the DGX Spark; adjust for your NICs) | The **patched NCCL 2.30.7** (skip-tree-connect, `LD_PRELOAD`) |
| Your **hostnames** and SSH access | The **serve arguments** (TP4, marlin MoE, KV **bf16** (`--kv-cache-dtype auto`), KV pool 12 GiB, DFlash `num_speculative_tokens: 7`, parsers, `max-model-len 262144`) |
| A HuggingFace token to fetch the weights (kept in your own secret store) | The **launch order** (workers 3→2→1 headless, then head 0) |

The whole point of the table: clone this, drop in your five values (four node IPs
plus your fabric scheme), and the model behaviour is identical to the reference
deployment.

---

## Quickstart

Assumes the weights, drafter, patched NCCL, and image are already staged on every
node (see [`docs/recipe.md`](docs/recipe.md) §1).

```bash
# 0. Edit the variables at the top of each script for your site.
#    scripts/fabric-setup.sh  — node IPs, interfaces, fabric addresses
#    scripts/rank-launcher.sh — master (head) IP, mgmt interface, IB HCA names
#    scripts/gate.sh          — BASE_URL of the head node

# 1. Apply the ring fabric (every boot, and after any docker churn).
./scripts/fabric-setup.sh

# 2. Launch the workers first (headless), then the head (opens the API).
ssh you@NODE3 '~/glm53-tp4-switchless-recipe/scripts/rank-launcher.sh 3'
ssh you@NODE2 '~/glm53-tp4-switchless-recipe/scripts/rank-launcher.sh 2'
ssh you@NODE1 '~/glm53-tp4-switchless-recipe/scripts/rank-launcher.sh 1'
ssh you@NODE0 '~/glm53-tp4-switchless-recipe/scripts/rank-launcher.sh 0'   # head, opens :8000

# 3. Watch the head come up (weight load + compile + warmup ~ a few minutes).
ssh you@NODE0 'docker logs -f glm53_tp4'

# 4. Gate it before trusting it: needle + tool-call + warm decode.
./scripts/gate.sh
```

Container "Up" is **not** "serving". Do not announce it as ready until the gate
in step 4 passes — see [`docs/recipe.md`](docs/recipe.md) §5.

---

## Repository layout

```
.
├── README.md                 # this file
├── CREDITS.md                # attribution — image, drafter, recipe influences
├── LICENSE                   # MIT — Alex Ellis, OpenFaaS Ltd
├── docs/
│   ├── recipe.md             # the full detailed recipe, end to end
│   ├── fabric.md             # the ring fabric addressing template + MTU
│   ├── switches.md           # switched alternatives (100/400 GbE) + supply chain
│   └── gotchas.md            # failure modes and the fixes
└── scripts/
    ├── fabric-setup.sh       # apply ring addressing + MTU (edit vars at top)
    ├── rank-launcher.sh      # launch one rank in a container (edit vars at top)
    └── gate.sh               # correctness gate (needle + tool-call + decode)
```

Start with [`docs/recipe.md`](docs/recipe.md).

---

## Consuming the endpoint

The head node exposes a standard OpenAI-compatible API on `:8000`. Point any
OpenAI-style client at `http://<head-node>:8000/v1` with model id
`glm-5.3-flash`. See [`docs/recipe.md`](docs/recipe.md) §6 for a client note on
GLM-5.3 reasoning turns (a real output-token-cap trap worth knowing about).

---

## Credits

This is an **integration** on top of other people's excellent work. See
[`CREDITS.md`](CREDITS.md). In short: the image is radixark's, the drafter is
incoai's, and several recipe details are informed by the wider DGX Spark
community. The original contribution here is the **switchless-ring integration**
(four nodes, dual-rail RoCE, no switch) with **patched NCCL 2.30.7** and the
end-to-end TP4 + DFlash2 serve recipe.
