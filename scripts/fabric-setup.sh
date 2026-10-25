#!/usr/bin/env bash
# Re-apply the switchless 4-node RoCE ring fabric.
#
# Run from your OPERATOR box (any machine that can SSH to all four nodes).
# It SSHes to each node and applies: NIC unmanage, MTU 9000, ring addressing,
# IP forwarding, and DOCKER-USER accept rules for the fabric interfaces.
#
# RUN THIS after EVERY reboot and after ANY docker up/down churn — the ring
# addressing, MTU, and DOCKER-USER chain are runtime-only and get wiped.
#
# ─────────────────────────────────────────────────────────────────────────────
# EDIT THESE FOR YOUR SITE  (all IPs are EXAMPLES in the private 10.x range)
# ─────────────────────────────────────────────────────────────────────────────

# SSH user on the nodes.
SSH_USER="you"

# Management IPs of the four nodes (rank order). Used only to SSH in.
# >>> set these to YOUR four node management IPs <<<
NODE0_IP="10.0.0.1"     # rank 0 / head
NODE1_IP="10.0.0.2"     # rank 1
NODE2_IP="10.0.0.3"     # rank 2
NODE3_IP="10.0.0.4"     # rank 3

# RoCE interface names on the nodes (same on every node for the DGX Spark).
# F1 = pair rail, F0 = cross rail. Adjust for your NICs.
F1_IF="enp1s0f1np1"     # pair edge
F0_IF="enp1s0f0np0"     # cross edge
F1_HCA="rocep1s0f1"
F0_HCA="rocep1s0f0"
GID_INDEX="${GID_INDEX:-3}"

# Ring addressing template. Each ring edge is a point-to-point /24 shared by two
# adjacent nodes. See docs/fabric.md for the diagram. Format: <addr-without-mask>
# (a /24 is applied). Convention: last octet = rank + 1.
#
#   pair edge node0<->node1 : NODE0_F1 / NODE1_F1  (subnet 10.10.10.0/24)
#   cross edge node1<->node2: NODE1_F0 / NODE2_F0  (subnet 10.10.20.0/24)
#   pair edge node2<->node3 : NODE2_F1 / NODE3_F1  (subnet 10.10.30.0/24)
#   cross edge node3<->node0: NODE3_F0 / NODE0_F0  (subnet 10.10.40.0/24)
#
# >>> set these to YOUR fabric scheme (any private range) <<<
NODE0_F1="10.10.10.1"; NODE0_F0="10.10.40.1"
NODE1_F1="10.10.10.2"; NODE1_F0="10.10.20.2"
NODE2_F1="10.10.30.3"; NODE2_F0="10.10.20.3"
NODE3_F1="10.10.30.4"; NODE3_F0="10.10.40.4"

# ─────────────────────────────────────────────────────────────────────────────
# FIXED LOGIC — MTU 9000 is mandatory (1500 = ~2.7x slower, silent). See docs.
# ─────────────────────────────────────────────────────────────────────────────
set -e

# Optional site overrides. Copy scripts/fabric.env.example to
# scripts/fabric.env and edit it there instead of touching the placeholders
# above. The file is gitignored because it contains private endpoints.
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
if [ -f "$SCRIPT_DIR/fabric.env" ]; then
  # shellcheck source=/dev/null
  source "$SCRIPT_DIR/fabric.env"
fi

# Point-to-point edges to jumbo-ping: "<source management IP> <peer fabric IP>".
# Sites with a different physical ring order must override this array in
# scripts/fabric.env.
if ! declare -p JUMBO_EDGES >/dev/null 2>&1; then
  JUMBO_EDGES=(
    "$NODE0_IP $NODE1_F1"
    "$NODE1_IP $NODE2_F0"
    "$NODE2_IP $NODE3_F1"
    "$NODE3_IP $NODE0_F0"
  )
fi

