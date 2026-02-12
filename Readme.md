# VPP MPLS L3VPN Docker Lab

This project builds a complete MPLS L3VPN lab using VPP (data plane) + FRR (control plane)
running inside Docker containers.

## Phases

| Branch | Description |
|--------|-------------|
| `main` | Phase 1 — Static MPLS routes, no control plane |
| `mp-bgp` | Phase 2 — MP-BGP (VPNv4) via FRR for VPN route exchange |

## Current: Phase 2 (MP-BGP)

Topology includes:
- 2 Provider Edge (PE) routers — VPP + FRR (bgpd)
- 2 Label Switch Routers (LSR) — VPP + FRR (minimal)
- 6 Customer Edge (CE) routers — VPP + FRR (bgpd)
- 2 End Hosts — plain Ubuntu containers (host1 behind CE1, host2 behind CE2)

Control Plane:
- **PE1 ↔ PE2**: MP-iBGP (ASN 65000, VPNv4 address family)
- **CE1/CE2 ↔ PE**: eBGP (ASN 65001, VRF 10)
- **CE3/CE4 ↔ PE**: eBGP (ASN 65002, VRF 20)
- **CE5/CE6 ↔ PE**: eBGP (ASN 65003, VRF 30)

End Hosts (VRF 10 only):
- **host1** (10.1.1.10) → behind CE1, customer LAN 10.1.1.0/24
- **host2** (10.1.2.10) → behind CE2, customer LAN 10.1.2.0/24
- Hosts know nothing about MPLS/BGP — just a default route to their CE gateway

VRF Assignment:
- VRF 10: CE1 (PE1 side) ↔ CE2 (PE2 side)
- VRF 20: CE3 (PE1 side) ↔ CE4 (PE2 side)
- VRF 30: CE5 (PE1 side) ↔ CE6 (PE2 side) — same IPs as VRF 20!

All nodes run FD.io VPP (data plane) + FRRouting (control plane).
Custom Docker image: `vpp-frr:latest` (built from `frr-vpp/Dockerfile`).

------------------------------------------------------------
TOPOLOGY
------------------------------------------------------------

```
               VRF 10                    VRF 20                    VRF 30
┌────────────────────────┐  ┌────────────────────────┐  ┌────────────────────────┐
│         CE1            │  │         CE3            │  │         CE5            │
│  ┌──────────────────┐  │  │  ┌──────────────────┐  │  │  ┌──────────────────┐  │
│  │ host-eth0        │  │  │  │ host-eth0        │  │  │  │ host-eth0        │  │
│  │ 100.64.1.20/24   │  │  │  │ 100.64.6.20/24   │  │  │  │ 100.64.6.20/24   │  │
│  └────────┬─────────┘  │  │  └────────┬─────────┘  │  │  └────────┬─────────┘  │
└───────────┼────────────┘  └───────────┼────────────┘  └───────────┼────────────┘
            │ 100.64.1.0/24             │ 100.64.6.0/24             │ 100.64.8.0/24
            │                           │                           │ VPP: 100.64.6.0/24
┌───────────┼───────────────────────────┼───────────────────────────┼────────────┐
│  ┌────────┴─────────┐  ┌─────────────┴──────────┐  ┌─────────────┴──────────┐ │
│  │ CE1-facing       │  │ CE3-facing             │  │ CE5-facing             │ │
│  │ 100.64.1.10/24   │  │ 100.64.6.10/24         │  │ 100.64.6.10/24         │ │
│  │ VRF 10           │  │ VRF 20                 │  │ VRF 30                 │ │
│  └──────────────────┘  └────────────────────────┘  └────────────────────────┘ │
│                                    PE1                                        │
│  ┌──────────────────┐                                                         │
│  │ Core-facing      │    ┌──────────────────────────────┐                     │
│  │ 100.64.2.10/24   │    │ VRF 20 & VRF 30: same IPs,  │                     │
│  │ MPLS enabled     │    │ different VPN labels (700/900)│                     │
│  └────────┬─────────┘    └──────────────────────────────┘                     │
└───────────┼───────────────────────────────────────────────────────────────────┘
            │ 100.64.2.0/24
┌───────────┼────────────┐
│  ┌────────┴─────────┐  │
│  │ host-eth0        │  │
│  │ 100.64.2.20/24   │  │
│  │ MPLS enabled     │  │
│  └──────────────────┘  │
│        LSR1            │
│  ┌──────────────────┐  │
│  │ host-eth1        │  │
│  │ 100.64.3.10/24   │  │
│  │ MPLS enabled     │  │
│  └────────┬─────────┘  │
└───────────┼────────────┘
            │ 100.64.3.0/24
┌───────────┼────────────┐
│  ┌────────┴─────────┐  │
│  │ host-eth0        │  │
│  │ 100.64.3.20/24   │  │
│  │ MPLS enabled     │  │
│  └──────────────────┘  │
│        LSR2            │
│  ┌──────────────────┐  │
│  │ host-eth1        │  │
│  │ 100.64.4.10/24   │  │
│  │ MPLS enabled     │  │
│  └────────┬─────────┘  │
└───────────┼────────────┘
            │ 100.64.4.0/24
┌───────────┼───────────────────────────────────────────────────────────────────┐
│  ┌────────┴─────────┐                                                         │
│  │ Core-facing      │    ┌──────────────────────────────┐                     │
│  │ 100.64.4.20/24   │    │ VRF 20 & VRF 30: same IPs,  │                     │
│  │ MPLS enabled     │    │ different VPN labels (700/900)│                     │
│  └──────────────────┘    └──────────────────────────────┘                     │
│                                    PE2                                        │
│  ┌────────┬─────────┐  ┌─────────────┬──────────┐  ┌─────────────┬──────────┐ │
│  │ CE2-facing       │  │ CE4-facing             │  │ CE6-facing             │ │
│  │ 100.64.5.10/24   │  │ 100.64.7.10/24         │  │ 100.64.7.10/24         │ │
│  │ VRF 10           │  │ VRF 20                 │  │ VRF 30                 │ │
│  └────────┬─────────┘  └─────────────┬──────────┘  └─────────────┬──────────┘ │
└───────────┼───────────────────────────┼───────────────────────────┼────────────┘
            │ 100.64.5.0/24             │ 100.64.7.0/24             │ 100.64.9.0/24
            │                           │                           │ VPP: 100.64.7.0/24
┌───────────┼────────────┐  ┌───────────┼────────────┐  ┌───────────┼────────────┐
│  ┌────────┴─────────┐  │  │  ┌────────┴─────────┐  │  │  ┌────────┴─────────┐  │
│  │ host-eth0        │  │  │  │ host-eth0        │  │  │  │ host-eth0        │  │
│  │ 100.64.5.20/24   │  │  │  │ 100.64.7.20/24   │  │  │  │ 100.64.7.20/24   │  │
│  └──────────────────┘  │  │  └──────────────────┘  │  │  └──────────────────┘  │
│         CE2            │  │         CE4            │  │         CE6            │
└────────────────────────┘  └────────────────────────┘  └────────────────────────┘
```

