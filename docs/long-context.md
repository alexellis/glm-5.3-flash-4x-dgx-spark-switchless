# 512K and 1M context — what it would take

The most common question about this recipe: *why does it ship
`--max-model-len 262144` when the model is rated to 1M?* Short answer: 262K is
the **validated, multi-user envelope**, not a ceiling. GLM-5.3-Flash is natively
trained to **1,048,576 positions** (`max_position_embeddings` in `config.json`),
and it is a NoPE model — there is no RoPE scaling or extrapolation trick
involved in going deeper. Both 512K and 1M are reachable with flag changes.

What follows is the exact arithmetic, what it costs you, and how to gate it if
you go there. If you want 1M — do it; this page is what your agent needs.

## The KV arithmetic

Measured on the running build (rank-0 log):

```
reserved 12.0 GiB memory for KV Cache
GPU KV cache size: 786,432 tokens, Maximum concurrency for 262,144 tokens per request: 3.00x
```

12 GiB ÷ 786,432 tokens = **16 KiB of KV per token, per rank** (bf16 KV — see
[`recipe.md`](recipe.md) for why FP8 KV is the wrong trade on this model).
Every projection below is that one measured number, scaled linearly:

| Window | Min pool for one full-depth stream | Suggested `--kv-cache-memory` | Full-depth streams at suggested |
|---|---|---|---|
| **262,144** (shipped) | 4 GiB | 12 GiB (`12884901888`) | 3.0 |
| **524,288** | 8 GiB | **12 GiB — unchanged** | 1.5 |
| **1,048,576** | 16 GiB (boundary-exact) | 18 GiB (`19327352832`) | 1.125 |

- **512K is one flag.** `--max-model-len 524288`, nothing else. The shipped
  12 GiB pool already holds 1.5 full-depth streams, and shallow requests share
  the same pool exactly as before.
- **1M is two flags.** `--max-model-len 1048576` plus a bigger pool. 16 GiB
  works out to 1,048,576 tokens *to the token* — a boundary-exact pool leaves
  no margin for block rounding or the speculative-decode lookahead, so take
  18 GiB and keep 12.5% headroom.

## What it costs

- **Cold TTFT becomes minutes.** Cold prefill measures ~2,000–2,300 tok/s on
  this deployment, so a full cold window is roughly **4–4.5 minutes at 512K**
  and **8–9 minutes at 1M**. Prefix-cache reuse still applies — it is the first
  deep prefill that hurts, and every user should know that number before you
  advertise the window.
- **Validation stops at 229K.** Needle retrieval is proven at 30K / 119K /
  229K; nothing beyond that has been measured here — neither retrieval quality
  nor decode speed at depth. A pass at 229K says nothing about 500K.
- **The pool is shared.** One 1M request occupies ~89% of an 18 GiB pool.
  `--max-num-seqs 6` does not protect concurrent users from a single deep
  request — they get queued or preempted behind it. The shipped config's 3.0×
  concurrency at full depth is a feature, and this trades it away.
- **The hard-hang zone is real.** 12 GiB is the known-safe pool on a 128 GiB
  GB10. 24 GiB combined with `--max-num-batched-tokens 8192` produced an OOM
  **hard-hang** — a wedged node, not a clean error (see
  [`gotchas.md`](gotchas.md)). 16–18 GiB is untested middle ground: raise the
  pool in one step, watch the whole bring-up, and be ready to power-cycle.
- **Check your demand first.** Across 476 real agentic requests through this
  deployment, the deepest prompt was **122K** — under half the shipped window.
  Ship a bigger window because your traffic needs it, not for the README.

## If you want it

In [`scripts/rank-launcher.sh`](../scripts/rank-launcher.sh), on **all four
ranks** (the serve arguments must match across the TP group):

```bash
# 512K — one change:
--max-model-len 524288

# 1M — two changes:
--max-model-len 1048576
--kv-cache-memory 19327352832        # 18 GiB; 16 GiB is the boundary-exact minimum
```

Relaunch in the usual order (workers 3 → 2 → 1, then the head), then gate it
before trusting it:

1. Run [`scripts/gate.sh`](../scripts/gate.sh) as shipped.
2. Extend the needle depth towards the new window (~0.9× is a fair probe) — and
   time a full-window cold prefill so you can quote the real TTFT.
3. If a node wedges with no error and the container is unreachable, that is the
   OOM hard-hang: power-cycle the node, drop the pool a notch, and re-gate.

Nothing else in the recipe changes — fabric, patched NCCL, drafter, and parsers
all carry over as-is.
