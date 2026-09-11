# The recipe — GLM-5.3-Flash NVFP4 TP4 + DFlash2 on a 4-node switchless ring

End-to-end bring-up (and restore) for GLM-5.3-Flash NVFP4, tensor-parallel across
four DGX Spark (GB10 / `sm_121`) nodes over a switchless RoCE ring, with the
DFlash2 speculative drafter.

Every address, interface, and hostname below is an **example** — replace it with
your own. The parts labelled *fixed* are the model recipe and should not be
changed unless you know exactly why.

---

## 1. Per-node prerequisites (all four nodes)

Each node needs the following staged on local disk (paths shown relative to
`$HOME`; adapt to taste, but keep them consistent across nodes because the
launcher references them):

| Path (example) | What | Source | Fixed? |
|---|---|---|---|
| `$HOME/glm53-flash-nvfp4-redhat/` | GLM-5.3-Flash NVFP4 checkpoint (`config.json` + ~120 shards, ~182 GiB) | `RedHatAI/GLM-5.3-Flash-NVFP4` at `36c184c6…` | ✅ weights |
| `$HOME/glm53-dflash2-draft/model.safetensors` | DFlash2 speculative drafter | `incoai/GLM-5.3-Flash-DFlash2` | ✅ drafter |
| `$HOME/nccl-patched/libnccl.so.2` | Patched **NCCL 2.30.7** (skip-tree-connect; works with glibc 2.39) | build from pinned source — see §2 | ✅ patch |
| `$HOME/glm53-tp4-cache/` | JIT / torch.compile / tilelang cache (created on first run) | — | — |
| `templates/chat_template.jinja` | Corrected official GLM template, mounted read-only by the launcher | Z.ai revision `690b7052…`, SHA-256 `0c4099f3…` | ✅ template |
| image `ghcr.io/tonyd2wild/vllm-glm53-flash:sm121-v11-dflash2` | vLLM + GLM-5.3 + DFlash2, built for `sm_121` (public) | `docker pull ghcr.io/tonyd2wild/vllm-glm53-flash:sm121-v11-dflash2` | ✅ image |

Fetch the weights and drafter with your own HuggingFace token, held in your own
secret store — never inline a token on a command line or commit one.

```bash
# example, on each node
huggingface-cli download RedHatAI/GLM-5.3-Flash-NVFP4 \
  --revision 36c184c6cda000a481711306df5adde42f63321a \
  --local-dir "$HOME/glm53-flash-nvfp4-redhat"
huggingface-cli download incoai/GLM-5.3-Flash-DFlash2 \
  --local-dir "$HOME/glm53-dflash2-draft"
docker pull ghcr.io/tonyd2wild/vllm-glm53-flash:sm121-v11-dflash2
```

The launcher (`scripts/rank-launcher.sh`) asserts the staged files exist and
checks the template and published NCCL checksums before it starts a container.

---

## 2. Patched NCCL 2.30.7 (skip-tree-connect)

The switchless ring needs a **patched NCCL 2.30.7** built with a
*skip-tree-connect* change, `LD_PRELOAD`-ed into the container ahead of the
stock library. The stock tree-connect step assumes a switched fabric can form
the NCCL tree; on a bare point-to-point ring that step wedges, so it is skipped
and the ring algorithm is used directly.

This recipe's controlled receipt pins its historical v0.1.0 release asset.
Download and checksum details are in [`nccl-build.md`](nccl-build.md).