> **Note:** CE5/CE6 (VRF 30) use the SAME customer IPs as CE3/CE4 (VRF 20): 100.64.6.20
> and 100.64.7.20. Docker networks use different subnets (100.64.8.0/24, 100.64.9.0/24) for
> L2 connectivity, but VPP assigns overlapping IPs in separate VRFs — proving VRF isolation.


End Host Connectivity (VRF 10):

```
host1 (10.1.1.10) ─── 10.1.1.0/24 ─── CE1 (10.1.1.1) ═══ PE1 ═══ LSR1 ═══ LSR2 ═══ PE2 ═══ CE2 (10.1.2.1) ─── 10.1.2.0/24 ─── host2 (10.1.2.10)
                       customer LAN1                          MPLS core                          customer LAN2
```

Packet path: host1 → CE1 (eBGP route) → PE1 (MPLS encap: transport + VPN label) → LSR1 → LSR2 → PE2 (MPLS decap) → CE2 (IP forward) → host2

End Host Addressing:

| Host  | IP Address | Gateway (CE) | CE LAN Subnet |
|-------|------------|--------------|---------------|
| host1 | 10.1.1.10  | 10.1.1.1 (CE1) | 10.1.1.0/24 |
| host2 | 10.1.2.10  | 10.1.2.1 (CE2) | 10.1.2.0/24 |

MPLS Label Assignments:

  Forward (PE1→PE2):  Transport labels 100→200→300, VPN labels: 500 (VRF 10), 700 (VRF 20), 900 (VRF 30)
  Return  (PE2→PE1):  Transport labels 400→401→402, VPN labels: 600 (VRF 10), 800 (VRF 20), 1000 (VRF 30)


------------------------------------------------------------
WHAT THIS LAB DEMONSTRATES
------------------------------------------------------------

- MPLS transport label switching (static LSPs)
- L3VPN using VRF with VPN label stacking
- **MP-BGP VPNv4** route exchange between PEs (FRR)
- **eBGP PE-CE** route learning (FRR)
- **FRR + VPP integration** — control plane + data plane separation
- VRF isolation: CE1↔CE2 (VRF 10), CE3↔CE4 (VRF 20), CE5↔CE6 (VRF 30)
- Cross-VRF traffic is blocked by design
- Overlapping IP addresses across VRFs (VRF 20 and VRF 30 use same CE IPs)
- End hosts with no MPLS/BGP knowledge — just IP + default route
- Route Distinguisher (RD) and Route Target (RT) for VPNv4

