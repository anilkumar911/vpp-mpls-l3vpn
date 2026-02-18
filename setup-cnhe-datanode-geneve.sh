#!/bin/bash
# Configure cnhe-datanode to steer org-pre-security traffic to frouter
# via GENEVE tunnel and return org-post-security traffic back to MPLS over GRE.
#
# This is the GENEVE variant: traffic between datanode and frouter-simulator
# goes through the CNHE Geneve tunnel (cnhe-gnv interface) instead of the
# direct LAN bridge path. The frouter-simulator reflects packets back via
# Geneve, and CNHE decaps them into the org-post-security VRF.

set -e

function vpp_exec() {
  docker exec -i cnhe-datanode vppctl "$1"
}

function vpp_exec_allow() {
  docker exec -i cnhe-datanode vppctl "$1" >/dev/null 2>&1 || true
}

function get_table_id() {
  local name="$1"
  docker exec -i cnhe-datanode vppctl show ip table | awk -v n="$name" '$0 ~ n {for (i=1;i<=NF;i++) if ($i ~ /^table_id:/) {split($i,a,":"); print a[2]}}'
}

function get_iface_by_ip() {
  local ip="$1"
  docker exec -i cnhe-datanode ip -4 addr show |
    awk -v ip="$ip" '
      /^[0-9]+:/ { gsub(/:/, ""); iface=$2; sub(/@.*/, "", iface) }
      $1=="inet" && $2 ~ ip { print iface; exit }
    '
}

echo "=== CNHE Datanode Geneve Setup ==="

# =========================================================================
# Discover org VRF table IDs
# =========================================================================
PRE_TABLE_ID=$(get_table_id "org-pre-security-1000")
POST_TABLE_ID=$(get_table_id "org-post-security-1000")
if [[ -z "$PRE_TABLE_ID" || -z "$POST_TABLE_ID" ]]; then
  echo "ERROR: Could not find org-pre/post security table IDs in cnhe-datanode"
  exit 1
fi
echo "  Pre-security table ID:  $PRE_TABLE_ID"
echo "  Post-security table ID: $POST_TABLE_ID"

# =========================================================================
# GRE tunnel setup (MPLS-over-GRE to LSR2)
# =========================================================================
DN_GRE=$(get_iface_by_ip "203.0.113.2")
if [[ -z "$DN_GRE" ]]; then
  echo "ERROR: Could not find GRE transport interface for 203.0.113.2"
  exit 1
fi

# Ensure GRE transport interface is up and addressed
vpp_exec_allow "set interface state host-$DN_GRE up"
vpp_exec_allow "set interface ip address host-$DN_GRE 203.0.113.2/24"

# Sync VPP af-packet MAC with Linux MAC to prevent l3 mac mismatch drops
DN_GRE_LINUX_MAC=$(docker exec -i cnhe-datanode cat "/sys/class/net/$DN_GRE/address" 2>/dev/null || true)
if [[ -n "$DN_GRE_LINUX_MAC" ]]; then
  vpp_exec_allow "set interface mac address host-$DN_GRE $DN_GRE_LINUX_MAC"
fi

# GRE tunnel to LSR2 (MPLS-over-GRE)
vpp_exec_allow "create gre tunnel src 203.0.113.2 dst 203.0.113.1"
vpp_exec_allow "set interface state gre0 up"
vpp_exec_allow "set interface ip address gre0 172.16.0.2/30"
echo "  GRE tunnel: 203.0.113.2 → 203.0.113.1 (gre0)"

# =========================================================================
# MPLS setup
# =========================================================================
vpp_exec_allow "mpls table add 0"
vpp_exec_allow "set interface mpls gre0 enable"

# Transport label processing
vpp_exec_allow "mpls local-label 310 non-eos via mpls-lookup-in-table 0"

# VPN label disposition: label 1100 → org-pre-security-1000
vpp_exec_allow "mpls local-label 1100 eos via ip4-lookup-in-table $PRE_TABLE_ID"
echo "  MPLS: label 310 (transport), label 1100 → pre-security (table $PRE_TABLE_ID)"

# =========================================================================
# CNHE Geneve tunnel: pre-security → frouter via cnhe-gnv
# =========================================================================
# The cnhe-gnv interface is an NBMA (Non-Broadcast Multiple Access) interface.
# Routes must use the peer UUID encoded as an IPv6 address as the next-hop,
# NOT a regular IPv4 address (NBMA doesn't support ARP resolution).
#
# The peer UUID-as-IPv6 is derived from the frouter IP with a 0xFF000000 mask:
#   Frouter IP 192.168.80.100 (0xC0A85064) → UUID ff000000-0000-0000-c000-0000c0a85064
#   → IPv6: ff00::c000:0:c0a8:5064

