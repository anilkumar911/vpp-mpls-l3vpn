#!/bin/bash

function vpp_exec() {
  docker exec -i $1 vppctl $2
}

function linux_exec() {
  docker exec -i $1 $2
}

# Find which ethX interface in a container has an IP in a given subnet
# Usage: get_iface <container> <subnet_prefix>
# Example: get_iface pe1 "100.64.1."  → returns "eth1"
function get_iface() {
  local container=$1
  local prefix=$2
  docker exec -i $container ip -4 addr show | grep "$prefix" | sed -n 's/.*\(eth[0-9]\).*/\1/p' | head -1
}

echo "============================================"
echo "  Creating Host Interfaces"
echo "============================================"

echo "CE1..."
vpp_exec ce1 "create host-interface name eth0"

echo "CE3..."
vpp_exec ce3 "create host-interface name eth0"

echo "CE5..."
vpp_exec ce5 "create host-interface name eth0"

echo "PE1..."
vpp_exec pe1 "create host-interface name eth0"
vpp_exec pe1 "create host-interface name eth1"
vpp_exec pe1 "create host-interface name eth2"
vpp_exec pe1 "create host-interface name eth3"

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

echo "CE2..."
vpp_exec ce2 "create host-interface name eth0"

echo "CE4..."
vpp_exec ce4 "create host-interface name eth0"

echo "CE6..."
vpp_exec ce6 "create host-interface name eth0"

echo ""
echo "============================================"
echo "  Detecting Interface-to-Network Mapping"
echo "============================================"
echo "  (Docker assigns ethX non-deterministically)"

# PE1: 4 interfaces
PE1_CE1=$(get_iface pe1 "100.64.1.")    # CE1-facing (VRF 10)
PE1_CORE=$(get_iface pe1 "100.64.2.")   # Core-facing (MPLS)
PE1_CE3=$(get_iface pe1 "100.64.6.")    # CE3-facing (VRF 20)
PE1_CE5=$(get_iface pe1 "100.64.8.")    # CE5-facing (VRF 30)
echo "  PE1: CE1=host-$PE1_CE1, Core=host-$PE1_CORE, CE3=host-$PE1_CE3, CE5=host-$PE1_CE5"

# LSR1: 2 interfaces
LSR1_PE1=$(get_iface lsr1 "100.64.2.")  # PE1-side
LSR1_LSR2=$(get_iface lsr1 "100.64.3.") # LSR2-side
echo "  LSR1: PE1-side=host-$LSR1_PE1, LSR2-side=host-$LSR1_LSR2"

# LSR2: 2 interfaces
LSR2_LSR1=$(get_iface lsr2 "100.64.3.") # LSR1-side
LSR2_PE2=$(get_iface lsr2 "100.64.4.")  # PE2-side
echo "  LSR2: LSR1-side=host-$LSR2_LSR1, PE2-side=host-$LSR2_PE2"

# PE2: 4 interfaces
PE2_CORE=$(get_iface pe2 "100.64.4.")   # Core-facing (MPLS)
PE2_CE2=$(get_iface pe2 "100.64.5.")    # CE2-facing (VRF 10)
PE2_CE4=$(get_iface pe2 "100.64.7.")    # CE4-facing (VRF 20)
PE2_CE6=$(get_iface pe2 "100.64.9.")    # CE6-facing (VRF 30)
echo "  PE2: Core=host-$PE2_CORE, CE2=host-$PE2_CE2, CE4=host-$PE2_CE4, CE6=host-$PE2_CE6"

echo ""
echo "============================================"
echo "  Flushing Linux IPs (prevent MAC mismatch)"
echo "============================================"
for node in ce1 ce3 ce5 pe1 lsr1 lsr2 pe2 ce2 ce4 ce6; do
  echo "Flushing $node..."
  docker exec -i $node ip addr flush dev eth0 2>/dev/null
  docker exec -i $node ip addr flush dev eth1 2>/dev/null
  docker exec -i $node ip addr flush dev eth2 2>/dev/null
  docker exec -i $node ip addr flush dev eth3 2>/dev/null
done

echo ""
echo "============================================"
echo "  Configuring CE1"
echo "============================================"
vpp_exec ce1 "set interface state host-eth0 up"
vpp_exec ce1 "set interface ip address host-eth0 100.64.1.20/24"
vpp_exec ce1 "ip route add 100.64.5.0/24 via 100.64.1.10"

echo ""
echo "============================================"
echo "  Configuring CE3 (VRF 20)"
echo "============================================"
vpp_exec ce3 "set interface state host-eth0 up"
vpp_exec ce3 "set interface ip address host-eth0 100.64.6.20/24"
vpp_exec ce3 "ip route add 100.64.7.0/24 via 100.64.6.10"

