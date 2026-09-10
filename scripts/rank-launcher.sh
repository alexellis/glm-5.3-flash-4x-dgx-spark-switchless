#!/usr/bin/env bash
# Launch one rank of GLM-5.3-Flash NVFP4 TP4 + DFlash2 on a switchless RoCE ring.
#
# Run the SAME script on every node, passing that node's rank (0..3).
# Order: workers (ranks 3,2,1) headless first, THEN the head (rank 0) which
# opens the OpenAI-compatible API on :8000.
#
# Usage:  ./rank-launcher.sh <rank 0..3>
#
# ─────────────────────────────────────────────────────────────────────────────
# EDIT THESE FOR YOUR SITE  (everything below the marker is the fixed recipe)
# ─────────────────────────────────────────────────────────────────────────────

# Management IP of the HEAD node (rank 0). Torch rendezvous + NCCL bootstrap
# ride the management LAN and use this as the master address.
# >>> set this to YOUR head node's management IP <<<
MASTER="10.0.0.1"

# Management interface on THIS node (the 1 GbE LAN used for bootstrap only).
# Default matches the DGX Spark; adjust for your NIC.
# >>> set this to YOUR management interface name <<<
MGMT_IF="enP7s7"

# RoCE HCA devices, cross rail then pair rail. NCCL uses BOTH.
# Defaults match the DGX Spark; adjust for your NICs.
# >>> set these to YOUR two RoCE devices <<<
IB_HCA="rocep1s0f0,rocep1s0f1"

# IPv4 RoCE-v2 GID slot used by NCCL. A fabric-mode change can leave an empty
# slot behind until the NIC is reinitialised, so this is verified below before
# a container is allowed to start.
GID_INDEX="${GID_INDEX:-3}"

# Master port for the torch rendezvous (must be open between nodes on the mgmt LAN).
MPORT=29520
# API port the head node (rank 0) listens on.
PORT=8000

# Local staging paths (see docs/recipe.md §1). $HOME-relative; keep consistent
# across all nodes.
MODEL_DIR="$HOME/glm53-flash-nvfp4-redhat" # RedHatAI/GLM-5.3-Flash-NVFP4
DRAFT_DIR="$HOME/glm53-dflash2-draft"    # incoai/GLM-5.3-Flash-DFlash2
NCCL_DIR="$HOME/nccl-patched"            # patched NCCL 2.30.7 (libnccl.so.2)
CACHE_DIR="$HOME/glm53-tp4-cache"        # JIT / compile cache (created on first run)
REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
CHAT_TEMPLATE="$REPO_ROOT/templates/chat_template.jinja"

# ─────────────────────────────────────────────────────────────────────────────
# FIXED RECIPE — do not change unless you know exactly why (see docs/recipe.md)
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail
R="${1:?usage: rank-launcher.sh <rank 0..3>}"
case "$R" in 0|1|2|3) ;; *) echo "rank must be 0, 1, 2, or 3" >&2; exit 2 ;; esac
# Public image (pull works without auth). Pin by digest for reproducibility:
#   ghcr.io/tonyd2wild/vllm-glm53-flash@sha256:4def0ef644cb2e9814136dcffd5e385e21bc594f48f3b292234051904abe85a6
IMAGE="ghcr.io/tonyd2wild/vllm-glm53-flash:sm121-v11-dflash2"
NAME="glm53_tp4"

die() {
  printf 'pre-flight failed: %s\n' "$*" >&2
  exit 1
}

