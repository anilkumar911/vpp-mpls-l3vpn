# VPP MPLS L3VPN Docker Lab

This project builds a complete MPLS L3VPN lab using VPP instances running inside Docker containers.

Topology includes:
- 2 Provider Edge (PE) routers
- 2 Label Switch Routers (LSR)
- 6 Customer Edge (CE) routers (2 per VRF)

VRF Assignment:
- VRF 10: CE1 (PE1 side) ↔ CE2 (PE2 side)
- VRF 20: CE3 (PE1 side) ↔ CE4 (PE2 side)
- VRF 30: CE5 (PE1 side) ↔ CE6 (PE2 side) — same IPs as VRF 20!

All nodes run FD.io VPP.

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

MPLS Label Assignments:

  Forward (PE1→PE2):  Transport labels 100→200→300, VPN labels: 500 (VRF 10), 700 (VRF 20), 900 (VRF 30)
  Return  (PE2→PE1):  Transport labels 400→401→402, VPN labels: 600 (VRF 10), 800 (VRF 20), 1000 (VRF 30)


------------------------------------------------------------
WHAT THIS LAB DEMONSTRATES
------------------------------------------------------------

- MPLS transport label switching
- Static LSP configuration in VPP
- L3VPN using VRF
- VPN label allocation
- MPLS label stacking (Transport + VPN label)
- End-to-end CE-to-CE connectivity across MPLS core
- VRF isolation: CE1↔CE2 (VRF 10), CE3↔CE4 (VRF 20), CE5↔CE6 (VRF 30) are isolated
- Cross-VRF traffic is blocked by design
- Overlapping IP addresses across VRFs (VRF 20 and VRF 30 use same CEs IPs)

At ingress PE, packet format becomes:

| Transport Label | VPN Label | IP Packet |

Core LSRs perform label swap.
Egress PE pops transport label and forwards based on VPN label.


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

1) Start Containers

docker-compose up -d

Verify containers:

docker ps

You should see:
ce1, pe1, lsr1, lsr2, pe2, ce2


2) Program VPP Configuration

Make script executable:

chmod +x setup.sh

Run:

./setup.sh

The script:
- Enables MPLS
- Configures interfaces
- Creates VRFs
- Installs static MPLS label bindings
- Installs VPN label
- Configures CE routing


------------------------------------------------------------
VERIFICATION
------------------------------------------------------------

Test end-to-end connectivity from CE1:

docker exec -it ce1 vppctl ping 100.64.5.20


Check MPLS FIB:

docker exec -it pe1 vppctl show mpls fib
docker exec -it lsr1 vppctl show mpls fib
docker exec -it lsr2 vppctl show mpls fib


Check IP FIB:

docker exec -it pe1 vppctl show ip fib


Run Packet Trace (example on PE1):

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

- This lab uses static MPLS LSPs.
- No LDP or BGP control plane is used.
- Label values are manually assigned.
- Docker bridge networks emulate point-to-point links.


------------------------------------------------------------
SUGGESTED EXTENSIONS
------------------------------------------------------------

- Implement Penultimate Hop Popping (PHP)
- Add SR-MPLS
- Add BGP VPNv4 between PEs
- Add ECMP path
- Measure performance under load
- Convert to containerlab topology
- Automate via Makefile or CI pipeline


------------------------------------------------------------
PROJECT STRUCTURE
------------------------------------------------------------

.
├── docker-compose.yml
├── program_vpp.sh
└── README.md


------------------------------------------------------------
LEARNING GOALS
------------------------------------------------------------

- Understand MPLS dataplane behavior
- Study label stack operations
- Experiment with VPP MPLS internals
- Practice PE/LSR role separation
- Deep dataplane debugging practice