echo ""
echo "============================================"
echo "  Configuring CE5 (VRF 30 — same IPs as CE3)"
echo "============================================"
vpp_exec ce5 "set interface state host-eth0 up"
vpp_exec ce5 "set interface ip address host-eth0 100.64.6.20/24"
vpp_exec ce5 "ip route add 100.64.7.0/24 via 100.64.6.10"

echo ""
echo "============================================"
echo "  Configuring CE2"
echo "============================================"
vpp_exec ce2 "set interface state host-eth0 up"
vpp_exec ce2 "set interface ip address host-eth0 100.64.5.20/24"
vpp_exec ce2 "ip route add 100.64.1.0/24 via 100.64.5.10"

echo ""
echo "============================================"
echo "  Configuring CE4 (VRF 20)"
echo "============================================"
vpp_exec ce4 "set interface state host-eth0 up"
vpp_exec ce4 "set interface ip address host-eth0 100.64.7.20/24"
vpp_exec ce4 "ip route add 100.64.6.0/24 via 100.64.7.10"

echo ""
echo "============================================"
echo "  Configuring CE6 (VRF 30 — same IPs as CE4)"
echo "============================================"
vpp_exec ce6 "set interface state host-eth0 up"
vpp_exec ce6 "set interface ip address host-eth0 100.64.7.20/24"
vpp_exec ce6 "ip route add 100.64.6.0/24 via 100.64.7.10"

echo ""
echo "============================================"
echo "  Configuring PE1 (Ingress PE)"
echo "============================================"
vpp_exec pe1 "set interface state host-$PE1_CE1 up"
vpp_exec pe1 "set interface state host-$PE1_CORE up"
vpp_exec pe1 "set interface state host-$PE1_CE3 up"
vpp_exec pe1 "set interface state host-$PE1_CE5 up"

# Create MPLS table and VRF tables
vpp_exec pe1 "mpls table add 0"
vpp_exec pe1 "ip table add 10"
vpp_exec pe1 "ip table add 20"
vpp_exec pe1 "ip table add 30"

# Assign CE1-facing interface to VRF 10 (before setting IP)
vpp_exec pe1 "set interface ip table host-$PE1_CE1 10"
vpp_exec pe1 "set interface ip address host-$PE1_CE1 100.64.1.10/24"

# Core-facing interface stays in global table
vpp_exec pe1 "set interface ip address host-$PE1_CORE 100.64.2.10/24"

# Enable MPLS on core-facing interface
vpp_exec pe1 "set interface mpls host-$PE1_CORE enable"

# Push transport(100) + VPN(500) for traffic to CE2 subnet
vpp_exec pe1 "ip route add 100.64.5.0/24 table 10 via 100.64.2.20 host-$PE1_CORE out-labels 100 500"

# --- Return path: pop transport(402) + VPN(600) for traffic from CE2 ---
vpp_exec pe1 "mpls local-label 402 non-eos via mpls-lookup-in-table 0"
vpp_exec pe1 "mpls local-label 600 eos via ip4-lookup-in-table 10"

# --- VRF 20 (CE3) ---
vpp_exec pe1 "set interface ip table host-$PE1_CE3 20"
vpp_exec pe1 "set interface ip address host-$PE1_CE3 100.64.6.10/24"

# Push transport(100) + VPN(700) for VRF 20 traffic to CE4 subnet
vpp_exec pe1 "ip route add 100.64.7.0/24 table 20 via 100.64.2.20 host-$PE1_CORE out-labels 100 700"

# Return path VRF 20: pop VPN(800) -> IP lookup in VRF 20
vpp_exec pe1 "mpls local-label 800 eos via ip4-lookup-in-table 20"

# --- VRF 30 (CE5 — overlapping IPs with VRF 20) ---
vpp_exec pe1 "set interface ip table host-$PE1_CE5 30"
vpp_exec pe1 "set interface ip address host-$PE1_CE5 100.64.6.10/24"

# Push transport(100) + VPN(900) for VRF 30 traffic to CE6 subnet
vpp_exec pe1 "ip route add 100.64.7.0/24 table 30 via 100.64.2.20 host-$PE1_CORE out-labels 100 900"

# Return path VRF 30: pop VPN(1000) -> IP lookup in VRF 30
vpp_exec pe1 "mpls local-label 1000 eos via ip4-lookup-in-table 30"

echo ""
echo "============================================"
echo "  Configuring LSR1 (Label Switch Router)"
echo "============================================"
vpp_exec lsr1 "set interface state host-$LSR1_PE1 up"
vpp_exec lsr1 "set interface state host-$LSR1_LSR2 up"
vpp_exec lsr1 "set interface ip address host-$LSR1_PE1 100.64.2.20/24"
vpp_exec lsr1 "set interface ip address host-$LSR1_LSR2 100.64.3.10/24"

# Create MPLS table and enable MPLS on both interfaces
vpp_exec lsr1 "mpls table add 0"
vpp_exec lsr1 "set interface mpls host-$LSR1_PE1 enable"
vpp_exec lsr1 "set interface mpls host-$LSR1_LSR2 enable"