check_hca() {
  local hca=$1
  local port=${2:-1}
  local base="/sys/class/infiniband/${hca}/ports/${port}"
  local gid type ndev mtu state

  [[ -d "$base" ]] || die "missing RDMA device ${hca}:${port}"
  state=$(<"$base/state")
  [[ "$state" == '4: ACTIVE' ]] || die "${hca}:${port} is not ACTIVE (${state})"

  gid=$(cat "$base/gids/$GID_INDEX" 2>/dev/null || true)
  type=$(cat "$base/gid_attrs/types/$GID_INDEX" 2>/dev/null || true)
  ndev=$(cat "$base/gid_attrs/ndevs/$GID_INDEX" 2>/dev/null || true)
  [[ "$type" == 'RoCE v2' ]] || die \
    "${hca}:${port} GID index ${GID_INDEX} is '${type:-empty}', not RoCE v2"
  [[ -n "$gid" && "$gid" != '0000:0000:0000:0000:0000:0000:0000:0000' ]] || die \
    "${hca}:${port} GID index ${GID_INDEX} is empty after the fabric change; persist the desired netplan, reboot this node, then rerun"
  [[ -n "$ndev" && -e "/sys/class/net/$ndev" ]] || die \
    "${hca}:${port} GID index ${GID_INDEX} has no network device"
  mtu=$(<"/sys/class/net/$ndev/mtu")
  [[ "$mtu" == 9000 ]] || die "${ndev} MTU is ${mtu}, expected 9000"
  ip -4 -o address show dev "$ndev" | grep -q 'inet ' || die \
    "${ndev} has no IPv4 fabric address"

  printf '  %-12s net=%-14s gid=%s mtu=%s state=ACTIVE\n' \
    "${hca}:${port}" "$ndev" "$GID_INDEX" "$mtu"
}

[[ "$R" =~ ^[0-3]$ ]] || die "rank must be 0, 1, 2, or 3"

# This node's management IP, discovered via the route toward the head node.
MIP=$(ip -4 route get "$MASTER" 2>/dev/null | grep -oE 'src [0-9.]+' | awk '{print $2}')
: "${MIP:?could not determine node management IP}"
NCCL_DEBUG="${NCCL_DEBUG:-WARN}"
NCCL_DEBUG_SUBSYS="${NCCL_DEBUG_SUBSYS:-INIT,NET}"

# Pre-flight: refuse a slow, stale, or competing appliance state.
test -f "$MODEL_DIR/config.json"        || { echo "missing $MODEL_DIR/config.json" >&2; exit 1; }
test -f "$DRAFT_DIR/model.safetensors"  || { echo "missing $DRAFT_DIR/model.safetensors" >&2; exit 1; }
test -f "$NCCL_DIR/libnccl.so.2"        || { echo "missing $NCCL_DIR/libnccl.so.2" >&2; exit 1; }
test -f "$CHAT_TEMPLATE"                || { echo "missing $CHAT_TEMPLATE" >&2; exit 1; }
mkdir -p "$CACHE_DIR"

[[ -n "$MIP" ]] || die "could not discover this node's management IP"
if nvidia-smi --query-compute-apps=pid --format=csv,noheader,nounits 2>/dev/null \
    | grep -Eq '[0-9]'; then
  die "another process is using the GPU; stop the other appliance first"
fi