gid_for_ip() { # print the IPv4-mapped RoCE GID for an IPv4 address
  local a b c d
  IFS=. read -r a b c d <<<"$1"
  printf '0000:0000:0000:0000:0000:ffff:%02x%02x:%02x%02x' \
    "$a" "$b" "$c" "$d"
}

cfg() { # $1=mgmt_ip  $2=f1_addr (pair)  $3=f0_addr (cross)
  ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=12 \
    "$SSH_USER@$1" "
      set -e
      # Stop NetworkManager fighting us for these interfaces.
      for d in $F0_IF $F1_IF; do sudo -n nmcli device set \$d managed no 2>/dev/null || true; done
      # Disable IPv6 on the rails. A privacy/stable IPv6 link-local address adds
      # extra GID slots, which pushes the IPv4 RoCE-v2 GID from index 3 to 5 and
      # makes NCCL pick the wrong GID. With IPv6 off, index 3 is the IPv4 GID.
      for d in $F0_IF $F1_IF; do sudo -n sysctl -qw net.ipv6.conf.\$d.disable_ipv6=1; done
      # Flush stale addresses, set MTU 9000, bring the rails up.
      sudo -n ip addr flush dev $F1_IF 2>/dev/null || true
      sudo -n ip addr flush dev $F0_IF 2>/dev/null || true
      sudo -n ip link set $F1_IF mtu 9000 up
      sudo -n ip link set $F0_IF mtu 9000 up
      # Apply this node's ring addresses.
      sudo -n ip addr add $2/24 dev $F1_IF
      sudo -n ip addr add $3/24 dev $F0_IF
      # Forwarding + DOCKER-USER accept for the fabric interfaces (docker churn
      # drops these — that is why this script must run after any docker up/down).
      sudo -n sysctl -qw net.ipv4.ip_forward=1 || true
      for IF in $F0_IF $F1_IF; do
        sudo -n iptables -C DOCKER-USER -i \$IF -j ACCEPT 2>/dev/null || sudo -n iptables -I DOCKER-USER -i \$IF -j ACCEPT
        sudo -n iptables -C DOCKER-USER -o \$IF -j ACCEPT 2>/dev/null || sudo -n iptables -I DOCKER-USER -o \$IF -j ACCEPT
      done
      # OPTIONAL: if any node must reach a NON-adjacent subnet at L3, add a static
      # route here via the appropriate neighbour, e.g.:
      #   sudo -n ip route replace 10.10.30.0/24 via <neighbour-fabric-ip> dev $F1_IF
      echo \"  \$(hostname): $F1_IF=$2  $F0_IF=$3  mtu=9000\"
    "
}

quiescent() { # $1=mgmt_ip
  ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=12 \
    "$SSH_USER@$1" "
      set -eu
      test -e /sys/class/net/$F1_IF
      test -e /sys/class/net/$F0_IF
      test -d /sys/class/infiniband/$F1_HCA
      test -d /sys/class/infiniband/$F0_HCA
      sudo -n ip link show >/dev/null 2>&1 || {
        echo \"\$(hostname): passwordless sudo is required for SSH_USER=$SSH_USER\" >&2
        echo 'install a sudoers drop-in for ip/nmcli/sysctl/iptables on every node' >&2
        exit 1
      }
      pids=\$(nvidia-smi --query-compute-apps=pid --format=csv,noheader,nounits 2>/dev/null || true)
      [ -z \"\$pids\" ] || {
        echo \"\$(hostname): GPU compute is active (PIDs: \$pids); stop every appliance before changing fabric mode\" >&2
        exit 1
      }
      echo \"  \$(hostname): reachable, expected rails present, GPU idle\"
    "
}

