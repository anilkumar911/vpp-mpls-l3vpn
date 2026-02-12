#!/bin/bash
# ================================================================
# VPP MPLS L3VPN Lab — Phase 2: MP-BGP with FRR
# ================================================================
#
# This script configures VPP data plane + sets up Linux interfaces
# so that FRR (running in the same container) can:
#   - Establish eBGP sessions with CEs
#   - Establish MP-iBGP VPNv4 session between PE1 and PE2
#
# What remains static:
#   - Transport labels on LSR1/LSR2 (swap operations)
#   - VPN labels on PEs (static fallback alongside FRR)
#
# What MP-BGP automates:
#   - CE route learning via eBGP
#   - VPNv4 route exchange between PEs via MP-iBGP
#
# ================================================================

set -e

function vpp_exec() {
  docker exec -i "$1" vppctl "$2"
}

function linux_exec() {
  docker exec -i "$1" $2
}

# Sync VPP af-packet MAC with the Linux interface MAC
# VPP auto-generates 02:fe:* MACs, but ARP resolves to Linux's Docker-assigned MAC.
# This causes "l3 mac mismatch" drops. Fix: set VPP MAC = Linux MAC.
function sync_mac() {
  local container=$1
  local iface=$2
  local linux_mac=$(docker exec -i "$container" ip link show "$iface" 2>/dev/null | awk '/ether/ {print $2}')
  if [ -n "$linux_mac" ]; then
    vpp_exec "$container" "set interface mac address host-$iface $linux_mac" > /dev/null 2>&1 || true
  fi
}

# Find which ethX interface in a container has an IP in a given subnet
function get_iface() {
  local container=$1
  local prefix=$2
  docker exec -i "$container" ip -4 addr show | grep "$prefix" | sed -n 's/.*\(eth[0-9]\).*/\1/p' | head -1
}

# Wait for VPP to be ready in a container
function wait_for_vpp() {
  local container=$1
  echo -n "  Waiting for VPP in $container..."
  for i in $(seq 1 30); do
    if docker exec -i "$container" vppctl show version > /dev/null 2>&1; then
      echo " ready."
      return 0
    fi
    sleep 1
  done
  echo " TIMEOUT!"
  return 1
}

echo "============================================"
echo "  Phase 2: VPP + FRR (MP-BGP) Setup"
echo "============================================"
echo ""

echo "============================================"
echo "  Waiting for VPP to be ready"
echo "============================================"
for node in ce1 ce3 ce5 pe1 lsr1 lsr2 pe2 ce2 ce4 ce6; do
  wait_for_vpp "$node"
done

echo ""
echo "============================================"
echo "  Creating Host Interfaces"
echo "============================================"

echo "CE1..."
vpp_exec ce1 "create host-interface name eth0"
vpp_exec ce1 "create host-interface name eth1"

echo "CE3..."
vpp_exec ce3 "create host-interface name eth0"

echo "CE5..."
vpp_exec ce5 "create host-interface name eth0"

echo "PE1..."
vpp_exec pe1 "create host-interface name eth0"
vpp_exec pe1 "create host-interface name eth1"
vpp_exec pe1 "create host-interface name eth2"
vpp_exec pe1 "create host-interface name eth3"
vpp_exec pe1 "create host-interface name eth4"

echo "LSR1..."
vpp_exec lsr1 "create host-interface name eth0"
vpp_exec lsr1 "create host-interface name eth1"

echo "LSR2..."
vpp_exec lsr2 "create host-interface name eth0"
vpp_exec lsr2 "create host-interface name eth1"

echo "PE2..."
vpp_exec pe2 "create host-interface name eth0"
vpp_exec pe2 "create host-interface name eth1"
vpp_exec pe2 "create host-interface name eth2"
vpp_exec pe2 "create host-interface name eth3"
vpp_exec pe2 "create host-interface name eth4"

echo "CE2..."
vpp_exec ce2 "create host-interface name eth0"
vpp_exec ce2 "create host-interface name eth1"

echo "CE4..."
vpp_exec ce4 "create host-interface name eth0"

echo "CE6..."
vpp_exec ce6 "create host-interface name eth0"

