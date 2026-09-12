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
- **Validation now extends to 828K.** The original gates proved retrieval at
  30K / 119K / 229K. The community ladder below adds verified needles at 100K /
  200K / 250K / 450K and **828,658 tokens**, plus a gate run at every pool step.
- **The pool is shared.** One full-length 1M request occupies ~34% of the
  validated 36 GiB pool (3,111,206 tokens, 2.97×). `--max-num-seqs 6` does not
  protect concurrent users from a single deep request — they get queued or
  preempted behind it.
- **The old "hard-hang zone" was page-cache starvation.** The 24 GiB +
  `--max-num-batched-tokens 8192` hang recorded here was later root-caused as
  the GB10 driver failing to reclaim page cache for the KV slab ("phantom
  backing") — not a hardware ceiling. With the unconditional boot-time flusher
  from [tonyd2wild's 1M-KV work](https://github.com/tonyd2wild/GLM-5.3-Flash-NVFP4-1M-KV-4x-DGX-Spark)
  the same 24 GiB boots clean, and 36 GiB is validated. The real ceiling is
  ~48 GiB, where the kernel OOM-killer takes the head worker (field report
  below).
- **Check your demand first.** Across 476 real agentic requests through this
  deployment, the deepest prompt was **122K** — under half the shipped window.
  Ship a bigger window because your traffic needs it, not for the README.

## Field report — 1M validated on a four-node switchless ring (2026-09-12)

A community deployment of this exact recipe (same image `sm121-v11-dflash2`,
same weights and drafter, patched NCCL, switchless ring) walked the KV pool up
in steps and then took the window to 1M. Both of the limits above moved.

| `--kv-cache-memory` | Window | Pool (tokens) | Full-depth concurrency | head MemFree (min) | Outcome |
|---|---|---|---|---|---|
| 24 GiB (`25769803776`) | 524,288 | 1,838,834 | 3.51× | ~24 GiB | clean |
| 36 GiB (`38654705664`) | 524,288 | 2,759,209 | 5.26× | ~12.6 GiB | clean |
| **36 GiB** | **1,048,576** | **3,111,206** | **2.97×** | **~9.0 GiB** | **clean — the 1M config** |
| 48 GiB (`51539607552`) | 1,048,576 | 4,148,995 | 3.96× | ~4.5 GiB | boot + startup complete, then kernel OOM-kills the head worker at warmup |

Receipts on the 36 GiB / 1M boot: `GPU KV cache size: 3,111,206 tokens,
Maximum concurrency for 1,048,576 tokens per request: 2.97x`; `gate.sh` 4/4;
needle at **828,658 prompt tokens** retrieved correctly (cold 451 s ≈ 1.84K
tok/s, warm re-ask 4.4 s); a 200K-token needle in 81.8 s (~2.25K tok/s). The
bigger window costs ~3.5 GiB of head overhead versus 512K at the same pool
(9.0 vs 12.6 GiB residual).

### Two prerequisites

**1. Unconditional page-cache flusher during boot (pools > ~16 GiB).** On GB10
the KV slab must come from truly free pages; `MemAvailable` counts reclaimable
page cache that the driver will not reclaim, so large pools can allocate and
then die on first touch ("phantom backing"). This root-cause and fix are
[tonyd2wild's](https://github.com/tonyd2wild/GLM-5.3-Flash-NVFP4-1M-KV-4x-DGX-Spark):
run `sync; echo 3 | sudo tee /proc/sys/vm/drop_caches` on every node every 60 s
for the whole boot window, and stop it once the gate passes. It must be
*unconditional* — a threshold-triggered flusher can sit below its threshold and
still leave the driver short. Script:
[`flusher-unconditional.sh`](https://github.com/tonyd2wild/GLM-5.3-Flash-NVFP4-1M-KV-4x-DGX-Spark/blob/main/flusher-unconditional.sh).

**2. The SM121 `persistent_topk` guard for 1M.** Booting
`--max-model-len 1048576` on this image wedges warmup with

```
launch_persistent_topk, /workspace/csrc/libtorch_stable/topk.cu:138,
persistent_topk would oversubscribe
```

The sparse-indexer top-k path launches `persistent_topk` for `select_k` in
(512, 1024, 2048); on GB10 (48 SMs, ~99 KB smem) that kernel's FilteredTopK
fallback needs 128 KB. The fix (from
[tonyd2wild's 1M-KV repo](https://github.com/tonyd2wild/GLM-5.3-Flash-NVFP4-1M-KV-4x-DGX-Spark),
`docker/sparse_attn_indexer_kpool_sm121.py`) is a one-condition guard in
`vllm/model_executor/layers/sparse_attn_indexer_kpool.py` that routes small-SM
parts to `top_k_per_row_decode`:

```python
if (
    current_platform.is_cuda()
    and select_k in (512, 1024, 2048)
    and torch.cuda.get_device_properties(0).multi_processor_count >= 78
):
```

Bind-mount the corrected file over the image's copy on all ranks (the same
technique the recipe already uses for the NCCL `.so`).

**48 GiB — what actually happens.** The KV slab allocates, all ranks capture
graphs, and `Application startup complete` is printed — then, during warmup,
the Linux OOM-killer kills the head rank's `VLLM::Worker_TP` (`dmesg`:
`global_oom ... anon-rss:…`, exit code `None`; no `NVRM` error, no CUDA
traceback, and the node itself survives). At 48 GiB the head has only ~4.5 GiB
left after alloc. **Treat 36 GiB as the practical bf16 ceiling per node on this
recipe.** More capacity needs a denser KV format (fp8), which is a different
stack.

**One operational footnote:** after roughly five or more full boot cycles
(or after an OOM kill), a node can fail NCCL init during worker startup
(`NCCL error: unhandled system error` / `remote process exited or there was a
network error`) even though config and fabric are unchanged. Reboot all four
nodes, re-apply the fabric, and relaunch — see
[`gotchas.md`](gotchas.md).

### Speculative length: 3 or 7?

`num_speculative_tokens: 7` is tuned for code/structured output. If your
traffic is prose- or analysis-heavy, `3` measured substantially better on this
ring (temp 0, median of 3, 36 GiB pool):

| Output | k=7 | k=3 | Δ |
|---|---|---|---|
| prose essay | 38.2 t/s | **45.1 t/s** | **+18%** |
| analysis (thinking on) | 36.0 t/s | **38.9 t/s** | **+8%** |
| code | **61.9 t/s** | 55.3 t/s | −11% |

k=4 sits between (41.0 / 37.9 / 59.5). It is a single-number change in
`--speculative-config`; pick per workload.

### Credits and provenance

The prerequisites above are not our discoveries — they come from the
community's work, and this report links to it rather than vendoring files:

- **tonyd2wild** — the page-cache "phantom backing" root cause, the
  unconditional flusher, and the SM121 `persistent_topk` guard, all from his
  1M-KV recipe. His repositories publish no licence, so treat the linked files
  as his work; the guard snippet above is reproduced only to describe the fix.
- **The wider DGX Spark community** — the direction that prose/analysis drafts
  better with a shorter verification length is consistent with independent
  measurements on other rings, for example the per-k step-time curves in the
  [NVIDIA forum's GLM-5.3-Flash thread](https://forums.developer.nvidia.com/t/glm-5-3-flash-320b-total-parameters-18b-active/381350).

What is new in this report is the measured ladder and receipts from our ring,
the 48 GiB failure mode, and the reboot-after-boots note. Treat them as one
more data point, not a specification.

## If you want it

In [`scripts/rank-launcher.sh`](../scripts/rank-launcher.sh), on **all four
ranks** (the serve arguments must match across the TP group):

```bash
# 512K — one change:
--max-model-len 524288

# 1M — window + pool (validated: 36 GiB holds 2.97× at full depth):
--max-model-len 1048576
--kv-cache-memory 38654705664        # 36 GiB; 16 GiB is the boundary-exact
                                     # minimum, 18 GiB gives 1.125 streams
```

Pools above ~16 GiB need the unconditional flusher on every node for the boot
window; 1M additionally needs the SM121 `persistent_topk` guard first (both in
the field report above).

Relaunch in the usual order (workers 3 → 2 → 1, then the head), then gate it
before trusting it:

1. Run [`scripts/gate.sh`](../scripts/gate.sh) as shipped.
2. Extend the needle depth towards the new window (~0.9× is a fair probe) — and
   time a full-window cold prefill so you can quote the real TTFT (~7.5 min at
   828K here).
3. If the head rank dies during warmup with nothing in the vLLM log, check
   `dmesg` for the OOM killer and step the pool down one notch. If a node
   wedges with no error and the container is unreachable, power-cycle it and
   drop the pool.

Nothing else in the recipe changes — fabric, patched NCCL, drafter, and parsers
all carry over as-is.
