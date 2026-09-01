# Switched alternatives (and why we run switchless)

This recipe needs **no switch**. Four nodes, two RoCE rails each, cabled directly
into a ring; traffic to the non-adjacent node relays through a neighbour via the
routes and `DOCKER-USER` forwarding that [`scripts/fabric-setup.sh`](../scripts/fabric-setup.sh)
applies. That keeps the parts list — and the cost — to a minimum, and it sidesteps
the current networking supply chain almost entirely.

If you would rather put a switch on the fabric — for robustness, for changing the
topology without re-cabling, or to scale past four nodes — MikroTik now covers
every tier that matters here, from 100G desktop money up to a 400G-capable
top-of-rack. Real models, real UK prices, and real stock below.

**Prices and stock checked 31 August 2026, UK suppliers, inc VAT at 20%.**
Both move quickly — treat this as a dated snapshot and re-check before ordering.

| Model | Ports that matter | UK price (inc VAT) | Stock (31 Aug 2026) | Max power / heat | Cooling & noise | New cables? |
|---|---|---|---|---|---|---|
| **MikroTik CRS504-4XQ-IN** (100G, compact) | 4× QSFP28 100G | **£599.44** [wifi-stock.co.uk](https://www.wifi-stock.co.uk/details/mikrotik-cloud-router-switch-crs504-4xq-in.html) · £717.76 [Ballicom](https://www.ballicom.co.uk/mikrotik-crs504-4xq-in.p1674853.html) | Out of stock at wifi-stock, Ballicom, and [LinITX](https://linitx.com/product/mikrotik-100g-crs504-cloud-router-switch-crs504-4xq-in-routeros-l5/17076) (awaiting restock) | 41 W max / ≈140 BTU/h | 2× 40 mm fans — **loud and ramping out of the box** (measured; sold as "quiet" but isn't). Tameable ~28% via `fan-target-temp`, but a Noctua swap is the real fix — see [Measured](#the-crs504-noise-reality-important) | **No** for single-rail — the ring's four QSFP28 DACs re-plug as-is (switch atop the stack; the 0.4–0.5 m reach is tight) |
| **MikroTik CRS520-4XS-16XQ-RM** (100G, ToR) | 16× QSFP28 100G + 4× SFP28 25G | £1,644.19 [MS Distribution](https://www.msdist.co.uk/products/mikrotik-crs520-4xs-16xq-rm) · **£1,679.99** [LinITX](https://linitx.com/product/mikrotik-100g-crs520-cloud-router-switch-crs520-4xs-16xq-rm/17992) | **LinITX: 3 in stock, despatch today** | 150 W max / ≈510 BTU/h | 4 hot-swap fans, 1U full-width — rack acoustics, not office | Ring DACs re-plug; add 4 more QSFP28 DACs for dual-rail, longer lengths if it lives in a rack |
| **MikroTik CRS804-4DDQ-hRM** (400G, half-width) | 4× QSFP56-DD 400G (break-out to 2×200G etc.) | **£1,139.99** [LinITX](https://linitx.com/product/mikrotik-crs804-ddq-cloud-router-400gb-4-port-switch-crs804-4ddq-hrm/18455) · ≈£1,009 [Senetic](https://www.senetic.co.uk/product/CRS804-4DDQ-HRM) (£841.18 ex) | Pre-order only: LinITX batch of 6 arriving **2 Oct 2026** (pre-sold), next batch of 2 on **18 Dec 2026** | 123 W max with optics / ≈420 BTU/h | 2 hot-swap fans, half-width 1U — the quiet one of the 400G pair | Ring DACs work day one — QSFP-DD cages accept QSFP28 at 100G; new QSFP56/QSFP-DD DACs only to go past 100G per rail |
| **MikroTik CRS812-8DS-2DQ-2DDQ-RM** (400G, full ToR) | 2× QSFP56-DD 400G + 2× QSFP56 200G + 8× SFP56 50G | **£1,040.64** [Senetic](https://www.senetic.co.uk/product/CRS812-8DS-2DQ-2DDQ-RM) (£867.20 ex) | **Senetic: 5 available**; [LinITX](https://linitx.com/product/mikrotik-crs812-ddq-cloud-router-400gb-switch-crs812-8ds-2dq-2ddq-rm/18393) on order; wifi-stock out of stock | 134 W max (STH measured ~130–140 W with optics) / ≈460 BTU/h | 4 hot-swap fans, dual 250 W PSUs — [ServeTheHome](https://www.servethehome.com/mikrotik-achieves-400gbe-in-our-mikrotik-crs812-8ds-2dq-2ddq-rm-review-keysight-cyperf-arm-marvell/): "on the verge" of desk-tolerable at idle, loud with high-power optics — rack it | Ring DACs fit only the 4 QSFP ports (at 100G); the 8× SFP56 cages need SFP-family cables the ring doesn't own |

MSRPs for calibration: CRS504 $799 · CRS520 $2,195 · CRS804 $1,295 · CRS812
$1,295. Heat figures are max-power converted (W × 3.412); MikroTik does not
publish dBA numbers, so the noise notes are from hands-on reports rather than a
datasheet.

## Which one fits this build

Four nodes × two rails = **8 fabric ports** as cabled in this recipe (or four
ports if you drop to a single rail per node and let the switch do all the
forwarding).

- **CRS504-4XQ-IN** — one 100G port per node, single-rail star. The cheapest
  path to "no relay hop", *if you can find one*: it was out of stock at every
  UK supplier checked. We cabled one and measured it: **~2.5× slower cold
  prefill** than the dual-rail ring (see [Measured](#measured--we-cabled-a-crs504-and-ran-the-real-sweep)),
  and loud fans that need a swap. Fine as a fallback/eval lane; not for
  prefill-heavy production.
- **CRS520-4XS-16XQ-RM** — the pragmatic option: takes all 8 rails at 100G
  with ports to spare for growth, and it is the only one of the four
  **actually in stock in the UK today**. Rack-grade fan noise.
- **CRS804-4DDQ-hRM** — the sweet spot on paper: four 400G ports, and
  break-out (QSFP-DD → 2× 200G) can host every rail with bandwidth headroom
  the NICs cannot saturate. Half-width, two fans, the quietest way to a 400G
  fabric — but pre-order lead times land in October at the earliest, which is
  exactly the supply-chain point this recipe routes around.
- **CRS812-8DS-2DQ-2DDQ-RM** — the full-width ToR of the family, but note the
  port mix: only two 400G ports, and the eight SFP56 cages top out at 50G —
  too slow for a rail. It suits a mixed fabric or a two-node 400G spine more
  than this four-node build; for pure rail capacity the CRS804 carries more.

## Measured — we cabled a CRS504 and ran the real sweep

We didn't leave "100G per node can bottleneck heavy collectives" as theory —
we cabled all four Sparks into a **CRS504-4XQ-IN** (single-rail 100G star),
brought GLM-5.3-Flash TP4 up over it with NCCL, and ran the same cold-prefill /
warm-decode / needle sweep as the switchless baseline. Two runs, agree within
noise. Same model, same recipe, **only the fabric changed** — so this isolates
what the fabric costs.

| Metric | Switchless 200G ring | CRS504 100G switch | Δ |
|---|---|---|---|
| Cold prefill 8K | 2,233 tok/s | **902 tok/s** | **2.5× slower** |
| Cold prefill 32K | 2,288 tok/s | **914 tok/s** | 2.5× slower |
| Cold prefill 64K | 2,273 tok/s | **912 tok/s** | 2.5× slower |
| Cold prefill 128K | 2,249 tok/s | **905 tok/s** | 2.5× slower |
| Warm re-prefill 32K (cache hit) | 2.1 s / 15,200 tok/s | **5.1 s / 6,268 tok/s** | ~2.4× slower |
| Warm decode | 37–41 tok/s | **34 tok/s** | ~15% slower |
| Needle retrieval @ ~64K | PASS | **PASS** | correctness intact |

**Why:** cold prefill is bandwidth-bound (large all-reduce collectives), and the
CRS504 gives **one ~92 Gb/s rail per node** versus the ring's **two rails**. So
prefill drops; decode is latency-bound (small messages) and barely moves;
correctness is unaffected. This is a *confounded* comparison (100G-single-rail
switched vs 200G-dual-rail switchless); isolating the switching penalty alone
would need a 200G switch (e.g. CRS812).

> ⚠️ **Caveat — the ~910 may be under-tuned, not the switch's ceiling.** Our NCCL
> environment here was the ring's (`NCCL_MIN/MAX_NCHANNELS=4`, `NCCL_CROSS_NIC=1`,
> `NCCL_ALGO=Ring`) applied unchanged to a single-rail switch, and we ran no
> PFC/lossless RoCE. A public [4-node CRS504 report](https://forums.developer.nvidia.com/t/4-node-cluster-with-crs504-and-100g-connection-results/373818)
> measured **~2,400 tok/s prefill for DeepSeek-V4-Flash on the same switch** — ~2.6×
> our GLM figure — which strongly suggests our number is config-limited (ring-tuned
> NCCL / no PFC / GLM's heavier bf16-KV collectives) rather than a 100G wall. A
> switch-appropriate re-run (auto-tuned channels, drop `CROSS_NIC`, ± PFC) is
> pending; treat the 2.5× as an upper bound on the penalty until then.

### Deployment profile (measured, switchless — the production config)

Captured across all four GB10 nodes during the sweep:

| Per node | Value |
|---|---|
| Unified memory | 128 GiB; ~113 GiB free pre-KV; **12 GiB KV pool = 786,432 tokens** (3.0× the 262K window) |
| Model on disk | 184 GiB NVFP4 checkpoint (≈46 GiB/node at TP4) + 46 GiB draft |
| GPU temp under load | **54–56 °C avg, 74 °C peak** (idle ~47 °C) |
| GPU power | **~30 W avg, ~65 W peak** (idle ~11 W) — the "~500 W for the pair" is whole-system |
| GPU util | ~37% avg, 96% peak (bursty — prefill spikes) |
| CPU | **~4–5% avg, ≤15% peak** — NCCL + spec-decode overhead is light |

### The CRS504 noise reality (important)

The CRS504-4XQ-IN is **not** "dead quiet." It has two 40 mm fans, and out of the
box they are loud and **ramp in pitch every ~30 s**. Root cause: RouterOS's
`fan-target-temp` defaults to **58 °C** while the switch ASIC idles at **59 °C**
— one degree over — so the controller keeps chasing 58 and never settles.

- **Config lever:** `/system/health/settings/set fan-target-temp=65` (the max;
  `fan-full-speed-temp` is hard-capped at 65). This **stops the ramping** and cut
  RPM ~28% in our unit (5,900 → 4,300 RPM).
- **But it's still audible**, and worse — 40 mm fans get *tonally* whiny at the
  lower RPM. `fan-min-speed-percent` is already at its 12% floor. Software is out
  of room.
- **The real fix is a fan swap:** a **Noctua NF-A4x20 (3-pin, ~£25)** is the
  well-documented remedy for the CRS line — engineered for smooth acoustics
  across the RPM range. `psu2-state=fail` (single power cord) and a missing
  internet uplink are **red herrings**; neither drives the fans.

### Jumbo-frame config gotcha (CRS504, RouterOS 7)

Getting MTU 9000 to actually pass took more than the datasheet implies:

1. Raise `l2mtu=9216` on **every** bridge member — including the non-running
   QSFP28 **breakout sub-lanes** (`qsfp28-N-2/3/4`), which otherwise cap the bridge.
2. **Remove `ether1`** (the 1 GbE copper mgmt port) from the bridge — its hardware
   max l2mtu is 2028, and as a bridge member it drags the whole bridge down.
3. Set the bridge `mtu=9216`, then **reboot the switch** — the l2mtu change only
   reaches the switch chip on reboot (a single 9000-byte ping succeeds but real
   traffic drops until then).

And **validate the data plane, not ICMP**: a `ping -f` flood showing 100% loss at
9000 B is *not* evidence the fabric drops jumbo (ICMP echo is rate-limited by the
kernel/switch control plane). Use `iperf3` (TCP retransmits + UDP loss) and, ideally,
`nccl-tests` — the traffic you actually care about. Our TCP moved 14.6 GB with **0
retransmits**; NCCL ran GLM TP4 cleanly. RoCE-over-switch also needs each node's
**RoCEv2 GID index** to match its fabric address — don't hardcode it; discover it
per node from `show_gids` (a stray second IP on one node shifted its GID off the
shared index and stalled NCCL until fixed).

## Reality check: supply chain

The snapshot above **is** the supply-chain story: the cheapest box (CRS504) is
sold out across the UK channel, the newest 400G part (CRS804) is pre-sold into
October, and what you can actually buy today is the 100G ToR (CRS520) or the
mixed-port CRS812. That is a large part of why the switchless ring is attractive
for a four-node build — it removes the switch, and its lead time, from the
critical path entirely. If you are scaling beyond four nodes, or you value the
operational simplicity of a switched fabric, put the pre-order in early rather
than as an afterthought.
