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
| **MikroTik CRS504-4XQ-IN** (100G, compact) | 4× QSFP28 100G | **£599.44** [wifi-stock.co.uk](https://www.wifi-stock.co.uk/details/mikrotik-cloud-router-switch-crs504-4xq-in.html) · £717.76 [Ballicom](https://www.ballicom.co.uk/mikrotik-crs504-4xq-in.p1674853.html) | Out of stock at wifi-stock, Ballicom, and [LinITX](https://linitx.com/product/mikrotik-100g-crs504-cloud-router-switch-crs504-4xq-in-routeros-l5/17076) (awaiting restock) | 41 W max / ≈140 BTU/h | 2 fans (not fanless, but near-silent once booted — desk-tolerable) | **No** for single-rail — the ring's four QSFP28 DACs re-plug as-is (switch atop the stack; the 0.4–0.5 m reach is tight) |
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
  UK supplier checked. 100G per node can bottleneck heavy collectives versus
  the dual-rail ring.
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

## Reality check: supply chain

The snapshot above **is** the supply-chain story: the cheapest box (CRS504) is
sold out across the UK channel, the newest 400G part (CRS804) is pre-sold into
October, and what you can actually buy today is the 100G ToR (CRS520) or the
mixed-port CRS812. That is a large part of why the switchless ring is attractive
for a four-node build — it removes the switch, and its lead time, from the
critical path entirely. If you are scaling beyond four nodes, or you value the
operational simplicity of a switched fabric, put the pre-order in early rather
than as an afterthought.