echo ""
echo "============================================"
echo "  Syncing VPP MAC with Linux MAC"
echo "============================================"
echo "  (Fix af-packet l3 mac mismatch drops)"
for node in ce1 ce3 ce5 pe1 lsr1 lsr2 pe2 ce2 ce4 ce6; do
  for iface in eth0 eth1 eth2 eth3 eth4; do
    if docker exec -i "$node" ip link show "$iface" > /dev/null 2>&1; then
      sync_mac "$node" "$iface"
    fi
  done
  echo "  $node: MAC synced"
done

echo ""
echo "============================================"
echo "  Detecting Interface-to-Network Mapping"
echo "============================================"
echo "  (Docker assigns ethX non-deterministically)"

# PE1: 5 interfaces (4 data + 1 mgmt)
PE1_CE1=$(get_iface pe1 "100.64.1.")    # CE1-facing (VRF 10)
PE1_CORE=$(get_iface pe1 "100.64.2.")   # Core-facing (MPLS)
PE1_CE3=$(get_iface pe1 "100.64.6.")    # CE3-facing (VRF 20)
PE1_CE5=$(get_iface pe1 "100.64.8.")    # CE5-facing (VRF 30)
PE1_MGMT=$(get_iface pe1 "10.255.0.")   # Management (iBGP peering)
echo "  PE1: CE1=host-$PE1_CE1, Core=host-$PE1_CORE, CE3=host-$PE1_CE3, CE5=host-$PE1_CE5, Mgmt=$PE1_MGMT"

# CE1: 2 interfaces (PE-facing + LAN-facing)
CE1_PE=$(get_iface ce1 "100.64.1.")
CE1_LAN=$(get_iface ce1 "10.1.1.")
echo "  CE1: PE=host-$CE1_PE, LAN=host-$CE1_LAN"

# LSR1: 2 interfaces
LSR1_PE1=$(get_iface lsr1 "100.64.2.")
LSR1_LSR2=$(get_iface lsr1 "100.64.3.")
echo "  LSR1: PE1-side=host-$LSR1_PE1, LSR2-side=host-$LSR1_LSR2"

# LSR2: 2 interfaces
LSR2_LSR1=$(get_iface lsr2 "100.64.3.")
LSR2_PE2=$(get_iface lsr2 "100.64.4.")
echo "  LSR2: LSR1-side=host-$LSR2_LSR1, PE2-side=host-$LSR2_PE2"

# PE2: 5 interfaces (4 data + 1 mgmt)
PE2_CORE=$(get_iface pe2 "100.64.4.")
PE2_CE2=$(get_iface pe2 "100.64.5.")
PE2_CE4=$(get_iface pe2 "100.64.7.")
PE2_CE6=$(get_iface pe2 "100.64.9.")
PE2_MGMT=$(get_iface pe2 "10.255.0.")
echo "  PE2: Core=host-$PE2_CORE, CE2=host-$PE2_CE2, CE4=host-$PE2_CE4, CE6=host-$PE2_CE6, Mgmt=$PE2_MGMT"

# CE2: 2 interfaces (PE-facing + LAN-facing)
CE2_PE=$(get_iface ce2 "100.64.5.")
CE2_LAN=$(get_iface ce2 "10.1.2.")
echo "  CE2: PE=host-$CE2_PE, LAN=host-$CE2_LAN"

echo ""
echo "============================================"
echo "  Flushing Linux IPs (prevent MAC mismatch)"
echo "============================================"
echo "  (Skipping management interfaces on PEs)"
for node in ce1 ce3 ce5 pe1 lsr1 lsr2 pe2 ce2 ce4 ce6; do
  echo "  Flushing $node..."
  for iface in eth0 eth1 eth2 eth3 eth4; do
    # Skip the management interface on PEs (used for iBGP peering)
    if [[ "$node" == "pe1" && "$iface" == "$PE1_MGMT" ]]; then continue; fi
    if [[ "$node" == "pe2" && "$iface" == "$PE2_MGMT" ]]; then continue; fi
    docker exec -i "$node" ip addr flush dev "$iface" 2>/dev/null || true
  done
done