verify() { # $1=mgmt_ip  $2=f1_addr  $3=f0_addr
  local f1_gid f0_gid
  f1_gid=$(gid_for_ip "$2")
  f0_gid=$(gid_for_ip "$3")
  ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=12 \
    "$SSH_USER@$1" "
      set -eu
      check_rail() {
        hca=\$1; dev=\$2; expected=\$3; expected_gid=\$4
        base=/sys/class/infiniband/\$hca/ports/1
        state=\$(cat \"\$base/state\")
        type=\$(cat \"\$base/gid_attrs/types/$GID_INDEX\" 2>/dev/null || true)
        gid=\$(cat \"\$base/gids/$GID_INDEX\" 2>/dev/null || true)
        ndev=\$(cat \"\$base/gid_attrs/ndevs/$GID_INDEX\" 2>/dev/null || true)
        mtu=\$(cat /sys/class/net/\$dev/mtu)
        addr=\$(ip -4 -o address show dev \"\$dev\" | awk '{print \$4}')
        [ \"\$state\" = '4: ACTIVE' ] || { echo \"\$hca is not ACTIVE\" >&2; exit 1; }
        [ \"\$type\" = 'RoCE v2' ] || { echo \"\$hca GID $GID_INDEX is not RoCE v2\" >&2; exit 1; }
        [ \"\$gid\" != '0000:0000:0000:0000:0000:0000:0000:0000' ] || {
          echo \"\$hca GID $GID_INDEX is empty after the mode change\" >&2
          echo 'Stop every GPU appliance, reboot this node, reapply the fabric, and rerun this check.' >&2
          exit 1
        }
        [ \"\$gid\" = \"\$expected_gid\" ] || {
          echo \"\$hca GID $GID_INDEX is \$gid, expected \$expected_gid for \$expected\" >&2
          echo 'IPv6 is adding GID slots. Re-run the fabric script so it disables IPv6, or reboot and retry.' >&2
          exit 1
        }
        [ \"\$ndev\" = \"\$dev\" ] || { echo \"\$hca GID maps to \$ndev, expected \$dev\" >&2; exit 1; }
        [ \"\$mtu\" = 9000 ] || { echo \"\$dev MTU is \$mtu, expected 9000\" >&2; exit 1; }
        [ \"\$addr\" = \"\$expected/24\" ] || { echo \"\$dev address is \$addr, expected \$expected/24\" >&2; exit 1; }
      }
      check_rail $F1_HCA $F1_IF $2 $f1_gid
      check_rail $F0_HCA $F0_IF $3 $f0_gid
      echo \"  \$(hostname): both rails clean (RoCE v2 GID $GID_INDEX, MTU 9000)\"
    "
}

jumbo() { # $1=source management IP  $2=direct-neighbour fabric IP
  ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=12 \
    "$SSH_USER@$1" "ping -q -M do -s 8972 -c 2 -W 2 $2 >/dev/null"
}

echo "clean-room check: all four ranks must be reachable and GPU-idle..."
quiescent "$NODE0_IP"
quiescent "$NODE1_IP"
quiescent "$NODE2_IP"
quiescent "$NODE3_IP"

echo "re-applying switchless ring addressing (MTU 9000)..."
cfg "$NODE0_IP" "$NODE0_F1" "$NODE0_F0"
cfg "$NODE1_IP" "$NODE1_F1" "$NODE1_F0"
cfg "$NODE2_IP" "$NODE2_F1" "$NODE2_F0"
cfg "$NODE3_IP" "$NODE3_F1" "$NODE3_F0"

echo "verifying both rails on every node..."
verify "$NODE0_IP" "$NODE0_F1" "$NODE0_F0"
verify "$NODE1_IP" "$NODE1_F1" "$NODE1_F0"
verify "$NODE2_IP" "$NODE2_F1" "$NODE2_F0"
verify "$NODE3_IP" "$NODE3_F1" "$NODE3_F0"

echo "verifying all four point-to-point edges with jumbo packets..."
for edge in "${JUMBO_EDGES[@]}"; do
  read -r src dst <<<"$edge"
  jumbo "$src" "$dst"
done

echo "fabric pre-flight passed: 4 nodes, 8 GIDs, 8 MTUs, and 4 jumbo edges."
echo "the real proof is a completed NCCL collective — run scripts/gate.sh."