At ingress PE, packet format becomes:

| Transport Label | VPN Label | IP Packet |

Core LSRs perform label swap.
Egress PE pops transport label and forwards based on VPN label.


------------------------------------------------------------
BGP ASN AND VRF ASSIGNMENTS
------------------------------------------------------------

| Node     | ASN   | Role                       |
|----------|-------|----------------------------|
| PE1      | 65000 | Provider iBGP              |
| PE2      | 65000 | Provider iBGP              |
| CE1, CE2 | 65001 | Customer 1 (VRF 10)        |
| CE3, CE4 | 65002 | Customer 2 (VRF 20)        |
| CE5, CE6 | 65003 | Customer 3 (VRF 30)        |

| VRF    | RD        | Import RT  | Export RT  |
|--------|-----------|------------|------------|
| VRF 10 | 65000:10  | 65000:10   | 65000:10   |
| VRF 20 | 65000:20  | 65000:20   | 65000:20   |
| VRF 30 | 65000:30  | 65000:30   | 65000:30   |


------------------------------------------------------------
REQUIREMENTS
------------------------------------------------------------

- Docker
- Docker Compose
- Linux host (recommended)

Verify installation:

docker --version
docker-compose --version


------------------------------------------------------------
BRINGING UP THE LAB
------------------------------------------------------------

1) Build Custom VPP + FRR Image

chmod +x frr-vpp/build.sh
./frr-vpp/build.sh

This builds `vpp-frr:latest` from `frr-vpp/Dockerfile`.


2) Start Containers

docker-compose up -d

Verify containers:

docker ps

You should see 12 containers:
ce1, ce3, ce5, pe1, lsr1, lsr2, pe2, ce2, ce4, ce6, host1, host2


3) Program VPP + Start FRR

chmod +x setup.sh
./setup.sh

The script:
- Waits for VPP to be ready in all containers
- Creates VPP host interfaces and detects interface mapping
- **Syncs VPP af-packet MACs with Linux interface MACs** (prevents L3 MAC mismatch drops)
- Configures VRFs (10, 20, 30) on PE1 and PE2
- Installs static MPLS transport labels on LSRs
- Configures local CE LAN routes in VPP VRF tables
- Uses Docker `pe_mgmt` bridge network (10.255.0.0/24) for PE-PE iBGP peering
- Sets up Linux VRF devices for FRR per-VRF BGP instances
- Adds Linux blackhole routes to suppress false ICMP unreachable from kernel
- Starts FRR (zebra + bgpd) on all nodes
- Installs tools on end hosts and sets default routes
- Displays BGP session status


------------------------------------------------------------
VERIFICATION
------------------------------------------------------------

--- BGP Session Status ---

docker exec -it pe1 vtysh -c 'show bgp summary'
docker exec -it pe2 vtysh -c 'show bgp summary'

--- VPNv4 Routes (MP-iBGP between PEs) ---

docker exec -it pe1 vtysh -c 'show bgp ipv4 vpn'
docker exec -it pe2 vtysh -c 'show bgp ipv4 vpn'

--- Per-VRF BGP Routes ---

docker exec -it pe1 vtysh -c 'show bgp vrf VRF10 ipv4 unicast'
docker exec -it pe1 vtysh -c 'show bgp vrf VRF20 ipv4 unicast'
docker exec -it pe1 vtysh -c 'show bgp vrf VRF30 ipv4 unicast'

--- Test End-to-End Connectivity ---

docker exec -it ce1 vppctl ping 100.64.5.20    # VRF 10
docker exec -it ce3 vppctl ping 100.64.7.20    # VRF 20
docker exec -it ce5 vppctl ping 100.64.7.20    # VRF 30

--- End Host Connectivity (the real test!) ---

docker exec -it host1 ping -c 3 10.1.2.10      # host1 → host2 across MPLS core
docker exec -it host2 ping -c 3 10.1.1.10      # host2 → host1 across MPLS core
docker exec -it host1 traceroute 10.1.2.10      # trace path through MPLS
docker exec -it host1 ping -c 3 10.1.1.1       # host1 → CE1 gateway (sanity check)

--- Check MPLS FIB ---

docker exec -it pe1 vppctl show mpls fib
docker exec -it lsr1 vppctl show mpls fib

--- Check VPP IP FIB per VRF ---

docker exec -it pe1 vppctl show ip fib table 10
docker exec -it pe1 vppctl show ip fib table 20

--- Packet Trace ---

docker exec -it pe1 vppctl trace add af-packet-input 10
docker exec -it ce1 vppctl ping 100.64.5.20
docker exec -it pe1 vppctl show trace


