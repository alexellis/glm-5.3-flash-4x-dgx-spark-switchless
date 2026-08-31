# The ring fabric — addressing template & MTU

The switchless RoCE ring is **runtime-only** configuration: a reboot wipes the
addressing, MTU, and routes, and docker up/down churn rewrites the `DOCKER-USER`
iptables chain the ring relies on. Re-apply it with `scripts/fabric-setup.sh`
after **every boot** and after **any docker churn**.

All IPs below are **example values** in the private `10.10.0.0/16` range. Use any
private range you like; keep the *structure* (four point-to-point /24 links, one
per ring edge).

---

## The four ring edges

Four nodes form a closed ring. Each edge is a private /24 shared by exactly two
adjacent nodes. Two pairs are joined internally by their **pair rail (`f1`)**, and
the pairs are joined to each other by their **cross rail (`f0`)**:

```
              pair edge (f1)                    pair edge (f1)
   node0 ─────────────────────── node1  node2 ─────────────────────── node3
     │  10.10.10.1        10.10.10.2 │      │ 10.10.30.1       10.10.30.2 │
     │                               │      │                             │
     │ cross edge (f0)   10.10.20.1  └──────┘  10.10.20.2   cross edge(f0)│
     │ 10.10.40.2                                            10.10.40.1   │
     └────────────────────────── (ring closes) ─────────────────────────┘
```

| link | subnet (example) | endpoint A | endpoint B | rail |
|---|---|---|---|---|
| node0 ↔ node1 | `10.10.10.0/24` | node0 `10.10.10.1` | node1 `10.10.10.2` | pair (`f1`) |
| node1 ↔ node2 | `10.10.20.0/24` | node1 `10.10.20.2` | node2 `10.10.20.3` | cross (`f0`) |
| node2 ↔ node3 | `10.10.30.0/24` | node2 `10.10.30.3` | node3 `10.10.30.4` | pair (`f1`) |
| node3 ↔ node0 | `10.10.40.0/24` | node3 `10.10.40.4` | node0 `10.10.40.1` | cross (`f0`) |

Per-node summary (this is the table the script fills in):

| node | rank | pair rail (`f1`) addr | cross rail (`f0`) addr |
|---|---|---|---|
| node0 | 0 | `10.10.10.1/24` | `10.10.40.1/24` |
| node1 | 1 | `10.10.10.2/24` | `10.10.20.2/24` |
| node2 | 2 | `10.10.30.3/24` | `10.10.20.3/24` |
| node3 | 3 | `10.10.30.4/24` | `10.10.40.4/24` |

A useful convention (optional): make the last octet equal `rank + 1` on every
rail, so an address instantly tells you which node it is.

## The cables

Four edges means **four cables — that is the entire cable bill for the ring**.
With the nodes stacked or side by side, the shortest passive DACs on the market
do the job: this deployment runs on **0.4–0.5 m Amphenol 100G QSFP28 DACs**.
No optics, no transceivers, nothing active or fussy — buy the shortest length
that reaches, since passive DACs are the cheapest and lowest-power option at
these distances.

Moving to a switched fabric changes the count and the reach, not necessarily
the cables themselves — the per-switch cable story is in the table in
[`switches.md`](switches.md).

---

## Interface names

The example scripts default to the DGX Spark's NIC names. Adjust to your hardware:

| role | example interface (DGX Spark) | example RoCE device |
|---|---|---|
| pair rail (`f1`) | `enp1s0f1np1` | `rocep1s0f1` |
| cross rail (`f0`) | `enp1s0f0np0` | `rocep1s0f0` |
| management LAN | `enP7s7` | — |

`NCCL_IB_HCA` must list **both** RoCE devices, cross then pair, e.g.
`rocep1s0f0,rocep1s0f1`.

---

## What `fabric-setup.sh` applies, per node

1. Take the two RoCE interfaces out of NetworkManager's control (so it does not
   fight you).
2. Flush any stale addresses, set **MTU 9000**, bring both rails up.
3. Add the pair-rail and cross-rail addresses for that node.
4. Enable IP forwarding and re-assert `DOCKER-USER` ACCEPT rules for the fabric
   interfaces (docker churn drops these — hence re-applying after docker
   up/down).

Because a ring rank only exchanges collectives with its two immediate neighbours,
point-to-point addressing on directly-cabled links is what matters. If your
deployment needs any node to reach a non-adjacent subnet at L3, add the
appropriate static routes via a neighbour — the script has a clearly-marked spot
for them.

---

## Two silent failure modes

These cost you nothing at connect time and everything at run time. Watch for both.

### 1. MTU left at 1500

An address-only fix (adding IPs but forgetting MTU) leaves the rails at 1500.
NCCL connects, collectives complete, **no error** — but all-reduce runs on
1500-byte packets and decode is roughly **2.7× slower**. Always set MTU 9000 on
both rails **and restart the containers** so NCCL re-initialises at the new MTU.

### 2. ICMP jumbo ping passes while RDMA is broken

A clean `ping -M do -s 8972 <peer>` proves the L2/L3 path and MTU, but it does
**not** prove the RDMA relay works. Jumbo ping is necessary but not sufficient.
The only proof the ring is healthy is a **completed NCCL collective** — i.e. the
model actually serving and passing the correctness gate. Do not trust ping alone.

---

## Verifying

- Jumbo path (necessary, not sufficient): `ping -M do -s 8972 <neighbour-fabric-ip>`
- MTU actually applied: `ip link show <rail-if>` shows `mtu 9000`.
- Addresses present: `ip -4 addr show <rail-if>`.
- The real proof: the correctness gate in [`recipe.md`](recipe.md) §5 passes.