echo ""
echo "============================================"
echo "  Configuring CE1 (VRF 10, PE1 side)"
echo "============================================"
vpp_exec ce1 "set interface state host-$CE1_PE up"
vpp_exec ce1 "set interface ip address host-$CE1_PE 100.64.1.20/24"
vpp_exec ce1 "ip route add 0.0.0.0/0 via 100.64.1.10"
# LAN-side interface (toward host1)
vpp_exec ce1 "set interface state host-$CE1_LAN up"
vpp_exec ce1 "set interface ip address host-$CE1_LAN 10.1.1.1/24"
# Linux side for FRR eBGP peering
docker exec -i ce1 ip addr add 100.64.1.20/24 dev $CE1_PE 2>/dev/null || true
docker exec -i ce1 ip route add default via 100.64.1.10 2>/dev/null || true
# Linux side for LAN (so FRR can see connected 10.1.1.0/24)
docker exec -i ce1 ip addr add 10.1.1.1/24 dev $CE1_LAN 2>/dev/null || true

echo ""
echo "============================================"
echo "  Configuring CE3 (VRF 20, PE1 side)"
echo "============================================"
vpp_exec ce3 "set interface state host-eth0 up"
vpp_exec ce3 "set interface ip address host-eth0 100.64.6.20/24"
vpp_exec ce3 "ip route add 0.0.0.0/0 via 100.64.6.10"
docker exec -i ce3 ip addr add 100.64.6.20/24 dev eth0 2>/dev/null || true
docker exec -i ce3 ip route add default via 100.64.6.10 2>/dev/null || true

echo ""
echo "============================================"
echo "  Configuring CE5 (VRF 30, PE1 side)"
echo "============================================"
vpp_exec ce5 "set interface state host-eth0 up"
vpp_exec ce5 "set interface ip address host-eth0 100.64.6.20/24"
vpp_exec ce5 "ip route add 0.0.0.0/0 via 100.64.6.10"
docker exec -i ce5 ip addr add 100.64.6.20/24 dev eth0 2>/dev/null || true
docker exec -i ce5 ip route add default via 100.64.6.10 2>/dev/null || true

echo ""
echo "============================================"
echo "  Configuring CE2 (VRF 10, PE2 side)"
echo "============================================"
vpp_exec ce2 "set interface state host-$CE2_PE up"
vpp_exec ce2 "set interface ip address host-$CE2_PE 100.64.5.20/24"
vpp_exec ce2 "ip route add 0.0.0.0/0 via 100.64.5.10"
# LAN-side interface (toward host2)
vpp_exec ce2 "set interface state host-$CE2_LAN up"
vpp_exec ce2 "set interface ip address host-$CE2_LAN 10.1.2.1/24"
# Linux side for FRR eBGP peering
docker exec -i ce2 ip addr add 100.64.5.20/24 dev $CE2_PE 2>/dev/null || true
docker exec -i ce2 ip route add default via 100.64.5.10 2>/dev/null || true
# Linux side for LAN (so FRR can see connected 10.1.2.0/24)
docker exec -i ce2 ip addr add 10.1.2.1/24 dev $CE2_LAN 2>/dev/null || true

echo ""
echo "============================================"
echo "  Configuring CE4 (VRF 20, PE2 side)"
echo "============================================"
vpp_exec ce4 "set interface state host-eth0 up"
vpp_exec ce4 "set interface ip address host-eth0 100.64.7.20/24"
vpp_exec ce4 "ip route add 0.0.0.0/0 via 100.64.7.10"
docker exec -i ce4 ip addr add 100.64.7.20/24 dev eth0 2>/dev/null || true
docker exec -i ce4 ip route add default via 100.64.7.10 2>/dev/null || true

echo ""
echo "============================================"
echo "  Configuring CE6 (VRF 30, PE2 side)"
echo "============================================"
vpp_exec ce6 "set interface state host-eth0 up"
vpp_exec ce6 "set interface ip address host-eth0 100.64.7.20/24"
vpp_exec ce6 "ip route add 0.0.0.0/0 via 100.64.7.10"
docker exec -i ce6 ip addr add 100.64.7.20/24 dev eth0 2>/dev/null || true
docker exec -i ce6 ip route add default via 100.64.7.10 2>/dev/null || true

echo ""
echo "============================================"
echo "  Configuring PE1 (Provider Edge)"
echo "============================================"

