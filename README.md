# GLM-5.3-Flash NVFP4 — 4× DGX Spark, switchless-ring TP4 + DFlash2

![GLM-5.3-Flash (320B-A18B, NVFP4) served TP4 across four NVIDIA DGX Spark nodes on a switchless ring](images/hero.jpg)

Serve **GLM-5.3-Flash (NVFP4)** across **four NVIDIA DGX Spark (GB10 / `sm_121`)
nodes** as one tensor-parallel engine — joined by a **switchless RoCE ring** and
accelerated by the **DFlash2 speculative drafter**. One OpenAI-compatible endpoint,
a 262K context window, ~45 tok/s on real agentic traffic — on hardware you own.

This repository is the **recipe and the contract**: every address, interface, and
hostname is a placeholder you swap for your own — nothing here depends on a private
gateway, router, or network.

**Not tied to these weights, either.** The ring fabric, the patched NCCL, and the
rank-launch pattern know nothing about the model — the same four-node fabric has
also served **GLM-5.2** (in more than one quant format: EXL3, and QuantTrio) and
**DeepSeek-V4-Flash** at TP4. To adapt it, swap the weights and the model-specific
serve arguments (parsers, drafter, MoE backend, and KV sizing); everything else in
the recipe carries over.

**And no — this is not Sparkring under a different name.** It does not load the
Sparkring/SIRCL custom runtime or transport. The collectives form on **patched
NCCL 2.30.7** — a *skip-tree-connect* change `LD_PRELOAD`-ed into every
container, because stock NCCL's tree-connect step wedges on a switch-free
point-to-point fabric — plus a pinned NCCL runtime profile worked out for this
topology. The historical v0.1.0 binary remains pinned by this recipe; future
builds, loading checks, fabric templates, and releases are owned by
[`alexellis/switchless-nccl`](https://github.com/alexellis/switchless-nccl).
The custom SparkRing transport remained absent during validation. The runtime
profile is in [`docs/recipe.md`](docs/recipe.md), the NCCL migration boundary is
in [`docs/nccl-build.md`](docs/nccl-build.md), and provenance and original work
are set out in [`CREDITS.md`](CREDITS.md).

Built and run in production by **Alex Ellis** / **OpenFaaS Ltd** —
[github.com/alexellis](https://github.com/alexellis) ·
[x.com/alexellisuk](https://x.com/alexellisuk). Licensed **MIT** (see
[`LICENSE`](LICENSE)).

---

## Do you actually need a switch? No.

The received wisdom is that multi-node tensor parallelism needs a 100/400 GbE
switch on the fabric. For a four-node build it doesn't — and today, avoiding one is
a feature rather than a compromise.

This recipe cables the four Sparks into a **closed RoCE ring**: two rails per node,
each wired straight to two neighbours, with the non-adjacent hop relayed through a
neighbour (the routes and `DOCKER-USER` forwarding in
[`scripts/fabric-setup.sh`](scripts/fabric-setup.sh) handle it). No switch on the
data path — and, just as importantly, no switch on the **procurement** path, which
is the part that actually bites right now.

If you did want one, MikroTik now covers every tier — real UK prices (inc VAT)
and stock, checked **31 August 2026**:

| Model | UK price (inc VAT) | Stock | Power · noise |
|---|---|---|---|
| **CRS504-4XQ-IN** — 4× 100G QSFP28, compact | from **£599.44** | **Out of stock** UK-wide (LinITX awaiting restock) | 41 W · 2 fans, near-silent, desk-tolerable |
| **CRS520-4XS-16XQ-RM** — 16× 100G QSFP28, 1U ToR | **£1,679.99** (LinITX) | **3 in stock**, despatch today | 150 W · 4 fans, rack acoustics |
| **CRS804-4DDQ-hRM** — 4× 400G QSFP-DD, half-width | **£1,139.99** (LinITX) | Pre-order: batches **2 Oct** / **18 Dec 2026** | 123 W · 2 fans, the quiet 400G |
| **CRS812-8DS-2DQ-2DDQ-RM** — 2× 400G + 2× 200G, 1U ToR | **£1,040.64** (Senetic) | **5 available** (Senetic) | 134 W · 4 fans, loud with optics — rack it |

**Cables:** the ring runs on four short **0.4–0.5 m Amphenol 100G QSFP28 DACs**,
and they re-plug into every model above — the 400G QSFP-DD cages accept QSFP28
at 100G. New cables are only needed for dual-rail (four more DACs) or to push a
rail past 100G; per-model notes are in the
[`docs/switches.md`](docs/switches.md) table.

**Supply-chain reality (2026):** the table *is* the story — the cheapest box is
sold out UK-wide and the newest 400G part is pre-sold into October; what you can
buy today is the 100G ToR. For a four-node build the switchless ring removes the
switch, *and its lead time*, from the critical path entirely. Reach for a switch
when you scale past four nodes or want to change topology without re-cabling —
supplier links, heat figures, and port-fit notes are in
[`docs/switches.md`](docs/switches.md).

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

---

## Real serving numbers (measured, not marketed)

### Controlled RigMark run — 5 September 2026

This is the current reproducible result from the raw vLLM endpoint, with no
gateway in the measurement path: Red Hat NVFP4 weights, BF16 KV, DFlash2 at
static `k=7`, `reasoning_effort=low`, and the repository's released NCCL
v0.1.0 binary mapped into all four ranks. All **15/15** generated code, prose,
and structured outputs passed their completion gates.

The serving image in this measurement was our local experimental
`radixark/vllm-glm53-flash:dflash2` build; its per-rank image IDs and vLLM
revision are disclosed in the receipt, but the image is not distributed. The
launcher below deliberately uses Tony's pinned public image instead. The
fabric, released NCCL, weights, drafter, and serve settings are reproducible;
do not present the speed table as an image-for-image result from the public
launcher until that image has run the same receipt.

| Workload | Median | Observed range |
|---|---:|---:|
| Completed code decode | **75.2 tok/s** | 69.6–76.5 |
| Completed prose decode | **29.8 tok/s** | 29.3–30.8 |
| Valid structured decode | **109.6 tok/s** | 109.4–110.3 |
| Code TTFT | **0.348 s** | 0.341–0.352 |
| Prose TTFT | **0.272 s** | 0.263–0.282 |
| Cold 64K prefill | **2,276 tok/s** | 2,271–2,277 |
| Warm 64K replay | **40,859 tok/s** | 40,700–40,864 |
| C1 short-code aggregate | **50.8 tok/s** | 46.8–53.9 |
| C2 short-code aggregate | **75.2 tok/s** | 43.3–78.7 |
| C4 short-code aggregate | **119.3 tok/s** | 76.1–121.9 |

The structured result is a predictable-output ceiling, not a proxy for agent
speed. The code and prose rows contain long, completed outputs; they are the
figures to use for an interactive coding appliance.

The [raw TP4 receipt](data/rigmark/glm53-redhat-nvfp4-tp4-static-k7-low-20260905T191914Z.json)
and [shareable card](data/rigmark/glm53-redhat-nvfp4-tp4-static-k7-low-20260905T191914Z.card.txt)
record every output, range, immutable model and drafter revision, serving image
ID, NCCL checksum, recipe revision, and RigMark Git revision. Endpoint addresses
and credentials are absent.

### Matched TP2 → TP4 comparison

Both sides used RigMark Git `d8353e93b274`, protocol 1.0.0, identical prompts,
limits, sampling, and low-effort request bodies. This is an appliance comparison,
not topology in isolation: TP2 used Libert NVFP4 with adaptive DFlash2; TP4 used
Red Hat NVFP4 with static `k=7`.

| Metric | TP2 | TP4 | TP4 / TP2 |
|---|---:|---:|---:|
| Code decode | 42.6 | **75.2** | **1.77×** |
| Prose decode | 22.2 | **29.8** | **1.34×** |
| Structured ceiling | 54.6 | **109.6** | **2.01×** |
| Cold 64K prefill | 1,905 | **2,276** | **1.19×** |
| Warm 64K replay | 11,464 | **40,859** | **3.56×** |
| C4 short-code aggregate | 61.1 | **119.3** | **1.95×** |

The [matched TP2 receipt](data/rigmark/glm53-libert-nvfp4-tp2-adaptive-low-20260905T183114Z.json)
and [card](data/rigmark/glm53-libert-nvfp4-tp2-adaptive-low-20260905T183114Z.card.txt)
are included so the comparison can be reproduced rather than trusted.

For context, Jacopo Nardiello's earlier
[FP8 TP4 recipe](https://github.com/jnardiello/GLM-5.3-Flash-FP8-4-DGX-Spark-Switchless)
reported a RigMark run on the same workload family. It is useful directional
evidence, but not a strict A/B with this run: its archived benchmark source had
no Git identity, and it used upstream FP8 weights with dynamic `k=5/3`.

| Metric | Jacopo FP8 TP4 | This NVFP4 TP4 | Difference |
|---|---:|---:|---:|
| Code decode | 57.5 | **75.2** | **+31%** |
| Prose decode | **31.3** | 29.8 | −5% |
| Structured ceiling | 71.5 | **109.6** | **+53%** |
| Cold 64K prefill | 2,232 | **2,276** | **+2%** |
| Warm 64K replay | 39,246 | **40,859** | **+4%** |
| C4 short-code aggregate | 82.0 | **119.3** | **+45%** |

### Daily-driver history

Most recipes quote a synthetic benchmark. These are the actual serving records from
running this deployment as a **daily driver** — real agentic coding traffic through
an OpenAI-compatible gateway, not a load-generator. **TP4 only: figures from the
earlier 2× bring-up are excluded.**

| Metric | Measured (TP4, 4 nodes) |
|---|---|
| Requests served | **476** |
| Tokens through the model | **~17.5M** (17.2M prompt · 297K completion) |
| Decode on real generations (≥150 tok) | **~45 tok/s** typical, up to **~100 tok/s** warm |
| Time-to-first-token | **~1–2 s** on a warm prefix-cache hit; several seconds on a cold, deep prefill |
| Deepest single prompt served | **122K tokens** (of the 262K window) |

The figure that reframes everything: **prompt tokens outweigh completion tokens
roughly 58:1.** Real agentic coding is dominated by *reading* context, not writing
it — so **prefill throughput and prefix-cache reuse matter far more than a headline
decode rate.** A warm re-prefill of a ~19K-token turn in about two seconds is what
makes the interactive loop feel instant; the decode t/s is almost a footnote.
Optimise for the ratio you actually have, not the one the benchmarks advertise.

### Reproduce with the public benchmark

Use [`alexellis/rigmark`](https://github.com/alexellis/rigmark)
for new TP4/TP2, quantisation, or model comparisons. It fixes the code, prose,
structured, prefill, and concurrency workloads; records the appliance recipe;
and refuses to compare mismatched settings by default.

Use an explicit GLM reasoning effort and the same comparison ID as the other
appliance in the sweep:

```bash
./rigmark run \
  --base-url http://HEAD:8000 \
  --model glm-5.3-flash \
  --label glm53-nvfp4-tp4-low \
  --comparison-id YOUR-SWEEP-ID \
  --metadata metadata.json \
  --extra-body '{"chat_template_kwargs":{"reasoning_effort":"low"}}'
```

Publish the unedited result JSON. A tok/s figure whose completion gate fails
must not be presented as completed code, prose, or valid structured output.

### Concurrency

This deployment serves **two humans plus their coding agents daily**, and the
engine is tuned for a small team rather than a fleet: `--max-num-seqs 6`, with a
KV pool of 786,432 tokens (3.0× the served window). We measured concurrency two
ways, because they disagree — and the difference is the honest answer.

The decode-only sweep (steady generation, thinking off):

| Streams | Per-stream tok/s | Aggregate tok/s |
|---|---|---|
| 1 | **71** | 71 |
| 2 | 50 / 38.5 | 77 |
| 4 | 34 / 24 / 24 / 24 | **95** |

One stream already saturates the ring, so extra streams **time-share a fixed
decode budget** — per-stream falls roughly linearly while aggregate keeps
climbing. Nothing collapses; beyond `max-num-seqs` requests queue.

Real agentic clients are harsher. With genuine opencode coding sessions (mixed
prefill, thinking, and tool calls; per-session decode measured on sustained
generations of ≥150 tokens):

| Concurrent sessions | Per-session tok/s |
|---|---|
| 1 | **~44** |
| 2 | **~32** each |
| 3 | ~31 each |
| 4 | ~18 each |

Trust this table over the sweep: short tool-call bursts and speculative decode
over-read tiny predictable outputs, which is how synthetic numbers (and raw
all-request means) flatter a rig. In practice **two concurrent users cost each
about 27% of solo speed and the loop stays perfectly usable** — helped by the
58:1 ratio above: a warm re-prefill lands at ~9,000 tok/s (TTFT ~1.1 s)
regardless of who else is mid-decode, and that is what the interactive loop
actually feels like.

---

## What this gets you

- One OpenAI-compatible endpoint (`/v1/...`) on the head node's port `8000`,
  backed by all four Sparks acting as a single TP4 engine.
- Served model id: `glm-5.3-flash`.
- Context window up to **262,144** tokens. The model itself is rated to **1M**
  — the shipped window is a deliberate trade, and
  [`docs/long-context.md`](docs/long-context.md) works through exactly what
  512K or 1M would take, and what it would cost in KV.
- Controlled code decode around **75 tokens/s**, completed prose around
  **30 tokens/s**, and cold 64K prefill around **2,276 tokens/s** — roughly the bottom commercial
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
| Your 4 node **management IPs** | The **weights**: `RedHatAI/GLM-5.3-Flash-NVFP4` at the pinned revision |
| Your **RoCE cabling** (which port on which node reaches which neighbour) | The **drafter**: `incoai/GLM-5.3-Flash-DFlash2` |
| Your **fabric IP scheme** (a template is supplied — use any private range) | The **container image**: `ghcr.io/tonyd2wild/vllm-glm53-flash:sm121-v11-dflash2` (public) |
| Your **interface names** (defaults match the DGX Spark; adjust for your NICs) | The **patched NCCL 2.30.7** (skip-tree-connect, `LD_PRELOAD`) |
| Your **hostnames** and SSH access | The **serve arguments** (TP4, marlin MoE, KV **bf16** (`--kv-cache-dtype auto`), KV pool 12 GiB, DFlash `num_speculative_tokens: 7`, corrected official chat template, parsers, `max-model-len 262144`) |
| A HuggingFace token to fetch the weights (kept in your own secret store) | The **launch order** (workers 3→2→1 headless, then head 0) |

The whole point of the table: clone this, drop in your five values (four node IPs
plus your fabric scheme), and the model behaviour is identical to the reference
deployment.

---

## Quickstart

Assumes the weights, drafter, patched NCCL, and image are staged on every node.
This recipe retains the historical v0.1.0 download contract. New source builds
and future releases come from
[`alexellis/switchless-nccl`](https://github.com/alexellis/switchless-nccl).
The exact ownership and migration boundary is in
[`docs/nccl-build.md`](docs/nccl-build.md). The live RoCE gate remains mandatory
whichever installation path you use.

```bash
# 0. Edit the variables at the top of each script for your site.
#    scripts/fabric-setup.sh  — node IPs, interfaces, fabric addresses
#    scripts/rank-launcher.sh — master (head) IP, mgmt interface, IB HCA names
#    scripts/gate.sh          — BASE_URL of the head node

# 1. Apply and verify the ring fabric (every boot, and after docker churn).
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

The fabric step is deliberately a hard gate: before changing anything, it
requires all four nodes to be reachable with idle GPUs; afterwards it checks
eight RoCE-v2 GIDs, eight MTUs, and all four jumbo ring edges. The rank launcher independently
checks its two local rails, the published NCCL checksums, and competing GPU
processes. A stale TP2→TP4 network state now fails before model loading begins.

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
│   ├── long-context.md       # 512K / 1M: the KV arithmetic + how to gate it
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

Funded by **OpenFaaS Ltd**'s investment in DGX Spark hardware and R&D time, and
built by **Alex Ellis**. The original contribution here is the **switchless-ring
integration** — four nodes, dual-rail RoCE, no switch — with **patched NCCL
2.30.7** and the end-to-end TP4 + DFlash2 serve recipe, validated against real
traffic. It stands on components from **tonyd2wild** (image), **incoai** (drafter),
and the wider DGX Spark community. Full attribution in [`CREDITS.md`](CREDITS.md).
