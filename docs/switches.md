# Switched alternatives (and why we run switchless)

This recipe needs **no switch**. Four nodes, two RoCE rails each, cabled directly
into a ring; traffic to the non-adjacent node relays through a neighbour via the
routes and `DOCKER-USER` forwarding that [`scripts/fabric-setup.sh`](../scripts/fabric-setup.sh)
applies. That keeps the parts list — and the cost — to a minimum, and it sidesteps
the current networking supply chain almost entirely.

If you would rather put a switch on the fabric — for robustness, for changing the
topology without re-cabling, or to scale past four nodes — three tiers are worth
weighing. Treat the specifics as a starting point and price them for your region.

| Option | Pros | Cons |
|---|---|---|
| **100 GbE (e.g. MikroTik)** | Cheapest by far; ample for a 4-node ring or star; low power; the easiest of the three to actually source. | 100 GbE can bottleneck the NICs' full rate under heavy collectives; little headroom for growth. |
| **400 GbE — smaller** | Real bandwidth headroom; future-proofs prefill/decode as models and context grow. | Markedly pricier; fewer ports; harder to source. |
| **400 GbE — larger** | Most ports and bandwidth; scales cleanly well past four nodes. | Most expensive; meaningful power and cooling; the longest lead times. |

## Reality check: supply chain

Availability of 100/400 GbE gear is **rough** at the time of writing — long lead
times and patchy stock, and it only gets worse toward 400 GbE. That is a large part
of why the switchless ring is attractive for a 4-node build: it removes the switch
(and its lead time) from the critical path entirely. If you are scaling beyond four
nodes, or you value the operational simplicity of a switched fabric, factor the
procurement delay in early rather than as an afterthought.

> Specific models, port counts, and prices are deliberately left open — they move
> quickly and vary by region. Fill in what you can actually get hold of.