# Bring up VPP interfaces (skip mgmt — that stays Linux-only for iBGP)
vpp_exec pe1 "set interface state host-$PE1_CE1 up"
vpp_exec pe1 "set interface state host-$PE1_CORE up"
vpp_exec pe1 "set interface state host-$PE1_CE3 up"
vpp_exec pe1 "set interface state host-$PE1_CE5 up"

# Create MPLS table and VRF tables
vpp_exec pe1 "mpls table add 0"
vpp_exec pe1 "ip table add 10"
vpp_exec pe1 "ip table add 20"
vpp_exec pe1 "ip table add 30"

# VRF 10: CE1-facing interface
vpp_exec pe1 "set interface ip table host-$PE1_CE1 10"
vpp_exec pe1 "set interface ip address host-$PE1_CE1 100.64.1.10/24"

# VRF 20: CE3-facing interface
vpp_exec pe1 "set interface ip table host-$PE1_CE3 20"
vpp_exec pe1 "set interface ip address host-$PE1_CE3 100.64.6.10/24"

# VRF 30: CE5-facing interface
vpp_exec pe1 "set interface ip table host-$PE1_CE5 30"
vpp_exec pe1 "set interface ip address host-$PE1_CE5 100.64.6.10/24"

# Core-facing interface (global table, MPLS enabled)
vpp_exec pe1 "set interface ip address host-$PE1_CORE 100.64.2.10/24"
vpp_exec pe1 "set interface mpls host-$PE1_CORE enable"

# Loopback for BGP router-id (VPP side)
vpp_exec pe1 "create loopback interface"
vpp_exec pe1 "set interface state loop0 up"
vpp_exec pe1 "set interface ip address loop0 10.255.0.1/32"

# --- Transport label processing (static) ---
vpp_exec pe1 "mpls local-label 402 non-eos via mpls-lookup-in-table 0"

# --- VPN label disposition (static fallback) ---
vpp_exec pe1 "mpls local-label 600 eos via ip4-lookup-in-table 10"
vpp_exec pe1 "mpls local-label 800 eos via ip4-lookup-in-table 20"
vpp_exec pe1 "mpls local-label 1000 eos via ip4-lookup-in-table 30"

# --- Forward path VPN routes (static) ---
# Remote routes via MPLS to PE2:
vpp_exec pe1 "ip route add 100.64.5.0/24 table 10 via 100.64.2.20 host-$PE1_CORE out-labels 100 500"
vpp_exec pe1 "ip route add 10.1.2.0/24 table 10 via 100.64.2.20 host-$PE1_CORE out-labels 100 500"
vpp_exec pe1 "ip route add 100.64.7.0/24 table 20 via 100.64.2.20 host-$PE1_CORE out-labels 100 700"
vpp_exec pe1 "ip route add 100.64.7.0/24 table 30 via 100.64.2.20 host-$PE1_CORE out-labels 100 900"
# Local CE-connected LAN routes (so PE1 can forward decapsulated MPLS traffic to CEs):
vpp_exec pe1 "ip route add 10.1.1.0/24 table 10 via 100.64.1.20 host-$PE1_CE1"

# --- Linux interfaces for FRR ---
docker exec -i pe1 ip addr add 100.64.1.10/24 dev "$PE1_CE1" 2>/dev/null || true
docker exec -i pe1 ip addr add 100.64.6.10/24 dev "$PE1_CE3" 2>/dev/null || true
docker exec -i pe1 ip addr add 100.64.6.10/24 dev "$PE1_CE5" 2>/dev/null || true
docker exec -i pe1 ip addr add 100.64.2.10/24 dev "$PE1_CORE" 2>/dev/null || true
# Mgmt interface already has 10.255.0.1 from Docker — no need to add

# Linux VRF devices for FRR per-VRF BGP instances
docker exec -i pe1 ip link add VRF10 type vrf table 10 2>/dev/null || true
docker exec -i pe1 ip link set VRF10 up 2>/dev/null || true
docker exec -i pe1 ip link set "$PE1_CE1" master VRF10 2>/dev/null || true

docker exec -i pe1 ip link add VRF20 type vrf table 20 2>/dev/null || true
docker exec -i pe1 ip link set VRF20 up 2>/dev/null || true
docker exec -i pe1 ip link set "$PE1_CE3" master VRF20 2>/dev/null || true