printf 'GLM TP4 local pre-flight (rank %s)\n' "$R"
IFS=',' read -r -a hcas <<<"$IB_HCA"
[[ ${#hcas[@]} -eq 2 ]] || die "IB_HCA must name exactly two RoCE devices"
for hca_spec in "${hcas[@]}"; do
  hca=${hca_spec%%:*}
  port=1
  [[ "$hca_spec" == *:* ]] && port=${hca_spec#*:}
  check_hca "$hca" "$port"
done
if [[ -f "$NCCL_DIR/SHA256SUMS" ]]; then
  (cd "$NCCL_DIR" && sha256sum --check --ignore-missing SHA256SUMS) \
    || die "published NCCL asset failed its embedded checksum"
fi
printf '%s  %s\n' \
  '0c4099f3382d6c92700dfb99725025360966fd73032f0ecf32377c0d9e6309c5' \
  "$CHAT_TEMPLATE" | sha256sum --check --status - \
  || die "official GLM chat template does not match the pinned revision"
printf '  model, drafter, NCCL, fabric, and GPU state: clean\n'
docker rm -f "$NAME" 2>/dev/null || true

if [ "$R" = "0" ]; then
  TAIL=(--host 0.0.0.0 --port "$PORT")
else
  TAIL=(--headless)
fi

docker run -d --name "$NAME" --restart no \
  --cap-add IPC_LOCK --ulimit memlock=-1:-1 \
  --network host --ipc host --shm-size 32g --gpus all \
  --device /dev/infiniband:/dev/infiniband \
  -v "$MODEL_DIR:/model:ro" \
  -v "$DRAFT_DIR:/draft:ro" \
  -v "$NCCL_DIR:/opt/patched-nccl:ro" \
  -v "$CACHE_DIR:/cache" \
  -v "$CHAT_TEMPLATE:/opt/glm53/chat_template.jinja:ro" \
  -e LD_PRELOAD=/opt/patched-nccl/libnccl.so.2 -e VLLM_NCCL_SO_PATH=/opt/patched-nccl/libnccl.so.2 \
  -e NCCL_SKIP_TREE_CONNECT=1 -e NCCL_SWITCHLESS_RING_ONLY=1 \
  -e NCCL_SOCKET_IFNAME="$MGMT_IF" -e GLOO_SOCKET_IFNAME="$MGMT_IF" -e VLLM_HOST_IP="$MIP" \
  -e NCCL_NET=IB -e NCCL_IB_DISABLE=0 -e NCCL_IB_HCA="$IB_HCA" \
  -e NCCL_IB_GID_INDEX="$GID_INDEX" -e NCCL_IB_SUBNET_PREFIX_LEN=24 -e NCCL_IB_SUBNET_AWARE_ROUTING=1 \
  -e NCCL_IB_MERGE_NICS=0 \
  -e NCCL_ALGO=Ring -e NCCL_PROTO=LL,LL128,Simple -e NCCL_P2P_LEVEL=SYS \
  -e NCCL_MIN_NCHANNELS=4 -e NCCL_MAX_NCHANNELS=4 -e NCCL_CROSS_NIC=1 -e NCCL_CUMEM_ENABLE=0 \
  -e NCCL_IGNORE_CPU_AFFINITY=1 -e NCCL_DEBUG="$NCCL_DEBUG" -e NCCL_DEBUG_SUBSYS="$NCCL_DEBUG_SUBSYS" \
  -e VLLM_ONE_GPU_PER_NODE=1 -e PYTORCH_CUDA_ALLOC_CONF=expandable_segments:True \
  -e HF_HUB_OFFLINE=1 -e TRANSFORMERS_OFFLINE=1 -e PYTHONUNBUFFERED=1 \
  -e HF_HOME=/cache/hf -e XDG_CACHE_HOME=/cache -e VLLM_CACHE_ROOT=/cache/vllm \
  -e NODE_RANK="$R" -e MASTER_ADDR="$MASTER" \
  -e TORCH_CUDA_ARCH_LIST=12.1a -e FLASHINFER_CUDA_ARCH_LIST=12.1a \
  "$IMAGE" \
    /model \
    --served-model-name glm-5.3-flash --trust-remote-code \
    --tensor-parallel-size 4 --nnodes 4 --node-rank "$R" \
    --master-addr "$MASTER" --master-port "$MPORT" \
    --gpu-memory-utilization 0.82 --max-model-len 262144 \
    --max-num-seqs 6 --max-num-batched-tokens 8192 --block-size 2304 --moe-backend marlin \
    --limit-mm-per-prompt '{"image":16}' \
    --kv-cache-dtype auto --kv-cache-memory 12884901888 \
    --speculative-config '{"method":"dflash","model":"/draft","num_speculative_tokens":7}' \
    --tool-call-parser glm47 --enable-auto-tool-choice --reasoning-parser glm45 \
    --chat-template /opt/glm53/chat_template.jinja \
    --default-chat-template-kwargs '{"reasoning_effort":"max"}' \
    --distributed-executor-backend mp \
    "${TAIL[@]}"

echo "launched $NAME rank=$R mgmt=$MIP"
sleep 2
docker ps --format '{{.Names}} {{.Status}}' | grep "$NAME" \
  || { echo "$NAME exited; run: docker logs $NAME" >&2; exit 1; }