------------------------------------------------------------
CLEANUP
------------------------------------------------------------

Stop and remove containers:

docker-compose down

Remove networks and volumes:

docker-compose down -v


------------------------------------------------------------
HOW IT WORKS
------------------------------------------------------------

Transport Labels (Static):

PE1  : Push transport + VPN label
LSR1 : Swap 100 -> 200
LSR2 : Swap 200 -> 300
PE2  : Pop transport label

VPN Label:

- PE2 allocates VPN label (e.g., 500)
- PE1 pushes:
    Outer label = transport
    Inner label = VPN
- PE2 forwards inside VRF


------------------------------------------------------------
CONCEPTS PRACTICED
------------------------------------------------------------

- MPLS label stack processing
- VRF separation
- MPLS FIB vs IP FIB
- Static LSP programming
- Label swap vs pop behavior
- Docker-based network emulation


------------------------------------------------------------
NOTES
------------------------------------------------------------

- Transport labels (LSR swap) are still static — Phase 3 would add LDP.
- VPN routes are exchanged via MP-BGP VPNv4 (FRR bgpd).
- VPN labels currently use static fallback alongside FRR auto-allocation.
- PE-CE routes are learned via eBGP.
- FRR communicates with VPP indirectly via Linux netlink (zebra → kernel → VPP af-packet).
- Docker bridge networks emulate point-to-point links.
- PE-PE iBGP peers via a dedicated `pe_mgmt` Docker bridge (10.255.0.0/24) — this
  bypasses the MPLS core because VPP af-packet intercepts transit IP packets on LSRs,
  preventing multi-hop Linux IP forwarding for the BGP TCP session.
- **af-packet MAC sync**: VPP auto-generates `02:fe:*` MACs for af-packet interfaces,
  but Docker assigns different MACs to Linux veth interfaces. Remote nodes ARP against
  the Linux MAC, causing VPP "l3 mac mismatch" drops. Fix: `setup.sh` syncs VPP MACs
  to match Linux MACs on every interface.
- **af-packet packet duplication**: Both VPP and Linux see every packet on af-packet
  interfaces. This causes duplicate ping replies (DUP!) — a cosmetic issue that doesn't
  affect functionality. Linux blackhole routes prevent false ICMP unreachable generation.
- FRR 10.5.1 enforces `ebgp-requires-policy` by default — CE configs use
  `no bgp ebgp-requires-policy` to allow route exchange without explicit route-maps.


------------------------------------------------------------
SUGGESTED EXTENSIONS (FUTURE PHASES)
------------------------------------------------------------

- Phase 3: Add LDP for transport label distribution
- Phase 4: Add RSVP-TE for traffic-engineered LSPs
- Implement Penultimate Hop Popping (PHP)
- Add SR-MPLS (Segment Routing)
- Add ECMP path
- MPLS-over-GRE for remote security device insertion
- Route Reflector (RR) for scalable iBGP
- Convert to containerlab topology
- Automate via Makefile or CI pipeline


------------------------------------------------------------
PROJECT STRUCTURE
------------------------------------------------------------

.
├── docker-compose.yaml    # 12 containers, 12 bridge networks
├── setup.sh               # VPP data plane + FRR startup + host setup script
├── Readme.md
├── validation.md          # Packet traces and verification
├── frr-vpp/
│   ├── Dockerfile         # VPP + FRR combined image
│   ├── entrypoint.sh      # Starts VPP then FRR
│   └── build.sh           # Build script for vpp-frr:latest
└── frr-configs/
    ├── pe1.conf            # MP-iBGP + eBGP (VRF 10/20/30)
    ├── pe2.conf            # MP-iBGP + eBGP (VRF 10/20/30)
    ├── ce1.conf            # eBGP ASN 65001
    ├── ce2.conf            # eBGP ASN 65001
    ├── ce3.conf            # eBGP ASN 65002
    ├── ce4.conf            # eBGP ASN 65002
    ├── ce5.conf            # eBGP ASN 65003
    ├── ce6.conf            # eBGP ASN 65003
    ├── lsr1.conf           # Minimal (no BGP)
    └── lsr2.conf           # Minimal (no BGP)


------------------------------------------------------------
LEARNING GOALS
------------------------------------------------------------

- Understand MPLS dataplane behavior (VPP)
- Study label stack operations (transport + VPN)
- **MP-BGP VPNv4 route exchange** between PEs
- **eBGP PE-CE route learning** with FRR
- **Control plane / data plane separation** (FRR + VPP)
- **End-to-end host connectivity** across MPLS/VPN backbone
- VRF isolation with Route Distinguisher and Route Target
- Practice PE/LSR/CE role separation
- Deep dataplane + control plane debugging