All future source builds and releases are owned by
[`alexellis/switchless-nccl`](https://github.com/alexellis/switchless-nccl).
That repository pins the NVIDIA source and CUDA image, carries the clean
combined patch and full provenance, verifies the loaded library, and publishes
the generic fabric template. It does not contain this model's weights or vLLM
arguments.

- Place the resulting directory at `$HOME/nccl-patched/` on every node.
- The launcher mounts it read-only at `/opt/patched-nccl` and sets both
  `LD_PRELOAD` and `VLLM_NCCL_SO_PATH` to it. During migration it exports both
  the legacy `NCCL_SKIP_TREE_CONNECT=1` and clean
  `NCCL_SWITCHLESS_RING_ONLY=1` selectors.

This is the single most important piece of the switchless integration. Without
it, the collectives will not form reliably on a switch-free fabric.

---

## 3. The ring fabric

The ring addressing, MTU, and routes are **runtime-only** — a reboot wipes them,
and docker up/down churn rewrites the `DOCKER-USER` iptables chain the ring
relies on. Re-apply with `scripts/fabric-setup.sh` (run from your operator box;
it SSHes to each node).

Full addressing template and the two silent failure modes are in
[`fabric.md`](fabric.md). The essentials:

- **Two RoCE rails per node.** One is the *pair edge* (joins the two nodes of a
  pair), one is the *cross edge* (joins the pairs into a ring). NCCL uses both:
  `NCCL_IB_HCA=<pair-hca>,<cross-hca>`.
- **MTU 9000 on both rails**, then restart the containers so NCCL re-inits at the
  new MTU. Leaving MTU at 1500 gives you a ring that works but runs all-reduce on
  1500-byte packets — roughly **2.7× slower decode, with no error**. This is the
  most dangerous silent trap in the whole setup.
- **Bootstrap on the management LAN**, collectives on the RoCE fabric. The head
  node's management IP is the `--master-addr`; the master port (example `29520`)
  must be open between nodes on the management LAN.

The script first refuses to touch the fabric unless all four nodes are reachable,
their expected rails exist, and their GPUs are idle. It then verifies all eight
RoCE-v2 GIDs, all eight MTUs, and all four direct jumbo paths. A mode switch can leave a
zeroed GID behind even while `ip addr` looks correct; the script stops there and
gives the recovery rather than letting four model ranks hang in NCCL.

---

## 4. Launch — workers first, head last

Order matters. Bring up ranks **3, 2, 1 headless**, then **0** (which opens the
API). From your operator box:

```bash
./scripts/fabric-setup.sh                                   # must finish with "pre-flight passed"
ssh you@NODE3 '~/.../scripts/rank-launcher.sh 3'
ssh you@NODE2 '~/.../scripts/rank-launcher.sh 2'
ssh you@NODE1 '~/.../scripts/rank-launcher.sh 1'
ssh you@NODE0 '~/.../scripts/rank-launcher.sh 0'            # head, opens :8000
ssh you@NODE0 'docker logs -f glm53_tp4'                    # watch it come up
```

**Door-to-door is a few minutes** — weight load, torch.compile, and cudagraph
warmup dominate. Container "Up" is **not** "serving".

### The fixed serve arguments

These come straight from the proven DFlash2 recipe scaled to TP4. Do not change
them unless you understand the consequence.

```
/model
  --served-model-name glm-5.3-flash --trust-remote-code
  --tensor-parallel-size 4 --nnodes 4 --node-rank <R>
  --master-addr <HEAD_MGMT_IP> --master-port <MPORT>
  --gpu-memory-utilization 0.82 --max-model-len 262144
  --max-num-seqs 6 --max-num-batched-tokens 8192 --block-size 2304 --moe-backend marlin
  --limit-mm-per-prompt '{"image":16}'
  --kv-cache-dtype auto --kv-cache-memory 12884901888       # bf16 KV, 12 GiB — see gotchas
  --speculative-config '{"method":"dflash","model":"/draft","num_speculative_tokens":7}'
  --tool-call-parser glm47 --enable-auto-tool-choice --reasoning-parser glm45
  --chat-template /opt/glm53/chat_template.jinja
  --default-chat-template-kwargs '{"reasoning_effort":"max"}'
  --distributed-executor-backend mp
  <--host 0.0.0.0 --port 8000  for rank 0  |  --headless  for ranks 1–3>
```

Notes on the choices:

- **`--moe-backend marlin`** — the MoE kernel that performs on NVFP4 / `sm_121`.
- **`--max-num-batched-tokens 8192`** — under speculative decode vLLM silently
  derives a **2048** budget and warns it's suboptimal. Raising to 8192 measured
  **+11% cold prefill** (2,055 → 2,277 t/s @ 30K) at **zero single-stream decode
  cost** (~+1 GiB, ~+2 min one-time warmup). It lifts *concurrent* throughput only
  if you were batched-token-bottlenecked — measure your own baseline first (ours was
  already unthrottled at 4 streams, so we banked the prefill gain, not a concurrency
  jump). Keep clear of the 24 GiB-KV + 8192 combo — that's the OOM-hard-hang case.
- **`--kv-cache-dtype auto` (bf16 KV) + `--kv-cache-memory 12 GiB`** — use an
  *unquantised* (bf16) KV cache. FP8 KV (`fp8_e4m3`) is a blunt per-tensor quant
  whose error accumulates with context depth; DeepSeek-MLA models avoid that with
  the native `fp8_ds_mla` format, but GLM-5.3-Flash is **NoPE**-MLA and does not
  fit the `fp8_ds_mla` path (a `pe_dim` mismatch) — so the clean choice here is
  bf16. Because MLA keeps the KV small, bf16 still yields a large pool
  (**786,432 tokens, 3.0× the 262K window** — the rank-0 log prints it at
  start-up) and costs nothing on decode.
  Validated: mid-context needle retrieval passes at **30K / 119K / 229K** tokens.
  The pool is capped at 12 GiB on purpose — chasing it higher risks an OOM
  **hard-hang** on a node (not a clean error). See [`gotchas.md`](gotchas.md).
  Wondering about a 512K or 1M window instead? The arithmetic and the gating
  steps are worked through in [`long-context.md`](long-context.md).
- **DFlash speculative config, `num_speculative_tokens: 7`** — the DFlash2 drafter
  mounted at `/draft`; 7 is the tuned depth for this pairing.
- **`--tool-call-parser glm47 --reasoning-parser glm45`** — GLM-5.3 emits
  glm47-style tool calls and glm45-style reasoning. Both parsers are required for
  correct tool-calling and thinking behaviour.
- **`--max-model-len 262144`** — the served context window.

### The fixed NCCL / runtime environment (switchless)

```
LD_PRELOAD=/opt/patched-nccl/libnccl.so.2
VLLM_NCCL_SO_PATH=/opt/patched-nccl/libnccl.so.2            # patched NCCL 2.30.7
NCCL_SKIP_TREE_CONNECT=1
NCCL_SWITCHLESS_RING_ONLY=1
NCCL_SOCKET_IFNAME=<mgmt-if>  GLOO_SOCKET_IFNAME=<mgmt-if>  VLLM_HOST_IP=<this node mgmt ip>
NCCL_NET=IB  NCCL_IB_DISABLE=0  NCCL_IB_HCA=<pair-hca>,<cross-hca>    # both rails
NCCL_IB_MERGE_NICS=0
NCCL_IB_GID_INDEX=3  NCCL_IB_SUBNET_PREFIX_LEN=24  NCCL_IB_SUBNET_AWARE_ROUTING=1
NCCL_ALGO=Ring  NCCL_PROTO=LL,LL128,Simple  NCCL_P2P_LEVEL=SYS
NCCL_MIN_NCHANNELS=4  NCCL_MAX_NCHANNELS=4  NCCL_CROSS_NIC=1  NCCL_CUMEM_ENABLE=0
NCCL_IGNORE_CPU_AFFINITY=1
VLLM_ONE_GPU_PER_NODE=1  PYTORCH_CUDA_ALLOC_CONF=expandable_segments:True
TORCH_CUDA_ARCH_LIST=12.1a  FLASHINFER_CUDA_ARCH_LIST=12.1a
HF_HUB_OFFLINE=1  TRANSFORMERS_OFFLINE=1
```

`NCCL_ALGO=Ring` and the fixed channel count reflect the switchless ring. Keep
`NCCL_IB_MERGE_NICS=0`: NCCL otherwise merges both HCAs into one virtual device
and can pair GIDs that are not joined by a physical cable. The patched listener
advertises both GIDs so subnet-aware routing can select the correct unmerged
rail for each peer.

### Container flags

```
--network host --ipc host --shm-size 32g --gpus all
--device /dev/infiniband --cap-add IPC_LOCK --ulimit memlock=-1:-1
```

Mounts: `glm53-flash-nvfp4 → /model:ro`, `glm53-dflash2-draft → /draft:ro`,
`nccl-patched → /opt/patched-nccl:ro`, `glm53-tp4-cache → /cache`.

---

## 5. Correctness gate — before declaring it serving

Do **not** announce "up" on a `/v1/models` 200 or a `docker ps` "Up". Run all
three checks (`scripts/gate.sh` automates them) and quote the evidence:

1. **Long-context needle (~150K prefill).** Bury a fact in ~150K tokens of filler
   and ask for it back; it must be retrieved coherently. This proves long-context
   attention *across the ring*, not just a short-prompt reply.
2. **Tool-call.** A request that forces a tool call; the response must contain a
   properly `glm47`-parsed tool call.
3. **Warm decode.** One throwaway turn to fill the prefix cache, then measure.
   The current controlled run reaches **~70–76 t/s** completed code decode and
   **~2,276 t/s** cold 64K prefill. Cold first turns decode slowly with `cached=0` — that is an empty
   prefix cache, not a regression.

Reference point: this is roughly the **bottom commercial GLM-5.3 tier**. Matching
that on hardware you own is the win; do not compare it to smaller/faster models
in a different tier.

---

## 6. Consuming the endpoint (client note)

Point any OpenAI-compatible client at `http://<head-node>:8000/v1`, model id
`glm-5.3-flash`. The context window is 262,144 and reasoning defaults to `max`.
Send `chat_template_kwargs.reasoning_effort` as `low`, `high`, or `max`; the
old `enable_thinking` key is not read by the official GLM-5.3 template. The
launcher pins the corrected upstream template rather than trusting whichever
copy happened to ship inside a quantised checkpoint.

### The output-cap trap (worth knowing if you use opencode)

`opencode` issue **#29363** hardcodes `maxOutputTokens = min(limit.output,
32000)` and in practice caps at **16,000**. GLM-5.3 in thinking mode can spend
that entire budget inside `<think>`, so the deliverable never lands — the turn
burns tokens and returns nothing. Raising `limit.output` in the client config
does **not** lift it. The working fix is an environment variable in the shell
that launches opencode:

```bash
export OPENCODE_EXPERIMENTAL_OUTPUT_TOKEN_MAX=128000
```

With it, GLM finishes thinking *and* emits the artifact. Bake this into your
opencode launch profile so a fresh session cannot silently regress.

A belt-and-braces alternative that does not depend on the client: have whatever
sits in front of the model inject a `max_tokens` floor on every request, so
clients get an adequate budget regardless of their own settings.

---

## 7. Teardown & restore

**Teardown** (e.g. to free the nodes for other jobs):

```bash
for host in NODE0 NODE1 NODE2 NODE3; do ssh you@$host 'docker rm -f glm53_tp4'; done
```

Recreating **one** rank breaks the torch.distributed group — always cycle all
four together.

**Restore:** §3 (`fabric-setup.sh` — mandatory after any reboot or docker churn)
→ §4 (launch 3, 2, 1, 0) → §5 (gate).

See [`gotchas.md`](gotchas.md) for the failure modes you will eventually hit.