# Forward: Swap label 100 -> 200 (non-eos: VPN label below)
vpp_exec lsr1 "mpls local-label 100 non-eos via 100.64.3.20 host-$LSR1_LSR2 out-labels 200"

# Return: Swap label 401 -> 402
vpp_exec lsr1 "mpls local-label 401 non-eos via 100.64.2.10 host-$LSR1_PE1 out-labels 402"

echo ""
echo "============================================"
echo "  Configuring LSR2 (Label Switch Router)"
echo "============================================"
vpp_exec lsr2 "set interface state host-$LSR2_LSR1 up"
vpp_exec lsr2 "set interface state host-$LSR2_PE2 up"
vpp_exec lsr2 "set interface ip address host-$LSR2_LSR1 100.64.3.20/24"
vpp_exec lsr2 "set interface ip address host-$LSR2_PE2 100.64.4.10/24"

# Create MPLS table and enable MPLS on both interfaces
vpp_exec lsr2 "mpls table add 0"
vpp_exec lsr2 "set interface mpls host-$LSR2_LSR1 enable"
vpp_exec lsr2 "set interface mpls host-$LSR2_PE2 enable"

# Forward: Swap label 200 -> 300 (non-eos: VPN label below)
vpp_exec lsr2 "mpls local-label 200 non-eos via 100.64.4.20 host-$LSR2_PE2 out-labels 300"

# Return: Swap label 400 -> 401
vpp_exec lsr2 "mpls local-label 400 non-eos via 100.64.3.10 host-$LSR2_LSR1 out-labels 401"

echo ""
echo "============================================"
echo "  Configuring PE2 (Egress PE)"
echo "============================================"
vpp_exec pe2 "set interface state host-$PE2_CORE up"
vpp_exec pe2 "set interface state host-$PE2_CE2 up"
vpp_exec pe2 "set interface state host-$PE2_CE4 up"
vpp_exec pe2 "set interface state host-$PE2_CE6 up"

# Create MPLS table and VRF tables
vpp_exec pe2 "mpls table add 0"
vpp_exec pe2 "ip table add 10"
vpp_exec pe2 "ip table add 20"
vpp_exec pe2 "ip table add 30"

# Core-facing interface stays in global table
vpp_exec pe2 "set interface ip address host-$PE2_CORE 100.64.4.20/24"

# Enable MPLS on core-facing interface
vpp_exec pe2 "set interface mpls host-$PE2_CORE enable"

# Assign CE2-facing interface to VRF 10 (before setting IP)
vpp_exec pe2 "set interface ip table host-$PE2_CE2 10"
vpp_exec pe2 "set interface ip address host-$PE2_CE2 100.64.5.10/24"

# Transport label pop: label 300 non-eos -> pop, do MPLS lookup for inner VPN label
vpp_exec pe2 "mpls local-label 300 non-eos via mpls-lookup-in-table 0"

# VPN label disposition: label 500 eos -> pop, do IP lookup in VRF 10
vpp_exec pe2 "mpls local-label 500 eos via ip4-lookup-in-table 10"

# --- Return path: push transport(400) + VPN(600) for traffic to CE1 subnet ---
vpp_exec pe2 "ip route add 100.64.1.0/24 table 10 via 100.64.4.10 host-$PE2_CORE out-labels 400 600"

# --- VRF 20 (CE4) ---
vpp_exec pe2 "set interface ip table host-$PE2_CE4 20"
vpp_exec pe2 "set interface ip address host-$PE2_CE4 100.64.7.10/24"

# VPN label disposition VRF 20: label 700 eos -> pop, IP lookup in VRF 20
vpp_exec pe2 "mpls local-label 700 eos via ip4-lookup-in-table 20"

# Return path VRF 20: push transport(400) + VPN(800) for traffic to CE3 subnet
vpp_exec pe2 "ip route add 100.64.6.0/24 table 20 via 100.64.4.10 host-$PE2_CORE out-labels 400 800"

# --- VRF 30 (CE6 — overlapping IPs with VRF 20) ---
vpp_exec pe2 "set interface ip table host-$PE2_CE6 30"
vpp_exec pe2 "set interface ip address host-$PE2_CE6 100.64.7.10/24"

# VPN label disposition VRF 30: label 900 eos -> pop, IP lookup in VRF 30
vpp_exec pe2 "mpls local-label 900 eos via ip4-lookup-in-table 30"

# Return path VRF 30: push transport(400) + VPN(1000) for traffic to CE5 subnet
vpp_exec pe2 "ip route add 100.64.6.0/24 table 30 via 100.64.4.10 host-$PE2_CORE out-labels 400 1000"

echo ""
echo "============================================"
echo "  Configuration complete!"
echo "============================================"