docker exec -i pe1 ip link add VRF30 type vrf table 30 2>/dev/null || true
docker exec -i pe1 ip link set VRF30 up 2>/dev/null || true
docker exec -i pe1 ip link set "$PE1_CE5" master VRF30 2>/dev/null || true

# Blackhole routes in Linux VRFs for remote CE LANs — prevents Linux kernel
# from generating ICMP unreachable for MPLS-forwarded traffic (af-packet
# means both VPP and Linux see every packet; VPP handles it via MPLS,
# Linux must silently drop to avoid confusing the source host)
docker exec -i pe1 ip route add blackhole 10.1.2.0/24 vrf VRF10 2>/dev/null || true

echo ""
echo "============================================"
echo "  Configuring LSR1 (Label Switch Router)"
echo "============================================"
vpp_exec lsr1 "set interface state host-$LSR1_PE1 up"
vpp_exec lsr1 "set interface state host-$LSR1_LSR2 up"
vpp_exec lsr1 "set interface ip address host-$LSR1_PE1 100.64.2.20/24"
vpp_exec lsr1 "set interface ip address host-$LSR1_LSR2 100.64.3.10/24"

vpp_exec lsr1 "mpls table add 0"
vpp_exec lsr1 "set interface mpls host-$LSR1_PE1 enable"
vpp_exec lsr1 "set interface mpls host-$LSR1_LSR2 enable"

# Forward: Swap 100 → 200
vpp_exec lsr1 "mpls local-label 100 non-eos via 100.64.3.20 host-$LSR1_LSR2 out-labels 200"
# Return: Swap 401 → 402
vpp_exec lsr1 "mpls local-label 401 non-eos via 100.64.2.10 host-$LSR1_PE1 out-labels 402"

# IP routes for PE loopback reachability (BGP next-hop)
vpp_exec lsr1 "ip route add 10.255.0.1/32 via 100.64.2.10"
vpp_exec lsr1 "ip route add 10.255.0.2/32 via 100.64.3.20"

# Linux IP addresses and routes for IP transit (PE-PE iBGP uses Linux TCP)
docker exec -i lsr1 ip addr add 100.64.2.20/24 dev "$LSR1_PE1" 2>/dev/null || true
docker exec -i lsr1 ip addr add 100.64.3.10/24 dev "$LSR1_LSR2" 2>/dev/null || true
docker exec -i lsr1 sysctl -w net.ipv4.ip_forward=1 > /dev/null 2>&1
docker exec -i lsr1 ip route add 10.255.0.1/32 via 100.64.2.10 2>/dev/null || true
docker exec -i lsr1 ip route add 10.255.0.2/32 via 100.64.3.20 2>/dev/null || true

echo ""
echo "============================================"
echo "  Configuring LSR2 (Label Switch Router)"
echo "============================================"
vpp_exec lsr2 "set interface state host-$LSR2_LSR1 up"
vpp_exec lsr2 "set interface state host-$LSR2_PE2 up"
vpp_exec lsr2 "set interface ip address host-$LSR2_LSR1 100.64.3.20/24"
vpp_exec lsr2 "set interface ip address host-$LSR2_PE2 100.64.4.10/24"

vpp_exec lsr2 "mpls table add 0"
vpp_exec lsr2 "set interface mpls host-$LSR2_LSR1 enable"
vpp_exec lsr2 "set interface mpls host-$LSR2_PE2 enable"

# Forward: Swap 200 → 300
vpp_exec lsr2 "mpls local-label 200 non-eos via 100.64.4.20 host-$LSR2_PE2 out-labels 300"
# Return: Swap 400 → 401
vpp_exec lsr2 "mpls local-label 400 non-eos via 100.64.3.10 host-$LSR2_LSR1 out-labels 401"

# IP routes for PE loopback reachability
vpp_exec lsr2 "ip route add 10.255.0.1/32 via 100.64.3.10"
vpp_exec lsr2 "ip route add 10.255.0.2/32 via 100.64.4.20"

