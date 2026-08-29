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
| `$HOME/glm53-flash-nvfp4/` | GLM-5.3-Flash NVFP4 checkpoint (`config.json` + ~120 shards, ~182 GiB) | `LibertAIDAI/GLM-5.3-Flash-NVFP4` | ✅ weights |
| `$HOME/glm53-dflash2-draft/model.safetensors` | DFlash2 speculative drafter | `incoai/GLM-5.3-Flash-DFlash2` | ✅ drafter |
| `$HOME/nccl-patched/libnccl.so.2` | Patched **NCCL 2.30.7** (skip-tree-connect; works with glibc 2.39) | you provide — see §2 | ✅ patch |
| `$HOME/glm53-tp4-cache/` | JIT / torch.compile / tilelang cache (created on first run) | — | — |
| image `radixark/vllm-glm53-flash:dflash2` | vLLM + GLM-5.3 + DFlash2, built for `sm_121` | `docker pull radixark/vllm-glm53-flash:dflash2` | ✅ image |

Fetch the weights and drafter with your own HuggingFace token, held in your own
secret store — never inline a token on a command line or commit one.

```bash
# example, on each node
huggingface-cli download LibertAIDAI/GLM-5.3-Flash-NVFP4 \
  --local-dir "$HOME/glm53-flash-nvfp4"
huggingface-cli download incoai/GLM-5.3-Flash-DFlash2 \
  --local-dir "$HOME/glm53-dflash2-draft"
docker pull radixark/vllm-glm53-flash:dflash2
```

The launcher (`scripts/rank-launcher.sh`) asserts the three staged files exist
before it starts a container.

---

## 2. Patched NCCL 2.30.7 (skip-tree-connect)

The switchless ring needs a **patched NCCL 2.30.7** built with a
*skip-tree-connect* change, `LD_PRELOAD`-ed into the container ahead of the
stock library. The stock tree-connect step assumes a switched fabric can form
the NCCL tree; on a bare point-to-point ring that step wedges, so it is skipped
and the ring algorithm is used directly.

- Build or obtain `libnccl.so.2` for NCCL **2.30.7** with the skip-tree-connect
  patch, compatible with your container's glibc (glibc 2.39 is fine).
- Place it at `$HOME/nccl-patched/libnccl.so.2` on every node.
- The launcher mounts it read-only at `/opt/patched-nccl` and sets both
  `LD_PRELOAD` and `VLLM_NCCL_SO_PATH` to it, plus `NCCL_SKIP_TREE_CONNECT=1`.

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

---

## 4. Launch — workers first, head last

Order matters. Bring up ranks **3, 2, 1 headless**, then **0** (which opens the
API). From your operator box:

```bash
./scripts/fabric-setup.sh                                   # after any reboot / docker churn
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
  --gpu-memory-utilization 0.85 --max-model-len 262144
  --max-num-seqs 6 --block-size 2304 --moe-backend marlin
  --kv-cache-dtype fp8_e4m3 --kv-cache-memory 12884901888   # 12 GiB — see gotchas
  --speculative-config '{"method":"dflash","model":"/draft","num_speculative_tokens":7}'
  --tool-call-parser glm47 --enable-auto-tool-choice --reasoning-parser glm45
  --default-chat-template-kwargs '{"enable_thinking": true}'
  --distributed-executor-backend mp
  <--host 0.0.0.0 --port 8000  for rank 0  |  --headless  for ranks 1–3>
```

Notes on the choices:

- **`--moe-backend marlin`** — the MoE kernel that performs on NVFP4 / `sm_121`.
- **`--kv-cache-dtype fp8_e4m3` + `--kv-cache-memory 12 GiB`** — the KV pool is
  capped at 12 GiB on purpose. Chasing it higher risks an OOM **hard-hang** on a
  node (not a clean error). See [`gotchas.md`](gotchas.md).
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
NCCL_SOCKET_IFNAME=<mgmt-if>  GLOO_SOCKET_IFNAME=<mgmt-if>  VLLM_HOST_IP=<this node mgmt ip>
NCCL_NET=IB  NCCL_IB_DISABLE=0  NCCL_IB_HCA=<pair-hca>,<cross-hca>    # both rails
NCCL_IB_GID_INDEX=3  NCCL_IB_SUBNET_PREFIX_LEN=24  NCCL_IB_SUBNET_AWARE_ROUTING=1
NCCL_ALGO=Ring  NCCL_PROTO=LL,LL128,Simple  NCCL_P2P_LEVEL=SYS
NCCL_MIN_NCHANNELS=4  NCCL_MAX_NCHANNELS=4  NCCL_CROSS_NIC=1  NCCL_CUMEM_ENABLE=0
NCCL_IGNORE_CPU_AFFINITY=1
VLLM_ONE_GPU_PER_NODE=1  PYTORCH_CUDA_ALLOC_CONF=expandable_segments:True
TORCH_CUDA_ARCH_LIST=12.1a  FLASHINFER_CUDA_ARCH_LIST=12.1a
HF_HUB_OFFLINE=1  TRANSFORMERS_OFFLINE=1
```

`NCCL_ALGO=Ring` and the fixed channel count reflect the switchless ring; the
subnet-aware routing plus `NCCL_IB_SUBNET_PREFIX_LEN=24` let NCCL pick the right
rail per peer subnet.

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

1. **Long-context needle (~30K prefill).** Bury a fact in ~30K tokens of filler
   and ask for it back; it must be retrieved coherently. This proves long-context
   attention *across the ring*, not just a short-prompt reply.
2. **Tool-call.** A request that forces a tool call; the response must contain a
   properly `glm47`-parsed tool call.
3. **Warm decode.** One throwaway turn to fill the prefix cache, then measure.
   Expect **~48–51 t/s** code decode (up to ~72 warm), prefill **~1,800 t/s at
   32–64K**. Cold first turns decode slowly with `cached=0` — that is an empty
   prefix cache, not a regression.

Reference point: this is roughly the **bottom commercial GLM-5.3 tier**. Matching
that on hardware you own is the win; do not compare it to smaller/faster models
in a different tier.

---

## 6. Consuming the endpoint (client note)

Point any OpenAI-compatible client at `http://<head-node>:8000/v1`, model id
`glm-5.3-flash`. The context window is 262,144 and thinking is on by default
(binary thinking via `chat_template_kwargs.enable_thinking`, glm45 reasoning
parser).

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
