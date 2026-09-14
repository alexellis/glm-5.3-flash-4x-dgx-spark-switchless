# 512K and 1M context — what it would take

The shipped endpoint serves 262,144 tokens even though GLM-5.3-Flash is
natively rated to 1,048,576 positions (`max_position_embeddings` in
`config.json`). It is a NoPE model, so a deeper window does not require a RoPE
scaling or extrapolation setting. The smaller served window is the qualified,
multi-user envelope rather than a model limit.

## The measured KV pool

The current FP8 E4M3 deployment prints this on rank 0:

```
reserved 12.0 GiB memory for KV Cache
GPU KV cache size: 1,576,246 tokens, Maximum concurrency for 262,144 tokens per request: 6.01x
```

The 12 GiB reservation is **per rank**, but 4 × 12 GiB is not a 48 GiB logical
pool. Tensor parallelism shards the model while every active sequence consumes
corresponding KV blocks on every rank. The engine-wide usable capacity is the
reported **1,576,246 logical tokens**.

At this measured point, the effective density is about **7.98 KiB per logical
token, per rank**. The same pool would provide:

| Served window | Full-depth streams in the current pool |
|---|---:|
| **262,144** (shipped) | **6.01** |
| **524,288** | **3.01** |
| **1,048,576** | **1.50** |

That means neither 512K nor a single 1M stream needs a larger KV reservation.
They need a different `--max-model-len`, a fresh graph warm-up, and depth-specific
correctness testing. `--max-num-seqs 6` is only a scheduling ceiling; it does not
promise that six maximum-depth requests fit concurrently.

## Why TP4 does not automatically multiply KV capacity

TP4 reduces the model-weight footprint on each node and provides the compute and
communication lane that makes this model fast. It does not concatenate four
independent KV heaps. Each rank holds its shard of every sequence's cache, so the
rank with the smallest usable reservation bounds the same logical token pool.

The freed memory is still valuable: it gives graph capture, compilation, prefill,
the drafter, and transient allocations room to coexist. We deliberately convert
only 12 GiB/rank of that headroom into KV. The current TP4 pool is therefore a
safety-policy choice, not evidence that sharding failed to free memory. Raising
it is possible, but it should be treated as a new appliance qualification rather
than free capacity.

## What a larger reservation might buy

These are linear projections from the measured 12 GiB point, not qualified
configurations. Allocator block rounding, graph capture, prefill workspace, and
other transient use can change the realised capacity and stability.

| KV per rank | Estimated logical tokens | 262K-window equivalents | Status |
|---:|---:|---:|---|
| **12 GiB** | **1,576,246** | **6.01×** | Current, measured, and qualified |
| 16 GiB | ~2,101,661 | ~8.02× | Unverified |
| 18 GiB | ~2,364,369 | ~9.02× | Unverified |
| 20 GiB | ~2,627,077 | ~10.02× | Unverified |
| 24 GiB | ~3,152,492 | ~12.03× | Do not jump here; prior hard-hang territory |

The manual `--kv-cache-memory` setting makes vLLM skip KV memory profiling;
`--gpu-memory-utilization` does not resize this pool. If demand justifies more
concurrency, qualify 16 GiB first, then 18 GiB, with all four ranks observed and
a strict readiness deadline. Do not infer safety from idle free memory: peak
prefill, compilation, and graph capture are the dangerous phases.

## What deeper windows cost

- **Cold TTFT becomes minutes.** At the qualified cold-prefill result of about
  1,965 tok/s, 512K is roughly **4.4 minutes**, and 1M is roughly **8.9 minutes**.
  Prefix-cache reuse still helps subsequent turns.
- **Current FP8 depth evidence stops at 28,780 tokens.** Exact retrieval passed
  there, alongside tool calling, native vision, and the RigMark output gates.
  The earlier bf16 deployment passed needles at 30K, 119K, and 229K, but that
  does not qualify the present FP8 cache at those depths.
- **One deep request consumes shared capacity.** A full 1M request would occupy
  about two-thirds of the current pool. Other requests may queue or be preempted
  despite `--max-num-seqs 6`.
- **The hard-hang zone is real.** A previous 24 GiB/rank experiment combined
  with `--max-num-batched-tokens 8192` wedged a node instead of returning a clean
  OOM. The current 12 GiB cap deliberately favours an appliance that stays up.
- **Check actual demand.** In the measured production sample, the deepest of
  476 agentic requests was 122K, under half the shipped window.

## Qualifying a deeper window

Change `--max-model-len` on all four ranks; leave the proven 12 GiB pool alone
for the first experiment:

```bash
# 512K
--max-model-len 524288

# 1M
--max-model-len 1048576
```

Then relaunch workers 3 → 2 → 1, followed by head 0, and:

1. Run [`scripts/gate.sh`](../scripts/gate.sh) unchanged.
2. Add exact needle tests at increasing depths up to about 90% of the new
   window; a shallow pass is not evidence for 512K or 1M.
3. Measure the full-window cold prefill and publish its TTFT.
4. Exercise concurrent long requests while watching memory on every rank.
5. If a node stops responding, power-cycle it and return to the 12 GiB recipe;
   do not turn an OOM hard-hang into an indefinite retry loop.

Fabric, patched NCCL, drafter, and parsers otherwise remain unchanged.