# Linux IP addresses and routes for IP transit (PE-PE iBGP uses Linux TCP)
docker exec -i lsr2 ip addr add 100.64.3.20/24 dev "$LSR2_LSR1" 2>/dev/null || true
docker exec -i lsr2 ip addr add 100.64.4.10/24 dev "$LSR2_PE2" 2>/dev/null || true
docker exec -i lsr2 sysctl -w net.ipv4.ip_forward=1 > /dev/null 2>&1
docker exec -i lsr2 ip route add 10.255.0.1/32 via 100.64.3.10 2>/dev/null || true
docker exec -i lsr2 ip route add 10.255.0.2/32 via 100.64.4.20 2>/dev/null || true

echo ""
echo "============================================"
echo "  Configuring PE2 (Provider Edge)"
echo "============================================"

vpp_exec pe2 "set interface state host-$PE2_CORE up"
vpp_exec pe2 "set interface state host-$PE2_CE2 up"
vpp_exec pe2 "set interface state host-$PE2_CE4 up"
vpp_exec pe2 "set interface state host-$PE2_CE6 up"

vpp_exec pe2 "mpls table add 0"
vpp_exec pe2 "ip table add 10"
vpp_exec pe2 "ip table add 20"
vpp_exec pe2 "ip table add 30"

# Core-facing interface
vpp_exec pe2 "set interface ip address host-$PE2_CORE 100.64.4.20/24"
vpp_exec pe2 "set interface mpls host-$PE2_CORE enable"

# VRF 10: CE2-facing
vpp_exec pe2 "set interface ip table host-$PE2_CE2 10"
vpp_exec pe2 "set interface ip address host-$PE2_CE2 100.64.5.10/24"

# VRF 20: CE4-facing
vpp_exec pe2 "set interface ip table host-$PE2_CE4 20"
vpp_exec pe2 "set interface ip address host-$PE2_CE4 100.64.7.10/24"

# VRF 30: CE6-facing
vpp_exec pe2 "set interface ip table host-$PE2_CE6 30"
vpp_exec pe2 "set interface ip address host-$PE2_CE6 100.64.7.10/24"

# Loopback for BGP router-id (VPP side)
vpp_exec pe2 "create loopback interface"
vpp_exec pe2 "set interface state loop0 up"
vpp_exec pe2 "set interface ip address loop0 10.255.0.2/32"

# Transport label pop: 300 non-eos → MPLS lookup for VPN label
vpp_exec pe2 "mpls local-label 300 non-eos via mpls-lookup-in-table 0"

# VPN label disposition (static fallback)
vpp_exec pe2 "mpls local-label 500 eos via ip4-lookup-in-table 10"
vpp_exec pe2 "mpls local-label 700 eos via ip4-lookup-in-table 20"
vpp_exec pe2 "mpls local-label 900 eos via ip4-lookup-in-table 30"

# Return path: push transport + VPN labels toward PE1
# Remote routes via MPLS to PE1:
vpp_exec pe2 "ip route add 100.64.1.0/24 table 10 via 100.64.4.10 host-$PE2_CORE out-labels 400 600"
vpp_exec pe2 "ip route add 10.1.1.0/24 table 10 via 100.64.4.10 host-$PE2_CORE out-labels 400 600"
vpp_exec pe2 "ip route add 100.64.6.0/24 table 20 via 100.64.4.10 host-$PE2_CORE out-labels 400 800"
vpp_exec pe2 "ip route add 100.64.6.0/24 table 30 via 100.64.4.10 host-$PE2_CORE out-labels 400 1000"
# Local CE-connected LAN routes (so PE2 can forward decapsulated MPLS traffic to CEs):
vpp_exec pe2 "ip route add 10.1.2.0/24 table 10 via 100.64.5.20 host-$PE2_CE2"

# --- Linux interfaces for FRR ---
docker exec -i pe2 ip addr add 100.64.5.10/24 dev "$PE2_CE2" 2>/dev/null || true
docker exec -i pe2 ip addr add 100.64.7.10/24 dev "$PE2_CE4" 2>/dev/null || true
docker exec -i pe2 ip addr add 100.64.7.10/24 dev "$PE2_CE6" 2>/dev/null || true
docker exec -i pe2 ip addr add 100.64.4.20/24 dev "$PE2_CORE" 2>/dev/null || true
# Mgmt interface already has 10.255.0.2 from Docker — no need to add