# Discover the cnhe-gnv peer IPv6 address
CNHE_PEER_IPV6=$(docker exec -i cnhe-datanode vppctl show cnhe peers cnhe-gnv 2>/dev/null | \
  awk '/ff00::/ {for(i=1;i<=NF;i++) if($i ~ /^ff00::/) {print $i; exit}}')
if [[ -z "$CNHE_PEER_IPV6" ]]; then
  echo "ERROR: Could not find cnhe-gnv peer IPv6 (is the CNHE peer configured?)"
  exit 1
fi
echo "  CNHE peer IPv6: $CNHE_PEER_IPV6 (cnhe-gnv)"

# Remove any old direct LAN routes in pre-security (from GRE branch)
for prefix in 10.1.1.0/24 10.1.2.0/24 100.64.1.0/24 100.64.5.0/24 10.100.1.0/24; do
  vpp_exec_allow "ip route del $prefix table $PRE_TABLE_ID via 192.168.80.100 lan"
done

# Add pre-security routes via CNHE Geneve tunnel to frouter
echo "  Adding pre-security routes via cnhe-gnv:"
for prefix in 10.1.1.0/24 10.1.2.0/24 100.64.1.0/24 100.64.5.0/24 10.100.1.0/24; do
  vpp_exec_allow "ip route add $prefix table $PRE_TABLE_ID via $CNHE_PEER_IPV6 cnhe-gnv"
  echo "    $prefix → via $CNHE_PEER_IPV6 cnhe-gnv"
done

# =========================================================================
# VNI binding for Geneve return path
# =========================================================================
# When MPLS packets enter the datanode (not via Geneve), the CNHE buffer
# opaque VNI (cb->vni) is not set. The midchain fixup uses the sentinel
# value 0xFFFFFF (VNI 16777215) in the outbound Geneve header.
#
# When frouter reflects the packet back, the return Geneve has VNI=0xFFFFFF.
# We need a VNI binding for 0xFFFFFF so CNHE can match the tunnel and
# deliver the packet to the correct post-security VRF.
echo "  Adding VNI 16777215 binding (wire VNI for MPLS-injected traffic)"
vpp_exec_allow "cnhe org add ip4 cnhe-gnv vni 16777215 presec-table-ip4 $PRE_TABLE_ID postsec-table-ip4 $POST_TABLE_ID"

# =========================================================================
# Post-security routes: org-post-security → MPLS/GRE with labels
# =========================================================================
echo "  Adding post-security routes (MPLS labels → GRE → LSR2):"
vpp_exec_allow "ip route add 10.1.1.0/24 table $POST_TABLE_ID via 172.16.0.1 gre0 out-labels 1400 600"
vpp_exec_allow "ip route add 100.64.1.0/24 table $POST_TABLE_ID via 172.16.0.1 gre0 out-labels 1400 600"
vpp_exec_allow "ip route add 10.1.2.0/24 table $POST_TABLE_ID via 172.16.0.1 gre0 out-labels 1500 500"
vpp_exec_allow "ip route add 100.64.5.0/24 table $POST_TABLE_ID via 172.16.0.1 gre0 out-labels 1500 500"
echo "    10.1.1.0/24 → labels [1400][600]"
echo "    10.1.2.0/24 → labels [1500][500]"

# =========================================================================
# NOTE: No frouter gateway or LAN route leak fixes needed
# =========================================================================
# Unlike the direct-LAN (GRE branch) approach, the Geneve path does NOT
# require:
#   - Frouter default gateway pointing to datanode (Geneve handles routing)
#   - ICMP redirect suppression (traffic uses different interfaces/tunnels)
#   - LAN VRF → post-security route leaks (Geneve decap uses VNI binding
#     to deliver directly to post-security VRF)

# =========================================================================
# Summary
# =========================================================================
echo ""
echo "=== Configuration Summary ==="
echo "  Packet flow (forward: host1 → host2):"
echo "    MPLS [310][1100] → GRE → datanode"
echo "    → MPLS disposition → pre-security VRF"
echo "    → cnhe-checks → Geneve encap → frouter-sim (reflect)"
echo "    → Geneve return → cnhe-geneve4-input → post-security VRF"
echo "    → cnhe-checks → MPLS [1500][500] → GRE → LSR2 → PE2 → CE2 → host2"
echo ""
vpp_exec "show interface gre0"
vpp_exec "show mpls fib 310"
vpp_exec "show cnhe vni"
echo ""
echo "=== Geneve setup complete ==="
