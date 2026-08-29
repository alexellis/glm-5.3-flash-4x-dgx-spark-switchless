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

cfg() { # $1=mgmt_ip  $2=f1_addr (pair)  $3=f0_addr (cross)
  ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=12 \
    "$SSH_USER@$1" "
      set -e
      # Stop NetworkManager fighting us for these interfaces.
      for d in $F0_IF $F1_IF; do sudo nmcli device set \$d managed no 2>/dev/null || true; done
      # Flush stale addresses, set MTU 9000, bring the rails up.
      sudo ip addr flush dev $F1_IF 2>/dev/null || true
      sudo ip addr flush dev $F0_IF 2>/dev/null || true
      sudo ip link set $F1_IF mtu 9000 up
      sudo ip link set $F0_IF mtu 9000 up
      # Apply this node's ring addresses.
      sudo ip addr add $2/24 dev $F1_IF
      sudo ip addr add $3/24 dev $F0_IF
      # Forwarding + DOCKER-USER accept for the fabric interfaces (docker churn
      # drops these — that is why this script must run after any docker up/down).
      sudo sysctl -qw net.ipv4.ip_forward=1 || true
      for IF in $F0_IF $F1_IF; do
        sudo iptables -C DOCKER-USER -i \$IF -j ACCEPT 2>/dev/null || sudo iptables -I DOCKER-USER -i \$IF -j ACCEPT
        sudo iptables -C DOCKER-USER -o \$IF -j ACCEPT 2>/dev/null || sudo iptables -I DOCKER-USER -o \$IF -j ACCEPT
      done
      # OPTIONAL: if any node must reach a NON-adjacent subnet at L3, add a static
      # route here via the appropriate neighbour, e.g.:
      #   sudo ip route replace 10.10.30.0/24 via <neighbour-fabric-ip> dev $F1_IF
      echo \"  \$(hostname): $F1_IF=$2  $F0_IF=$3  mtu=9000\"
    "
}

echo "re-applying switchless ring addressing (MTU 9000)..."
cfg "$NODE0_IP" "$NODE0_F1" "$NODE0_F0"
cfg "$NODE1_IP" "$NODE1_F1" "$NODE1_F0"
cfg "$NODE2_IP" "$NODE2_F1" "$NODE2_F0"
cfg "$NODE3_IP" "$NODE3_F1" "$NODE3_F0"

echo "fabric re-applied."
echo "verify a link with a jumbo ping (necessary, NOT sufficient):"
echo "  ssh $SSH_USER@$NODE0_IP 'ping -M do -s 8972 -c3 $NODE1_F1'"
echo "the real proof is a completed NCCL collective — run scripts/gate.sh."