# Linux VRF devices for FRR
docker exec -i pe2 ip link add VRF10 type vrf table 10 2>/dev/null || true
docker exec -i pe2 ip link set VRF10 up 2>/dev/null || true
docker exec -i pe2 ip link set "$PE2_CE2" master VRF10 2>/dev/null || true

docker exec -i pe2 ip link add VRF20 type vrf table 20 2>/dev/null || true
docker exec -i pe2 ip link set VRF20 up 2>/dev/null || true
docker exec -i pe2 ip link set "$PE2_CE4" master VRF20 2>/dev/null || true

docker exec -i pe2 ip link add VRF30 type vrf table 30 2>/dev/null || true
docker exec -i pe2 ip link set VRF30 up 2>/dev/null || true
docker exec -i pe2 ip link set "$PE2_CE6" master VRF30 2>/dev/null || true

# Blackhole routes in Linux VRFs for remote CE LANs (see PE1 notes above)
docker exec -i pe2 ip route add blackhole 10.1.1.0/24 vrf VRF10 2>/dev/null || true

echo ""
echo "============================================"
echo "  Starting FRR on all nodes"
echo "============================================"
for node in ce1 ce3 ce5 pe1 lsr1 lsr2 pe2 ce2 ce4 ce6; do
  echo "  Starting FRR on $node..."
  docker exec -i "$node" /usr/lib/frr/frrinit.sh start 2>/dev/null || true
done

echo ""
echo "============================================"
echo "  Setting up End Hosts"
echo "============================================"

echo "  Installing tools on host1..."
docker exec -i host1 bash -c "apt-get update -qq && apt-get install -y -qq iputils-ping traceroute iproute2 > /dev/null 2>&1" || true
echo "  Setting default route on host1 (via CE1: 10.1.1.1)..."
docker exec -i host1 ip route replace default via 10.1.1.1 2>/dev/null || true

echo "  Installing tools on host2..."
docker exec -i host2 bash -c "apt-get update -qq && apt-get install -y -qq iputils-ping traceroute iproute2 > /dev/null 2>&1" || true
echo "  Setting default route on host2 (via CE2: 10.1.2.1)..."
docker exec -i host2 ip route replace default via 10.1.2.1 2>/dev/null || true

echo ""
echo "============================================"
echo "  Waiting for BGP sessions (15s)..."
echo "============================================"
sleep 15

echo ""
echo "============================================"
echo "  BGP Session Status"
echo "============================================"

echo ""
echo "--- PE1 BGP Summary ---"
docker exec -i pe1 vtysh -c "show bgp summary" 2>/dev/null || echo "  FRR not ready yet"

echo ""
echo "--- PE1 VRF 10 BGP ---"
docker exec -i pe1 vtysh -c "show bgp vrf VRF10 ipv4 unicast" 2>/dev/null || true

echo ""
echo "--- PE2 BGP Summary ---"
docker exec -i pe2 vtysh -c "show bgp summary" 2>/dev/null || echo "  FRR not ready yet"

echo ""
echo "--- PE1 VPNv4 Routes ---"
docker exec -i pe1 vtysh -c "show bgp ipv4 vpn" 2>/dev/null || true

echo ""
echo "============================================"
echo "  Configuration complete!"
echo "============================================"
echo ""
echo "Verification commands:"
echo "  docker exec -it pe1 vtysh -c 'show bgp summary'"
echo "  docker exec -it pe1 vtysh -c 'show bgp ipv4 vpn'"
echo "  docker exec -it pe1 vtysh -c 'show bgp vrf VRF10 ipv4 unicast'"
echo "  docker exec -it pe2 vtysh -c 'show bgp vrf VRF10 ipv4 unicast'"
echo "  docker exec -it ce1 vppctl ping 100.64.5.20"
echo "  docker exec -it ce3 vppctl ping 100.64.7.20"
echo "  docker exec -it ce5 vppctl ping 100.64.7.20"
echo ""
echo "End Host tests:"
echo "  docker exec -it host1 ping -c 3 10.1.2.10    # host1 → host2 (across MPLS core)"
echo "  docker exec -it host2 ping -c 3 10.1.1.10    # host2 → host1 (across MPLS core)"
echo "  docker exec -it host1 traceroute 10.1.2.10   # trace path through MPLS"
echo "============================================"
