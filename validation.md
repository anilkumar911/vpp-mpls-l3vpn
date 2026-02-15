# MPLS L3VPN Lab — Validation & Packet Walk-through

This document traces ICMP pings through the MPLS core, showing what happens at every hop.
It covers VRF 10 (CE1↔CE2), VRF 20 (CE3↔CE4), VRF 30 (CE5↔CE6), and cross-VRF isolation.
VRF 30 uses the same IP addresses as VRF 20, demonstrating overlapping address support.

---

## 1. End-to-End Ping Test

```
docker exec -it ce1 vppctl ping 100.64.5.20
```

```
116 bytes from 100.64.5.20: icmp_seq=1 ttl=62 time=125.5075 ms
116 bytes from 100.64.5.20: icmp_seq=2 ttl=62 time=153.4125 ms

Statistics: 2 sent, 2 received, 0% packet loss
```

---

## 2. Label Path Summary

> **Note:** Sections 2-4 document the **Phase 2 direct PE1↔PE2 path** using transport
> labels 100→200→300 / 400→401→402. In Phase 3 (current), all inter-CE traffic is
> **redirected through PE-SEC for inline FW inspection**. The actual label path for
> host1→host2 is now: PE1 push [150][1100] → LSR1 → LSR2 → GRE → PE-SEC VRF 10 →
> FW → PE-SEC VRF 11 push [1500][500] → GRE → LSR2 → PE2. See **Sections 11-18**
> for the inline FW flow documentation.

### Forward Path (CE1 → CE2)

```
CE1                    PE1                    LSR1                   LSR2                   PE2                    CE2
 │                      │                      │                      │                      │                      │
 │  IP: 100.64.1.20     │                      │                      │                      │                      │
 │  -> 100.64.5.20      │                      │                      │                      │                      │
 │ ──────────────────> │                      │                      │                      │                      │
 │   (plain IP)         │  Push labels         │                      │                      │                      │
 │                      │  [100][500]           │                      │                      │                      │
 │                      │ ──────────────────> │                      │                      │                      │
 │                      │   MPLS [100][500]     │  Swap 100 -> 200     │                      │                      │
 │                      │                      │ ──────────────────> │                      │                      │
 │                      │                      │   MPLS [200][500]     │  Swap 200 -> 300     │                      │
 │                      │                      │                      │ ──────────────────> │                      │
 │                      │                      │                      │   MPLS [300][500]     │  Pop 300, Pop 500    │
 │                      │                      │                      │                      │  IP lookup VRF 10    │
 │                      │                      │                      │                      │ ──────────────────> │
 │                      │                      │                      │                      │   (plain IP)         │
```

### Return Path (CE2 → CE1)

```
CE2                    PE2                    LSR2                   LSR1                   PE1                    CE1
 │                      │                      │                      │                      │                      │
 │  IP: 100.64.5.20     │                      │                      │                      │                      │
 │  -> 100.64.1.20      │                      │                      │                      │                      │
 │ ──────────────────> │                      │                      │                      │                      │
 │   (plain IP)         │  Push labels         │                      │                      │                      │
 │                      │  [400][600]           │                      │                      │                      │
 │                      │ ──────────────────> │                      │                      │                      │
 │                      │   MPLS [400][600]     │  Swap 400 -> 401     │                      │                      │
 │                      │                      │ ──────────────────> │                      │                      │
 │                      │                      │   MPLS [401][600]     │  Swap 401 -> 402     │                      │
 │                      │                      │                      │ ──────────────────> │                      │
 │                      │                      │                      │   MPLS [402][600]     │  Pop 402, Pop 600    │
 │                      │                      │                      │                      │  IP lookup VRF 10    │
 │                      │                      │                      │                      │ ──────────────────> │
 │                      │                      │                      │                      │   (plain IP)         │
```

---

## 3. MPLS FIB Verification

### PE1 — VRF 10 Route (Label Push)

```
docker exec -i pe1 vppctl show ip fib table 10 100.64.5.0/24
```

```
100.64.5.0/24 fib:1 index:26
    100.64.2.20 host-eth1
    labels:[[100 pipe ttl:0 exp:0][500 pipe ttl:0 exp:0]]
 forwarding:   unicast-ip4-chain
    [0] mpls-label:[100:64:0:neos][500:64:0:eos]
        mpls via 100.64.2.20 host-eth1
```

**Action:** IP packet enters VRF 10 → push label stack [100 (transport)][500 (VPN)] → forward to LSR1 via host-eth1.

### PE1 — Return Path (Label Pop)

```
docker exec -i pe1 vppctl show mpls fib | grep -E "^(402|600):" -A 5
```

```
402:neos  → lookup in MPLS-VRF:0  (pop transport, look up inner VPN label)
600:eos   → lookup in ipv4-VRF:10 (pop VPN label, IP lookup in customer VRF)
```

---

### LSR1 — Label Swap

```
docker exec -i lsr1 vppctl show mpls fib | grep -E "^(100|401):" -A 5
```

```
100:neos  → swap to 200, forward via 100.64.3.20 host-eth1   (forward path)
401:neos  → swap to 402, forward via 100.64.2.10 host-eth0   (return path)
```

**Action:** Receive [100][500] → swap top label 100→200 → send [200][500] to LSR2.

---

### LSR2 — Label Swap

```
docker exec -i lsr2 vppctl show mpls fib | grep -E "^(200|400):" -A 5
```

```
200:neos  → swap to 300, forward via 100.64.4.20 host-eth1   (forward path)
400:neos  → swap to 401, forward via 100.64.3.10 host-eth0   (return path)
```

**Action:** Receive [200][500] → swap top label 200→300 → send [300][500] to PE2.

---

### PE2 — Label Pop & VRF Disposition

```
docker exec -i pe2 vppctl show mpls fib | grep -E "^(300|500):" -A 5
```

```
300:neos  → pop, MPLS lookup in VRF:0   (exposes inner VPN label 500)
500:eos   → pop, IP lookup in VRF:10    (plain IP, forward to CE2)
```

**Action:** Receive [300][500] → pop 300 → lookup 500 → pop 500 → IP lookup in VRF 10 → forward to CE2 via host-eth1.

### PE2 — Return Path (Label Push)

```
docker exec -i pe2 vppctl show ip fib table 10 100.64.1.0/24
```

```
100.64.1.0/24
    labels:[[400 pipe][600 pipe]]
    mpls via 100.64.4.10 host-eth0
```

---

## 4. Packet Traces (Per-Hop)

### How to capture traces

```bash
# Enable tracing on all core nodes
for node in pe1 lsr1 lsr2 pe2; do
  docker exec -i $node vppctl "clear trace"
  docker exec -i $node vppctl "trace add af-packet-input 50"
done

# Send one ping
docker exec -i ce1 vppctl "ping 100.64.5.20 repeat 1"

# Read traces
for node in pe1 lsr1 lsr2 pe2; do
  echo "=== $node ==="
  docker exec -i $node vppctl show trace max 2
done
```

---

### 4.1 PE1 — Ingress PE (ICMP Request: Push Labels)

```
docker exec -i pe1 vppctl show trace
```

```
ethernet-input
  IP4: 02:fe:aa:bf:49:bb -> 02:fe:cb:fc:ad:e2         ← CE1 MAC → PE1 MAC

ip4-input
  ICMP: 100.64.1.20 -> 100.64.5.20                    ← plain ICMP from CE1
    ttl 254, length 96

ip4-lookup
  fib 1                                                ← VRF 10 lookup

ip4-mpls-label-imposition-pipe
    mpls-header:[500:64:0:eos]                         ← inner VPN label pushed

mpls-output
  mpls via 100.64.2.20 host-eth1                       ← next-hop LSR1

host-eth1-output
  MPLS: 02:fe:19:08:cd:46 -> 02:fe:00:9a:c3:9b
  label 100 exp 0, s 0, ttl 64                         ← outer transport label
```

**Summary:** Plain IP received on host-eth0 (VRF 10) → label stack pushed [100][500] → sent out host-eth1.

---

### 4.2 LSR1 — Label Switch Router (Swap 100 → 200)

```
docker exec -i lsr1 vppctl show trace
```

```
ethernet-input
  MPLS: 02:fe:19:08:cd:46 -> 02:fe:00:9a:c3:9b        ← from PE1

mpls-input
  label 100 ttl 64 exp 0                               ← incoming transport label

mpls-lookup
  lookup fib index 0, label 100 eos 0                  ← non-EOS (VPN label below)

mpls-label-imposition-pipe
    mpls-header:[200:63:0:neos]                        ← swap: 100 → 200

mpls-output
  mpls via 100.64.3.20 host-eth1                       ← next-hop LSR2

host-eth1-output
  MPLS: 02:fe:29:b9:3b:d7 -> 02:fe:f2:60:15:8d
  label 200 exp 0, s 0, ttl 63                         ← TTL decremented 64→63
```

**Summary:** MPLS [100][500] received on host-eth0 → swap top label 100→200 → [200][500] sent out host-eth1.

---

### 4.3 LSR2 — Label Switch Router (Swap 200 → 300)

```
docker exec -i lsr2 vppctl show trace
```

```
ethernet-input
  MPLS: 02:fe:29:b9:3b:d7 -> 02:fe:f2:60:15:8d        ← from LSR1

mpls-input
  label 200 ttl 63 exp 0                               ← incoming transport label

mpls-lookup
  lookup fib index 0, label 200 eos 0                  ← non-EOS

mpls-label-imposition-pipe
    mpls-header:[300:62:0:neos]                        ← swap: 200 → 300

mpls-output
  mpls via 100.64.4.20 host-eth1                       ← next-hop PE2

host-eth1-output
  MPLS: 02:fe:a7:2f:e2:68 -> 02:fe:3b:13:cf:e3
  label 300 exp 0, s 0, ttl 62                         ← TTL decremented 63→62
```

**Summary:** MPLS [200][500] received on host-eth0 → swap top label 200→300 → [300][500] sent out host-eth1.

---

### 4.4 PE2 — Egress PE (Pop Labels, Forward to CE2)

```
docker exec -i pe2 vppctl show trace
```

```
ethernet-input
  MPLS: 02:fe:a7:2f:e2:68 -> 02:fe:3b:13:cf:e3        ← from LSR2

mpls-input
  label 300 ttl 62 exp 0                               ← incoming transport label

mpls-lookup
  label 300 eos 0                                      ← non-EOS → pop, MPLS lookup

lookup-mpls-dst
  hdr:[500:64:0:eos]                                   ← inner VPN label exposed

ip4-mpls-label-disposition-pipe
  ip4, pipe                                            ← pop VPN label, IP lookup

lookup-ip4-dst
  fib-index:1 addr:100.64.5.20                         ← VRF 10 lookup

ip4-rewrite
  via 100.64.5.20 host-eth1                            ← forward to CE2

host-eth1-output
  IP4: 02:fe:72:91:a3:e7 -> 02:fe:05:28:bd:b5
  ICMP: 100.64.1.20 -> 100.64.5.20
    ttl 252, length 96                                 ← original TTL minus hops
```

**Summary:** MPLS [300][500] received on host-eth0 → pop 300 → lookup 500 → pop 500 → plain IP → VRF 10 lookup → forwarded to CE2 via host-eth1.

---

### 4.5 PE2 — Return Path (ICMP Reply: Push Labels)

```
ethernet-input
  IP4: 02:fe:05:28:bd:b5 -> 02:fe:72:91:a3:e7          ← from CE2

ip4-input
  ICMP: 100.64.5.20 -> 100.64.1.20                     ← echo reply
    ttl 64, length 96

ip4-lookup
  fib 1                                                 ← VRF 10

ip4-mpls-label-imposition-pipe
    mpls-header:[600:64:0:eos]                          ← inner VPN label pushed

mpls-output
  mpls via 100.64.4.10 host-eth0                        ← next-hop LSR2

host-eth0-output
  MPLS: 02:fe:3b:13:cf:e3 -> 02:fe:a7:2f:e2:68
  label 400 exp 0, s 0, ttl 64                          ← outer transport label
```

**Summary:** ICMP reply enters VRF 10 → push [400][600] → sent out host-eth0 towards LSR2.

---

### 4.6 LSR2 — Return Path (Swap 400 → 401)

```
mpls-input
  label 400 ttl 64 exp 0

mpls-label-imposition-pipe
    mpls-header:[401:63:0:neos]                         ← swap: 400 → 401

host-eth0-output
  label 401 exp 0, s 0, ttl 63
```

---

### 4.7 LSR1 — Return Path (Swap 401 → 402)

```
mpls-input
  label 401 ttl 63 exp 0

mpls-label-imposition-pipe
    mpls-header:[402:62:0:neos]                         ← swap: 401 → 402

host-eth0-output
  label 402 exp 0, s 0, ttl 62
```

---

### 4.8 PE1 — Return Path (Pop Labels, Forward to CE1)

```
mpls-input
  label 402 ttl 62 exp 0                               ← transport label

lookup-mpls-dst
  hdr:[600:64:0:eos]                                   ← inner VPN label exposed

ip4-mpls-label-disposition-pipe
  ip4, pipe                                            ← pop VPN label

lookup-ip4-dst
  fib-index:1 addr:100.64.1.20                         ← VRF 10 lookup

ip4-rewrite
  via 100.64.1.20 host-eth0                            ← forward to CE1

host-eth0-output
  IP4: 02:fe:cb:fc:ad:e2 -> 02:fe:aa:bf:49:bb
  ICMP: 100.64.5.20 -> 100.64.1.20
    ttl 62                                             ← reply arrives at CE1
```

**Summary:** MPLS [402][600] received on host-eth1 → pop 402 → pop 600 → plain IP → VRF 10 → forwarded to CE1 via host-eth0.

---

## 5. VRF 20 — End-to-End Ping Test (CE3 → CE4)

```
docker exec -it ce3 vppctl ping 100.64.7.20
```

```
116 bytes from 100.64.7.20: icmp_seq=1 ttl=62 time=148.1324 ms
116 bytes from 100.64.7.20: icmp_seq=2 ttl=62 time=155.1288 ms
116 bytes from 100.64.7.20: icmp_seq=3 ttl=62 time=192.1404 ms
116 bytes from 100.64.7.20: icmp_seq=4 ttl=62 time=148.6823 ms
116 bytes from 100.64.7.20: icmp_seq=5 ttl=62 time=115.7605 ms

Statistics: 5 sent, 5 received, 0% packet loss
```

---

## 6. VRF 20 Label Path Summary

### Forward Path (CE3 → CE4)

```
CE3                    PE1                    LSR1                   LSR2                   PE2                    CE4
 │                      │                      │                      │                      │                      │
 │  IP: 100.64.6.20     │                      │                      │                      │                      │
 │  -> 100.64.7.20      │                      │                      │                      │                      │
 │ ──────────────────> │                      │                      │                      │                      │
 │   (plain IP)         │  Push labels         │                      │                      │                      │
 │                      │  [100][700]           │                      │                      │                      │
 │                      │ ──────────────────> │                      │                      │                      │
 │                      │   MPLS [100][700]     │  Swap 100 -> 200     │                      │                      │
 │                      │                      │ ──────────────────> │                      │                      │
 │                      │                      │   MPLS [200][700]     │  Swap 200 -> 300     │                      │
 │                      │                      │                      │ ──────────────────> │                      │
 │                      │                      │                      │   MPLS [300][700]     │  Pop 300, Pop 700    │
 │                      │                      │                      │                      │  IP lookup VRF 20    │
 │                      │                      │                      │                      │ ──────────────────> │
 │                      │                      │                      │                      │   (plain IP)         │
```

### Return Path (CE4 → CE3)

```
CE4                    PE2                    LSR2                   LSR1                   PE1                    CE3
 │                      │                      │                      │                      │                      │
 │  IP: 100.64.7.20     │                      │                      │                      │                      │
 │  -> 100.64.6.20      │                      │                      │                      │                      │
 │ ──────────────────> │                      │                      │                      │                      │
 │   (plain IP)         │  Push labels         │                      │                      │                      │
 │                      │  [400][800]           │                      │                      │                      │
 │                      │ ──────────────────> │                      │                      │                      │
 │                      │   MPLS [400][800]     │  Swap 400 -> 401     │                      │                      │
 │                      │                      │ ──────────────────> │                      │                      │
 │                      │                      │   MPLS [401][800]     │  Swap 401 -> 402     │                      │
 │                      │                      │                      │ ──────────────────> │                      │
 │                      │                      │                      │   MPLS [402][800]     │  Pop 402, Pop 800    │
 │                      │                      │                      │                      │  IP lookup VRF 20    │
 │                      │                      │                      │                      │ ──────────────────> │
 │                      │                      │                      │                      │   (plain IP)         │
```

> **Note:** VRF 20 uses the same transport labels (100/200/300 forward, 400/401/402 return) as VRF 10.
> Only the VPN label differs: 700 (forward) and 800 (return) vs VRF 10's 500/600.
> LSRs are VRF-unaware — they only swap transport labels and never see the VPN label.

---

## 7. VRF 20 Per-Hop Packet Traces

### 7.1 PE1 — MPLS Label Imposition (CE3 → Core)

```
> docker exec -i pe1 vppctl show trace
```

```
af-packet-input
  af_packet: hw_if_index 3 (host-eth2, CE3-facing)

ethernet-input
  IP4: 02:fe:af:58:b7:9c -> 02:fe:c6:65:86:42

ip4-input
  ICMP: 100.64.6.20 -> 100.64.7.20                     ← plain IP from CE3

ip4-lookup
  fib 2 (VRF 20)                                        ← VRF 20 lookup

ip4-mpls-label-imposition-pipe
  mpls-header:[700:64:0:eos]                             ← VPN label 700 pushed

mpls-output
  mpls via 100.64.2.20 host-eth0                         ← out core interface

host-eth0-output
  MPLS: label 100 exp 0, s 0, ttl 64                    ← transport label 100 on top
```

**Summary:** Plain IP from CE3 → VRF 20 lookup → push [100][700] → send to LSR1 via core.

### 7.2 LSR1 — Label Swap (100 → 200)

```
mpls-input
  MPLS: label 100 ttl 64 exp 0                          ← receives transport label 100

mpls-lookup
  label 100 eos 0                                        ← non-eos (VPN label below)

mpls-label-imposition-pipe
  mpls-header:[200:63:0:neos]                            ← swap 100 → 200, TTL decremented

host-eth0-output
  MPLS: label 200 exp 0, s 0, ttl 63                    ← forwarded to LSR2
```

**Summary:** Same swap as VRF 10 — LSR1 doesn't see or care about the VPN label beneath.

### 7.3 LSR2 — Label Swap (200 → 300)

```
mpls-input
  MPLS: label 200 ttl 63 exp 0                          ← receives transport label 200

mpls-lookup
  label 200 eos 0                                        ← non-eos

mpls-label-imposition-pipe
  mpls-header:[300:62:0:neos]                            ← swap 200 → 300, TTL decremented

host-eth0-output
  MPLS: label 300 exp 0, s 0, ttl 62                    ← forwarded to PE2
```

**Summary:** Transport swap 200 → 300. VPN label 700 still hidden underneath.

### 7.4 PE2 — MPLS Label Disposition (Core → CE4)

```
mpls-input
  MPLS: label 300 ttl 62 exp 0                          ← receives transport label 300

mpls-lookup
  label 300 eos 0                                        ← non-eos (pop transport)

lookup-mpls-dst
  fib-index:0 hdr:[700:64:0:eos]                        ← inner VPN label 700 exposed

ip4-mpls-label-disposition-pipe
  rpf-id:-1 ip4, pipe                                    ← pop VPN label 700

lookup-ip4-dst
  fib-index:2 addr:100.64.7.20                           ← IP lookup in VRF 20 (fib 2)

ip4-rewrite
  ipv4 via 100.64.7.20 host-eth2                         ← CE4-facing interface

host-eth2-output
  IP4: ICMP: 100.64.6.20 -> 100.64.7.20
    ttl 252                                              ← delivered as plain IP to CE4
```

**Summary:** MPLS [300][700] → pop 300 → pop 700 → VRF 20 IP lookup → forward to CE4.

### 7.5 PE2 — Return Path Label Imposition (CE4 → Core)

```
af-packet-input
  af_packet: hw_if_index 3 (host-eth2, CE4-facing)

ip4-input
  ICMP: 100.64.7.20 -> 100.64.6.20                     ← ICMP reply from CE4

ip4-lookup
  fib 2 (VRF 20)                                        ← VRF 20 lookup

ip4-mpls-label-imposition-pipe
  mpls-header:[800:64:0:eos]                             ← VPN label 800 pushed

mpls-output
  mpls via 100.64.4.10 host-eth0                         ← out core interface

host-eth0-output
  MPLS: label 400 exp 0, s 0, ttl 64                    ← transport label 400 on top
```

**Summary:** Reply from CE4 → VRF 20 lookup → push [400][800] → send to LSR2.

### 7.6 LSR2 — Return Swap (400 → 401)

```
mpls-input
  MPLS: label 400 ttl 64 exp 0

mpls-lookup
  label 400 eos 0

mpls-label-imposition-pipe
  mpls-header:[401:63:0:neos]                            ← swap 400 → 401

host-eth1-output
  MPLS: label 401 exp 0, s 0, ttl 63                    ← forwarded to LSR1
```

### 7.7 LSR1 — Return Swap (401 → 402)

```
mpls-input
  MPLS: label 401 ttl 63 exp 0

mpls-lookup
  label 401 eos 0

mpls-label-imposition-pipe
  mpls-header:[402:62:0:neos]                            ← swap 401 → 402

host-eth1-output
  MPLS: label 402 exp 0, s 0, ttl 62                    ← forwarded to PE1
```

### 7.8 PE1 — Return Disposition (Core → CE3)

```
mpls-input
  MPLS: label 402 ttl 62 exp 0                          ← receives transport label 402

mpls-lookup
  label 402 eos 0                                        ← non-eos (pop transport)

lookup-mpls-dst
  fib-index:0 hdr:[800:64:0:eos]                        ← inner VPN label 800 exposed

ip4-mpls-label-disposition-pipe
  rpf-id:-1 ip4, pipe                                    ← pop VPN label 800

lookup-ip4-dst
  fib-index:2 addr:100.64.6.20                           ← IP lookup in VRF 20 (fib 2)

ip4-rewrite
  ipv4 via 100.64.6.20 host-eth2                         ← CE3-facing interface

host-eth2-output
  IP4: ICMP: 100.64.7.20 -> 100.64.6.20
    ttl 62                                               ← reply arrives at CE3
```

**Summary:** MPLS [402][800] → pop 402 → pop 800 → VRF 20 IP lookup → forward to CE3.

---

## 8. VRF Isolation Verification

The key property of L3VPN is that VRFs provide traffic isolation. CEs in VRF 10 cannot
reach CEs in VRF 20, and vice versa, even though they share the same MPLS core.

### 8.1 CE1 (VRF 10) → CE4 (VRF 20) — MUST FAIL

```
docker exec -i ce1 vppctl ping 100.64.7.20 repeat 3
```

```
Failed: no egress interface
Failed: no egress interface
Failed: no egress interface

Statistics: 0 sent, 0 received, 0% packet loss
```

**Why:** CE1 is in VRF 10. Its default route points to PE1's VRF 10 interface (100.64.1.10).
PE1's VRF 10 routing table has no route for 100.64.7.0/24 (that route only exists in VRF 20).
CE1 doesn't even have a route for 100.64.7.0/24, so the packet is dropped at CE1 itself.

### 8.2 CE3 (VRF 20) → CE2 (VRF 10) — MUST FAIL

```
docker exec -i ce3 vppctl ping 100.64.5.20 repeat 3
```

```
Failed: no egress interface
Failed: no egress interface
Failed: no egress interface

Statistics: 0 sent, 0 received, 0% packet loss
```

**Why:** CE3 is in VRF 20. Its only route to remote subnets is for 100.64.7.0/24 via PE1's VRF 20
interface. There is no route for 100.64.5.0/24 in VRF 20, so the packet is dropped.

### 8.3 Isolation Summary

| Source | Destination | VRF Src | VRF Dst | Result | Reason |
|--------|-------------|---------|---------|--------|--------|
| CE1 (100.64.1.20) | CE2 (100.64.5.20) | 10 | 10 | **PASS** ✓ | Same VRF, MPLS path exists |
| CE3 (100.64.6.20) | CE4 (100.64.7.20) | 20 | 20 | **PASS** ✓ | Same VRF, MPLS path exists |
| CE1 (100.64.1.20) | CE4 (100.64.7.20) | 10 | 20 | **FAIL** ✗ | No egress — VRF isolation |
| CE3 (100.64.6.20) | CE2 (100.64.5.20) | 20 | 10 | **FAIL** ✗ | No egress — VRF isolation |
| CE5 (100.64.6.20) | CE2 (100.64.5.20) | 30 | 10 | **FAIL** ✗ | No egress — VRF isolation |
| CE1 (100.64.1.20) | CE6 (100.64.7.20) | 10 | 30 | **FAIL** ✗ | No egress — VRF isolation |

> **This is the fundamental value of MPLS L3VPN:** multiple customers share the same
> physical MPLS core network, but their traffic is completely isolated through VRF separation
> at the PE routers and distinct VPN labels in the MPLS data plane.

---

## 9. VRF 30 — Overlapping IP Addresses (CE5 ↔ CE6)

VRF 30 is the most interesting test case: CE5 and CE6 use **the same IP addresses** as
CE3 and CE4 in VRF 20 (100.64.6.20 and 100.64.7.20). This is possible because each VRF
maintains a completely independent routing table, and the MPLS data plane uses different
VPN labels (900/1000 for VRF 30 vs 700/800 for VRF 20).

### 9.1 End-to-End Ping Test

```
docker exec -it ce5 vppctl ping 100.64.7.20
```

```
116 bytes from 100.64.7.20: icmp_seq=1 ttl=62 time=170.5595 ms
116 bytes from 100.64.7.20: icmp_seq=2 ttl=62 time=200.2822 ms
116 bytes from 100.64.7.20: icmp_seq=3 ttl=62 time=178.5853 ms
116 bytes from 100.64.7.20: icmp_seq=4 ttl=62 time=186.6639 ms
116 bytes from 100.64.7.20: icmp_seq=5 ttl=62 time=174.2701 ms

Statistics: 5 sent, 5 received, 0% packet loss
```

### 9.2 Label Path

```
Forward:  CE5 → PE1 → [100][900] → LSR1 [200][900] → LSR2 [300][900] → PE2 → CE6
Return:   CE6 → PE2 → [400][1000] → LSR2 [401][1000] → LSR1 [402][1000] → PE1 → CE5
```

Same transport labels as VRF 10 and VRF 20 — LSRs are VRF-unaware.
Only the VPN label distinguishes which VRF the traffic belongs to.

### 9.3 The Key Demonstration: Same IP, Different Destination

Both CE3 and CE5 ping 100.64.7.20, but each reaches a **different physical host**:

```
# CE3 (VRF 20) pings 100.64.7.20 → reaches CE4

docker exec -it ce3 vppctl ping 100.64.7.20 repeat 3
```

```
116 bytes from 100.64.7.20: icmp_seq=1 ttl=62 time=172.8691 ms
116 bytes from 100.64.7.20: icmp_seq=2 ttl=62 time=182.3491 ms
116 bytes from 100.64.7.20: icmp_seq=3 ttl=62 time=180.4376 ms

Statistics: 3 sent, 3 received, 0% packet loss
```

```
# CE5 (VRF 30) pings 100.64.7.20 → reaches CE6

docker exec -it ce5 vppctl ping 100.64.7.20 repeat 3
```

```
116 bytes from 100.64.7.20: icmp_seq=1 ttl=62 time=134.2611 ms
116 bytes from 100.64.7.20: icmp_seq=2 ttl=62 time=161.5062 ms
116 bytes from 100.64.7.20: icmp_seq=3 ttl=62 time=188.5203 ms

Statistics: 3 sent, 3 received, 0% packet loss
```

**Why this works:**
- CE3's packet enters PE1 on the VRF 20 interface → IP lookup in VRF 20 → push [100][700]
- CE5's packet enters PE1 on the VRF 30 interface → IP lookup in VRF 30 → push [100][900]
- The VPN label (700 vs 900) determines which VRF PE2 delivers the packet to
- PE2 pops VPN label 700 → IP lookup in VRF 20 → forward to CE4
- PE2 pops VPN label 900 → IP lookup in VRF 30 → forward to CE6

> **This is a real-world SP scenario:** two different customers using identical RFC 1918
> addressing, both served by the same MPLS backbone, with zero IP conflict.

---

## 10. Quick Validation Commands Reference

| What                        | Command                                                        |
|-----------------------------|----------------------------------------------------------------|
| VRF 10: CE1 → CE2 ping     | `docker exec -it ce1 vppctl ping 100.64.5.20`                 |
| VRF 20: CE3 → CE4 ping     | `docker exec -it ce3 vppctl ping 100.64.7.20`                 |
| VRF 30: CE5 → CE6 ping     | `docker exec -it ce5 vppctl ping 100.64.7.20`                 |
| Cross-VRF: CE1 → CE4       | `docker exec -it ce1 vppctl ping 100.64.7.20` (should fail)   |
| Cross-VRF: CE3 → CE2       | `docker exec -it ce3 vppctl ping 100.64.5.20` (should fail)   |
| Cross-VRF: CE5 → CE2       | `docker exec -it ce5 vppctl ping 100.64.5.20` (should fail)   |
| PE1 MPLS FIB                | `docker exec -i pe1 vppctl show mpls fib`                     |
| LSR1 MPLS FIB               | `docker exec -i lsr1 vppctl show mpls fib`                    |
| LSR2 MPLS FIB               | `docker exec -i lsr2 vppctl show mpls fib`                    |
| PE2 MPLS FIB                | `docker exec -i pe2 vppctl show mpls fib`                     |
| PE1 VRF 10 routes           | `docker exec -i pe1 vppctl show ip fib table 10`              |
| PE1 VRF 20 routes           | `docker exec -i pe1 vppctl show ip fib table 20`              |
| PE1 VRF 30 routes           | `docker exec -i pe1 vppctl show ip fib table 30`              |
| PE2 VRF 10 routes           | `docker exec -i pe2 vppctl show ip fib table 10`              |
| PE2 VRF 20 routes           | `docker exec -i pe2 vppctl show ip fib table 20`              |
| PE2 VRF 30 routes           | `docker exec -i pe2 vppctl show ip fib table 30`              |
| Interface status (any node) | `docker exec -i <node> vppctl show interface`                  |
| Enable trace (any node)     | `docker exec -i <node> vppctl trace add af-packet-input 50`   |
| View trace (any node)       | `docker exec -i <node> vppctl show trace`                      |
| Clear trace (any node)      | `docker exec -i <node> vppctl clear trace`                     |
| ARP table (any node)        | `docker exec -i <node> vppctl show ip neighbor`               |


---

## 11. Inline FW Service Chaining — Architecture Overview

All inter-CE traffic across ALL VRFs (10, 20, 30) is steered through the centralized
firewall (FW) behind PE-SEC for security inspection. This is implemented using an
**ingress/egress VRF split** pattern on PE-SEC to avoid routing loops.

**Architecture:**

```
                              MPLS Core
host1 ── CE1 ═══ PE1 ═══ LSR1 ═══ LSR2 ═══ PE2 ═══ CE2 ── host2
                                    │
                            GRE Tunnel (MPLS-over-GRE)
                            203.0.113.1 ↔ 203.0.113.2
                            172.16.0.1/30 ↔ 172.16.0.2/30
                                    │
                                 PE-SEC
                    ┌───────────────┴───────────────┐
                    │  Ingress VRFs    Egress VRFs   │
                    │  VRF 10 ──→    ──→ VRF 11     │
                    │  VRF 20 ──→    ──→ VRF 21     │
                    │  VRF 30 ──→    ──→ VRF 31     │
                    └───────┬───────────────┬───────┘
                            │               │
                         ingress         egress
                            │               │
                    ┌───────┴───────────────┴───────┐
                    │              FW                │
                    │  VRF 10: in 100.64.100.20      │
                    │          out 100.64.101.20     │
                    │          LAN 10.100.1.1        │
                    │  VRF 20: in 100.64.102.20      │
                    │          out 100.64.103.20     │
                    │  VRF 30: in 100.64.104.20      │
                    │          out 100.64.105.20     │
                    └───────────────┬───────────────┘
                                    │
                               sec-host (10.100.1.10)
```

**Service Chain Flow (per VRF):**
```
  MPLS core ──[pop VPN label]──→ PE-SEC Ingress VRF ──→ FW ingress interface
                                                              │
                                                         FW inspects
                                                              │
  MPLS core ←──[push MPLS labels]── PE-SEC Egress VRF ←── FW egress interface
```

**Why ingress/egress VRF split?**
Without separate VRFs, when FW sends inspected traffic back to PE-SEC, the same
VRF routing table would send it right back to FW (routing loop). The egress VRF
has different routes — pointing to the actual destination PEs via MPLS labels.

**GRE Tunnel:**
- LSR2 side: `gre0` — src 203.0.113.1, dst 203.0.113.2, point-to-point 172.16.0.1/30, MPLS enabled
- PE-SEC side: `gre0` — src 203.0.113.2, dst 203.0.113.1, point-to-point 172.16.0.2/30, MPLS enabled

**BGP Peering:**
- PE-SEC (ASN 65000) ↔ PE1, PE2: MP-iBGP VPNv4 (via pe_mgmt 10.255.0.0/24)
- FW (ASN 65010) ↔ PE-SEC: Per-VRF eBGP (VRF 10: 100.64.100.x, VRF 20: 100.64.102.x, VRF 30: 100.64.104.x)

**PE-SEC VPN Labels (VRF mapping):**

| VPN Label | Ingress VRF | Egress VRF | Customer              |
|-----------|-------------|------------|-----------------------|
| 1100      | VRF 10      | VRF 11     | CE1↔CE2, sec-host     |
| 1200      | VRF 20      | VRF 21     | CE3↔CE4               |
| 1250      | VRF 30      | VRF 31     | CE5↔CE6               |

---

### 11.1 GRE Tunnel Verification

```bash
# LSR2 GRE tunnel
docker exec -i lsr2 vppctl show gre tunnel
# Expected: src 203.0.113.1 dst 203.0.113.2

# PE-SEC GRE tunnel
docker exec -i pe-sec vppctl show gre tunnel
# Expected: src 203.0.113.2 dst 203.0.113.1

# Transport: GRE MPLS label (PE-SEC receives)
docker exec -i pe-sec vppctl show mpls fib 310
# Expected: 310 non-eos → MPLS lookup
```

### 11.2 PE-SEC VRF Verification

```bash
# Check all 6 VRFs on PE-SEC
docker exec -i pe-sec vppctl show ip fib table 10   # Ingress VRF 10
docker exec -i pe-sec vppctl show ip fib table 11   # Egress VRF 11
docker exec -i pe-sec vppctl show ip fib table 20   # Ingress VRF 20
docker exec -i pe-sec vppctl show ip fib table 21   # Egress VRF 21
docker exec -i pe-sec vppctl show ip fib table 30   # Ingress VRF 30
docker exec -i pe-sec vppctl show ip fib table 31   # Egress VRF 31

# Check VPN label mappings
docker exec -i pe-sec vppctl show mpls fib 1100   # → VRF 10
docker exec -i pe-sec vppctl show mpls fib 1200   # → VRF 20
docker exec -i pe-sec vppctl show mpls fib 1250   # → VRF 30
```

### 11.3 FW VRF Verification

```bash
# Check FW has 3 VRFs
docker exec -i fw vppctl show ip fib table 10   # VRF 10 (+ sec-host LAN)
docker exec -i fw vppctl show ip fib table 20   # VRF 20
docker exec -i fw vppctl show ip fib table 30   # VRF 30

# Check per-VRF BGP sessions
docker exec -i fw vtysh -c 'show bgp vrf VRF10 summary'
docker exec -i fw vtysh -c 'show bgp vrf VRF20 summary'
docker exec -i fw vtysh -c 'show bgp vrf VRF30 summary'
```

### 11.4 BGP Session Status

```bash
# PE-SEC MP-iBGP status
docker exec -i pe-sec vtysh -c 'show bgp summary'
# Expected: PE1 (10.255.0.1) and PE2 (10.255.0.2) sessions Established

# PE-SEC per-VRF eBGP with FW
docker exec -i pe-sec vtysh -c 'show bgp vrf VRF10 summary'
# Expected: FW (100.64.100.20) Established

docker exec -i pe-sec vtysh -c 'show bgp vrf VRF20 summary'
# Expected: FW (100.64.102.20) Established

docker exec -i pe-sec vtysh -c 'show bgp vrf VRF30 summary'
# Expected: FW (100.64.104.20) Established
```

---

## 12. Inline FW End-to-End Connectivity Tests

All inter-CE pings now traverse the FW for security inspection. The traffic flow is:
Source CE → Source PE → LSR(s) → GRE → PE-SEC (ingress VRF) → FW → PE-SEC (egress VRF) → GRE → LSR(s) → Dest PE → Dest CE

### 12.1 host1 → host2 (VRF 10, via inline FW)

```bash
docker exec -it host1 ping -c 3 10.1.2.10
# Expected: 3 packets received (traffic hairpins through PE-SEC → FW → PE-SEC)
# Path: host1 → CE1 → PE1 →[150][1100]→ LSR1 → LSR2 → GRE → PE-SEC VRF10 → FW → PE-SEC VRF11 →[1500][500]→ GRE → LSR2 → PE2 → CE2 → host2
```

### 12.2 host2 → host1 (VRF 10, via inline FW)

```bash
docker exec -it host2 ping -c 3 10.1.1.10
# Expected: 3 packets received
# Path: host2 → CE2 → PE2 →[1300][1100]→ LSR2 → GRE → PE-SEC VRF10 → FW → PE-SEC VRF11 →[1400][600]→ GRE → LSR2 → LSR1 → PE1 → CE1 → host1
```

### 12.3 sec-host → host1 (VRF 10, direct via FW)

```bash
docker exec -it sec-host ping -c 3 10.1.1.10
# Expected: 3 packets received
# Path: sec-host → FW VRF10 → PE-SEC VRF11 →[1400][600]→ GRE → LSR2 → LSR1 → PE1 → CE1 → host1
```

### 12.4 sec-host → host2 (VRF 10, direct via FW)

```bash
docker exec -it sec-host ping -c 3 10.1.2.10
# Expected: 3 packets received
# Path: sec-host → FW VRF10 → PE-SEC VRF11 →[1500][500]→ GRE → LSR2 → PE2 → CE2 → host2
```

### 12.5 host1 → sec-host (VRF 10, via inline FW)

```bash
docker exec -it host1 ping -c 3 10.100.1.10
# Expected: 3 packets received
# Path: host1 → CE1 → PE1 →[150][1100]→ LSR1 → LSR2 → GRE → PE-SEC VRF10 → FW VRF10 → sec-host (local delivery)
```

### 12.6 CE3 → CE4 (VRF 20, via inline FW)

```bash
docker exec -it ce3 vppctl ping 100.64.7.20
# Expected: replies received
# Path: CE3 → PE1 →[150][1200]→ LSR1 → LSR2 → GRE → PE-SEC VRF20 → FW VRF20 → PE-SEC VRF21 →[1500][700]→ GRE → LSR2 → PE2 → CE4
```

### 12.7 CE5 → CE6 (VRF 30, via inline FW)

```bash
docker exec -it ce5 vppctl ping 100.64.7.20
# Expected: replies received
# Path: CE5 → PE1 →[150][1250]→ LSR1 → LSR2 → GRE → PE-SEC VRF30 → FW VRF30 → PE-SEC VRF31 →[1500][900]→ GRE → LSR2 → PE2 → CE6
```

### 12.8 Connectivity Summary

| Test | VRF | Path via FW | Expected |
|------|-----|-------------|----------|
| host1 → host2 | 10 | PE1 → PE-SEC → FW → PE-SEC → PE2 | ✓ Pass |
| host2 → host1 | 10 | PE2 → PE-SEC → FW → PE-SEC → PE1 | ✓ Pass |
| sec-host → host1 | 10 | FW → PE-SEC → PE1 | ✓ Pass |
| sec-host → host2 | 10 | FW → PE-SEC → PE2 | ✓ Pass |
| host1 → sec-host | 10 | PE1 → PE-SEC → FW (local) | ✓ Pass |
| CE3 → CE4 | 20 | PE1 → PE-SEC → FW → PE-SEC → PE2 | ✓ Pass |
| CE4 → CE3 | 20 | PE2 → PE-SEC → FW → PE-SEC → PE1 | ✓ Pass |
| CE5 → CE6 | 30 | PE1 → PE-SEC → FW → PE-SEC → PE2 | ✓ Pass |
| CE6 → CE5 | 30 | PE2 → PE-SEC → FW → PE-SEC → PE1 | ✓ Pass |

---

## 13. Inline FW Label Path Diagrams

### 13.1 Forward: host1 → host2 (VRF 10, via FW)

```
CE1     PE1      LSR1     LSR2     GRE   PE-SEC    FW    PE-SEC    GRE   LSR2     PE2      CE2
 │       │        │        │        │   (VRF10)    │   (VRF11)     │      │        │        │
 │ IP    │        │        │        │      │       │      │        │      │        │        │
 │──────>│        │        │        │      │       │      │        │      │        │        │
 │       │ Push   │        │        │      │       │      │        │      │        │        │
 │       │[150]   │        │        │      │       │      │        │      │        │        │
 │       │[1100]  │        │        │      │       │      │        │      │        │        │
 │       │───────>│        │        │      │       │      │        │      │        │        │
 │       │        │ Swap   │        │      │       │      │        │      │        │        │
 │       │        │[250]   │        │      │       │      │        │      │        │        │
 │       │        │[1100]  │        │      │       │      │        │      │        │        │
 │       │        │───────>│        │      │       │      │        │      │        │        │
 │       │        │        │Swap+GRE│      │       │      │        │      │        │        │
 │       │        │        │[310]   │      │       │      │        │      │        │        │
 │       │        │        │[1100]  │      │       │      │        │      │        │        │
 │       │        │        │───────>│      │       │      │        │      │        │        │
 │       │        │        │        │ Pop  │       │      │        │      │        │        │
 │       │        │        │        │VRF10 │       │      │        │      │        │        │
 │       │        │        │        │─────>│       │      │        │      │        │        │
 │       │        │        │        │      │ fwd   │      │        │      │        │        │
 │       │        │        │        │      │──────>│      │        │      │        │        │
 │       │        │        │        │      │       │ dflt │        │      │        │        │
 │       │        │        │        │      │       │route │        │      │        │        │
 │       │        │        │        │      │       │─────>│        │      │        │        │
 │       │        │        │        │      │       │      │ Push   │      │        │        │
 │       │        │        │        │      │       │      │[1500]  │      │        │        │
 │       │        │        │        │      │       │      │[500]   │      │        │        │
 │       │        │        │        │      │       │      │───────>│      │        │        │
 │       │        │        │        │      │       │      │        │ Swap │        │        │
 │       │        │        │        │      │       │      │        │[1501]│        │        │
 │       │        │        │        │      │       │      │        │[500] │        │        │
 │       │        │        │        │      │       │      │        │─────>│        │        │
 │       │        │        │        │      │       │      │        │      │ Pop    │        │
 │       │        │        │        │      │       │      │        │      │ VRF10  │        │
 │       │        │        │        │      │       │      │        │      │───────>│        │
 │       │        │        │        │      │       │      │        │      │        │ IP fwd │
 │       │        │        │        │      │       │      │        │      │        │───────>│
```

### 13.2 Forward: CE3 → CE4 (VRF 20, via FW)

```
Label path:  PE1 push [150][1200] → LSR1 swap [250][1200] → LSR2 swap+GRE [310][1200]
             → PE-SEC pop → VRF 20 → FW VRF 20 → inspect → default route
             → PE-SEC VRF 21 push [1500][700] → GRE → LSR2 swap [1501][700]
             → PE2 pop → VRF 20 → CE4
```

### 13.3 Return: CE4 → CE3 (VRF 20, via FW)

```
Label path:  PE2 push [1300][1200] → LSR2 swap+GRE [310][1200]
             → PE-SEC pop → VRF 20 → FW VRF 20 → inspect → default route
             → PE-SEC VRF 21 push [1400][800] → GRE → LSR2 swap [1401][800]
             → LSR1 swap [1402][800] → PE1 pop → VRF 20 → CE3
```

### 13.4 Forward: CE5 → CE6 (VRF 30, via FW — same IPs as VRF 20!)

```
Label path:  PE1 push [150][1250] → LSR1 swap [250][1250] → LSR2 swap+GRE [310][1250]
             → PE-SEC pop → VRF 30 → FW VRF 30 → inspect → default route
             → PE-SEC VRF 31 push [1500][900] → GRE → LSR2 swap [1501][900]
             → PE2 pop → VRF 30 → CE6

Note: VPN label 1250 (VRF 30) vs 1200 (VRF 20) ensures PE-SEC places traffic in
the correct VRF, even though CE5/CE6 use the same IP addresses as CE3/CE4.
```

### 13.5 Return: CE6 → CE5 (VRF 30, via FW)

```
Label path:  PE2 push [1300][1250] → LSR2 swap+GRE [310][1250]
             → PE-SEC pop → VRF 30 → FW VRF 30 → inspect → default route
             → PE-SEC VRF 31 push [1400][1000] → GRE → LSR2 swap [1401][1000]
             → LSR1 swap [1402][1000] → PE1 pop → VRF 30 → CE5
```

---

## 14. Inline FW MPLS FIB Verification

### 14.1 PE1 — Forward Routes to PE-SEC (All VRFs)

PE1 pushes PE-SEC VPN labels instead of direct PE2 labels:

```bash
docker exec -i pe1 vppctl show ip fib table 10
# 100.64.5.0/24 → via 100.64.2.20 out-labels [150][1100]  (was [100][500] in Phase 2)
# 10.1.2.0/24   → via 100.64.2.20 out-labels [150][1100]  (was [100][500] in Phase 2)

docker exec -i pe1 vppctl show ip fib table 20
# 100.64.7.0/24 → via 100.64.2.20 out-labels [150][1200]  (was [100][700] in Phase 2)

docker exec -i pe1 vppctl show ip fib table 30
# 100.64.7.0/24 → via 100.64.2.20 out-labels [150][1250]  (was [100][900] in Phase 2)
```

> **Key change:** Transport label 150 (→ PE-SEC) replaces 100 (→ PE2 direct).
> VPN labels 1100/1200/1250 (PE-SEC) replace 500/700/900 (PE2).

### 14.2 PE2 — Forward Routes to PE-SEC (All VRFs)

```bash
docker exec -i pe2 vppctl show ip fib table 10
# 100.64.1.0/24 → via 100.64.4.10 out-labels [1300][1100]  (was [400][600] in Phase 2)
# 10.1.1.0/24   → via 100.64.4.10 out-labels [1300][1100]  (was [400][600] in Phase 2)

docker exec -i pe2 vppctl show ip fib table 20
# 100.64.6.0/24 → via 100.64.4.10 out-labels [1300][1200]  (was [400][800] in Phase 2)

docker exec -i pe2 vppctl show ip fib table 30
# 100.64.6.0/24 → via 100.64.4.10 out-labels [1300][1250]  (was [400][1000] in Phase 2)
```

### 14.3 PE-SEC — VPN Label Disposition

```bash
docker exec -i pe-sec vppctl show mpls fib
# Label 1100 eos → ip4-lookup-in-table 10 (VRF 10 ingress)
# Label 1200 eos → ip4-lookup-in-table 20 (VRF 20 ingress)
# Label 1250 eos → ip4-lookup-in-table 30 (VRF 30 ingress)
```

### 14.4 PE-SEC — Ingress VRF Routes (→ FW)

```bash
# VRF 10 ingress: all remote subnets point to FW ingress interface
docker exec -i pe-sec vppctl show ip fib table 10
# 10.1.1.0/24   → via 100.64.100.20  (FW VRF 10 ingress)
# 10.1.2.0/24   → via 100.64.100.20  (FW VRF 10 ingress)
# 100.64.1.0/24 → via 100.64.100.20  (FW VRF 10 ingress)
# 100.64.5.0/24 → via 100.64.100.20  (FW VRF 10 ingress)
# 10.100.1.0/24 → via 100.64.100.20  (FW VRF 10 ingress / local delivery)

# VRF 20 ingress:
docker exec -i pe-sec vppctl show ip fib table 20
# 100.64.6.0/24 → via 100.64.102.20  (FW VRF 20 ingress)
# 100.64.7.0/24 → via 100.64.102.20  (FW VRF 20 ingress)

# VRF 30 ingress:
docker exec -i pe-sec vppctl show ip fib table 30
# 100.64.6.0/24 → via 100.64.104.20  (FW VRF 30 ingress)
# 100.64.7.0/24 → via 100.64.104.20  (FW VRF 30 ingress)
```

### 14.5 PE-SEC — Egress VRF Routes (→ MPLS core)

```bash
# VRF 11 egress: routes to actual destination PEs
docker exec -i pe-sec vppctl show ip fib table 11
# 10.1.1.0/24   → via 172.16.0.1 gre0 out-labels [1400][600]   (→ PE1 VRF 10)
# 100.64.1.0/24 → via 172.16.0.1 gre0 out-labels [1400][600]   (→ PE1 VRF 10)
# 10.1.2.0/24   → via 172.16.0.1 gre0 out-labels [1500][500]   (→ PE2 VRF 10)
# 100.64.5.0/24 → via 172.16.0.1 gre0 out-labels [1500][500]   (→ PE2 VRF 10)

# VRF 21 egress:
docker exec -i pe-sec vppctl show ip fib table 21
# 100.64.6.0/24 → via 172.16.0.1 gre0 out-labels [1400][800]   (→ PE1 VRF 20)
# 100.64.7.0/24 → via 172.16.0.1 gre0 out-labels [1500][700]   (→ PE2 VRF 20)

# VRF 31 egress:
docker exec -i pe-sec vppctl show ip fib table 31
# 100.64.6.0/24 → via 172.16.0.1 gre0 out-labels [1400][1000]  (→ PE1 VRF 30)
# 100.64.7.0/24 → via 172.16.0.1 gre0 out-labels [1500][900]   (→ PE2 VRF 30)
```

### 14.6 FW — Per-VRF Default Routes

```bash
# FW VRF 10: default → PE-SEC VRF 11 egress
docker exec -i fw vppctl show ip fib table 10
# 0.0.0.0/0 → via 100.64.101.1  (PE-SEC VRF 11)
# 10.100.1.0/24 → connected (sec-host LAN)

# FW VRF 20: default → PE-SEC VRF 21 egress
docker exec -i fw vppctl show ip fib table 20
# 0.0.0.0/0 → via 100.64.103.1  (PE-SEC VRF 21)

# FW VRF 30: default → PE-SEC VRF 31 egress
docker exec -i fw vppctl show ip fib table 30
# 0.0.0.0/0 → via 100.64.105.1  (PE-SEC VRF 31)
```

### 14.7 LSR Transport Labels (unchanged from Phase 2)

Transport labels are VRF-agnostic — they carry any VPN label:

```bash
docker exec -i lsr1 vppctl show mpls fib
# 150 → swap 250 (PE1 → PE-SEC direction, all VRFs)
# 1401 → swap 1402 (PE-SEC → PE1 return, all VRFs)

docker exec -i lsr2 vppctl show mpls fib
# 250 → swap 310 via GRE (PE1 → PE-SEC via GRE tunnel)
# 1300 → swap 310 via GRE (PE2 → PE-SEC via GRE tunnel)
# 1400 → swap 1401 (PE-SEC → PE1 via LSR1)
# 1500 → swap 1501 (PE-SEC → PE2 direct)
```

---

## 15. Inline FW Per-Hop Packet Traces

### 15.1 PE1 — Ingress (host1 → host2: Push [150][1100], via PE-SEC)

```bash
docker exec -i pe1 vppctl clear trace
docker exec -i pe1 vppctl trace add af-packet-input 50
docker exec -it host1 ping -c 1 10.1.2.10
docker exec -i pe1 vppctl show trace
```

Expected trace:
```
af-packet-input:
  host-ethX (CE1-facing)
  IP4: 10.1.1.10 → 10.1.2.10, ICMP echo request
ip4-lookup:
  fib 10 (VRF 10)
  adj: via 100.64.2.20 host-ethX out-labels [150][1100]
mpls-output:
  Push [150 non-eos][1100 eos]
  → LSR1 (100.64.2.20)
```

### 15.2 PE-SEC — GRE Decap, VPN Pop → VRF 10 → FW

```bash
docker exec -i pe-sec vppctl clear trace
docker exec -i pe-sec vppctl trace add gre4-input 50
docker exec -i pe-sec vppctl trace add af-packet-input 50
docker exec -it host1 ping -c 1 10.1.2.10
docker exec -i pe-sec vppctl show trace
```

Expected trace:
```
gre4-input:
  GRE tunnel decap: src 203.0.113.1, dst 203.0.113.2
  Inner MPLS: [310][1100]
mpls-input:
  Pop 310 → MPLS lookup
  Pop 1100 → ip4-lookup-in-table 10 (VRF 10 ingress)
ip4-lookup:
  fib 10: 10.1.2.10 → via 100.64.100.20 (FW ingress)
af-packet-output:
  → FW (100.64.100.20)
```

### 15.3 FW — Inspect and Forward to PE-SEC Egress VRF

```bash
docker exec -i fw vppctl clear trace
docker exec -i fw vppctl trace add af-packet-input 50
docker exec -it host1 ping -c 1 10.1.2.10
docker exec -i fw vppctl show trace
```

Expected trace:
```
af-packet-input:
  host-ethX (ingress, VRF 10)
  IP4: 10.1.1.10 → 10.1.2.10
ip4-lookup:
  fib 10 (VRF 10): default route → via 100.64.101.1 (PE-SEC VRF 11)
af-packet-output:
  → PE-SEC VRF 11 egress interface (100.64.101.1)
```

### 15.4 PE-SEC — Egress VRF 11 → MPLS Push → GRE → PE2

```bash
docker exec -i pe-sec vppctl clear trace
docker exec -i pe-sec vppctl trace add af-packet-input 50
docker exec -it host1 ping -c 1 10.1.2.10
docker exec -i pe-sec vppctl show trace
```

Expected trace (egress direction):
```
af-packet-input:
  host-ethX (VRF 11 egress interface from FW)
  IP4: 10.1.1.10 → 10.1.2.10
ip4-lookup:
  fib 11 (VRF 11): 10.1.2.0/24 → via 172.16.0.1 gre0 out-labels [1500][500]
mpls-output:
  Push [1500 non-eos][500 eos]
gre4-encap:
  src 203.0.113.2, dst 203.0.113.1
  Inner MPLS: [1500][500]
  → LSR2
```

### 15.5 PE2 — Pop Labels, Forward to CE2 → host2

```bash
docker exec -i pe2 vppctl clear trace
docker exec -i pe2 vppctl trace add af-packet-input 50
docker exec -it host1 ping -c 1 10.1.2.10
docker exec -i pe2 vppctl show trace
```

Expected trace:
```
af-packet-input:
  host-ethX (core-facing, from LSR2)
  MPLS: [1501][500]
mpls-input:
  Pop 1501 → MPLS lookup
  Pop 500 → ip4-lookup-in-table 10 (VRF 10)
ip4-lookup:
  fib 10: 10.1.2.10 → via 100.64.5.20 (CE2)
af-packet-output:
  → CE2
```

---

## 16. Inline FW Label Assignment Summary

### VRF 10: host1 ↔ host2 (via FW)

| Direction | Segment | Label Operation | Next Hop |
|-----------|---------|-----------------|----------|
| **host1 → host2** | | | |
| PE1 | Push [150][1100] | Transport 150, VPN 1100 | LSR1 |
| LSR1 | Swap 150 → 250 | Transport swap | LSR2 |
| LSR2 | Swap 250 → 310, GRE | Transport + tunnel | PE-SEC gre0 |
| PE-SEC | Pop 310, Pop 1100 | → VRF 10 (ingress) | FW (100.64.100.20) |
| FW | IP forward (inspect) | VRF 10 default route | PE-SEC VRF 11 (100.64.101.1) |
| PE-SEC | Push [1500][500], GRE | Transport 1500, VPN 500 | LSR2 gre0 |
| LSR2 | Swap 1500 → 1501 | Transport swap | PE2 |
| PE2 | Pop 1501, Pop 500 | → VRF 10 | CE2 → host2 |
| **host2 → host1** | | | |
| PE2 | Push [1300][1100] | Transport 1300, VPN 1100 | LSR2 |
| LSR2 | Swap 1300 → 310, GRE | Transport + tunnel | PE-SEC gre0 |
| PE-SEC | Pop 310, Pop 1100 | → VRF 10 (ingress) | FW (100.64.100.20) |
| FW | IP forward (inspect) | VRF 10 default route | PE-SEC VRF 11 (100.64.101.1) |
| PE-SEC | Push [1400][600], GRE | Transport 1400, VPN 600 | LSR2 gre0 |
| LSR2 | Swap 1400 → 1401 | Transport swap | LSR1 |
| LSR1 | Swap 1401 → 1402 | Transport swap | PE1 |
| PE1 | Pop 1402, Pop 600 | → VRF 10 | CE1 → host1 |

### VRF 20: CE3 ↔ CE4 (via FW)

| Direction | Segment | Label Operation | Next Hop |
|-----------|---------|-----------------|----------|
| **CE3 → CE4** | | | |
| PE1 | Push [150][1200] | Transport 150, VPN 1200 | LSR1 |
| PE-SEC | Pop 310, Pop 1200 | → VRF 20 (ingress) | FW (100.64.102.20) |
| FW | IP forward (inspect) | VRF 20 default route | PE-SEC VRF 21 (100.64.103.1) |
| PE-SEC | Push [1500][700], GRE | Transport 1500, VPN 700 | PE2 |
| **CE4 → CE3** | | | |
| PE2 | Push [1300][1200] | Transport 1300, VPN 1200 | LSR2 |
| PE-SEC | Pop 310, Pop 1200 | → VRF 20 (ingress) | FW (100.64.102.20) |
| FW | IP forward (inspect) | VRF 20 default route | PE-SEC VRF 21 (100.64.103.1) |
| PE-SEC | Push [1400][800], GRE | Transport 1400, VPN 800 | PE1 |

### VRF 30: CE5 ↔ CE6 (via FW, overlapping IPs with VRF 20)

| Direction | Segment | Label Operation | Next Hop |
|-----------|---------|-----------------|----------|
| **CE5 → CE6** | | | |
| PE1 | Push [150][1250] | Transport 150, VPN 1250 | LSR1 |
| PE-SEC | Pop → VRF 30 (ingress) | VPN 1250 | FW (100.64.104.20) |
| FW | IP forward (inspect) | VRF 30 default route | PE-SEC VRF 31 (100.64.105.1) |
| PE-SEC | Push [1500][900], GRE | Transport 1500, VPN 900 | PE2 |
| **CE6 → CE5** | | | |
| PE2 | Push [1300][1250] | Transport 1300, VPN 1250 | LSR2 |
| PE-SEC | Pop → VRF 30 (ingress) | VPN 1250 | FW (100.64.104.20) |
| FW | IP forward (inspect) | VRF 30 default route | PE-SEC VRF 31 (100.64.105.1) |
| PE-SEC | Push [1400][1000], GRE | Transport 1400, VPN 1000 | PE1 |

> **Key Observations:**
> - Transport labels (150/250/310, 1300/310, 1400/1401/1402, 1500/1501) are VRF-agnostic.
> - VPN labels identify the destination VRF: 1100→VRF 10, 1200→VRF 20, 1250→VRF 30 on PE-SEC.
> - The FW doesn't touch MPLS labels — it operates on plain IP packets within each VRF.
> - Egress VRFs (11/21/31) on PE-SEC re-encapsulate with destination PE labels.

---

## 17. Inline FW Service Chaining — Design Analysis

### Architecture Pattern: Ingress/Egress VRF Split

The **ingress/egress VRF split** is a standard service chaining pattern used in real-world
SP deployments. For each customer VRF, PE-SEC maintains two sub-VRFs:

| Customer | Ingress VRF | Egress VRF | Purpose |
|----------|-------------|------------|---------|
| Customer 1 | VRF 10 | VRF 11 | CE1↔CE2 + sec-host |
| Customer 2 | VRF 20 | VRF 21 | CE3↔CE4 |
| Customer 3 | VRF 30 | VRF 31 | CE5↔CE6 |

**Ingress VRFs** receive MPLS-decapped traffic and route ALL remote subnets to the FW
ingress interface.

**Egress VRFs** receive inspected traffic from the FW egress interface and route it via
MPLS labels to the actual destination PE (PE1 or PE2).

### Why Two VRFs Per Customer?

Without the split, a single VRF on PE-SEC would have:
- Route to remote CE subnets → FW (for inspection)
- But when FW sends inspected traffic back, the same route sends it to FW again → **LOOP**

The egress VRF breaks the loop because it has DIFFERENT routes — pointing to PE1/PE2
via MPLS labels, not back to FW.

### FW Operation

The FW operates as a multi-VRF security device:
- **Per-VRF interface pairs**: Each VRF has a dedicated ingress and egress interface
- **Per-VRF routing**: Default route in each VRF points to the PE-SEC egress VRF
- **VRF isolation on FW**: Required because VRF 20 and VRF 30 use overlapping IPs

### Overlapping IP Handling

VRF 20 (CE3/CE4) and VRF 30 (CE5/CE6) use identical IP addresses:
- CE3/CE5: 100.64.6.20
- CE4/CE6: 100.64.7.20

This is handled correctly because:
1. PE1/PE2 push DIFFERENT VPN labels (1200 for VRF 20, 1250 for VRF 30)
2. PE-SEC maps these to DIFFERENT ingress VRFs (VRF 20 vs VRF 30)
3. FW keeps traffic separated in per-VRF routing tables
4. PE-SEC egress VRFs push DIFFERENT destination VPN labels

### Real-World Applicability

This architecture mirrors production SP deployments where:
- A centralized firewall/IPS inspects all customer traffic
- MPLS VPN provides transport with per-customer isolation
- Service chaining via VRF split avoids routing loops
- The FW can apply per-VRF security policies (DPI, IDS/IPS, ACLs)
- Multiple VRFs share the same physical FW with logical separation

---

## 18. Updated Quick Validation Commands Reference

### All VRFs via Inline FW

| What                        | Command                                                        |
|-----------------------------|----------------------------------------------------------------|
| VRF 10: CE1 → CE2 ping     | `docker exec -it ce1 vppctl ping 100.64.5.20` (via FW)        |
| VRF 20: CE3 → CE4 ping     | `docker exec -it ce3 vppctl ping 100.64.7.20` (via FW)        |
| VRF 30: CE5 → CE6 ping     | `docker exec -it ce5 vppctl ping 100.64.7.20` (via FW)        |

### End Host Connectivity (via inline FW)

| What                        | Command                                                        |
|-----------------------------|----------------------------------------------------------------|
| host1 → host2               | `docker exec -it host1 ping -c 3 10.1.2.10` (via FW)          |
| host2 → host1               | `docker exec -it host2 ping -c 3 10.1.1.10` (via FW)          |
| sec-host → host1            | `docker exec -it sec-host ping -c 3 10.1.1.10`                |
| sec-host → host2            | `docker exec -it sec-host ping -c 3 10.1.2.10`                |
| host1 → sec-host            | `docker exec -it host1 ping -c 3 10.100.1.10` (via FW)        |

### PE-SEC VRF Verification

| What                        | Command                                                        |
|-----------------------------|----------------------------------------------------------------|
| PE-SEC MPLS FIB             | `docker exec -i pe-sec vppctl show mpls fib`                  |
| VRF 10 ingress routes       | `docker exec -i pe-sec vppctl show ip fib table 10`           |
| VRF 11 egress routes        | `docker exec -i pe-sec vppctl show ip fib table 11`           |
| VRF 20 ingress routes       | `docker exec -i pe-sec vppctl show ip fib table 20`           |
| VRF 21 egress routes        | `docker exec -i pe-sec vppctl show ip fib table 21`           |
| VRF 30 ingress routes       | `docker exec -i pe-sec vppctl show ip fib table 30`           |
| VRF 31 egress routes        | `docker exec -i pe-sec vppctl show ip fib table 31`           |

### FW VRF Verification

| What                        | Command                                                        |
|-----------------------------|----------------------------------------------------------------|
| FW VRF 10 routes            | `docker exec -i fw vppctl show ip fib table 10`               |
| FW VRF 20 routes            | `docker exec -i fw vppctl show ip fib table 20`               |
| FW VRF 30 routes            | `docker exec -i fw vppctl show ip fib table 30`               |
| FW VRF 10 BGP               | `docker exec -i fw vtysh -c 'show bgp vrf VRF10 summary'`     |
| FW VRF 20 BGP               | `docker exec -i fw vtysh -c 'show bgp vrf VRF20 summary'`     |
| FW VRF 30 BGP               | `docker exec -i fw vtysh -c 'show bgp vrf VRF30 summary'`     |

### GRE Tunnel & Transport

| What                        | Command                                                        |
|-----------------------------|----------------------------------------------------------------|
| LSR2 GRE tunnel             | `docker exec -i lsr2 vppctl show gre tunnel`                  |
| PE-SEC GRE tunnel           | `docker exec -i pe-sec vppctl show gre tunnel`                |

### Cross-VRF Isolation (must fail)

| What                        | Command                                                        |
|-----------------------------|----------------------------------------------------------------|
| CE1 (VRF10) → CE4 (VRF20)  | `docker exec -it ce1 vppctl ping 100.64.7.20` (should fail)   |
| CE3 (VRF20) → CE2 (VRF10)  | `docker exec -it ce3 vppctl ping 100.64.5.20` (should fail)   |

### Tracing (any node)

| What                        | Command                                                        |
|-----------------------------|----------------------------------------------------------------|
| Enable trace                | `docker exec -i <node> vppctl trace add af-packet-input 50`   |
| Enable GRE trace            | `docker exec -i <node> vppctl trace add gre4-input 50`        |
| View trace                  | `docker exec -i <node> vppctl show trace`                      |
| Clear trace                 | `docker exec -i <node> vppctl clear trace`                     |

---

## VRF 20 End-to-End Validation (host3 ↔ host4)

This section validates VRF 20 traffic flowing from host3 (10.2.1.10, behind CE3) to host4 (10.2.2.10, behind CE4)
across the full MPLS L3VPN core with inline FW service chaining — proving that:

1. VRF 20 uses the same MPLS transport as VRF 10 but with different VPN labels
2. Both request and reply traffic traverse the FW (inspection point)
3. VRF isolation is maintained — VRF 10 hosts cannot reach VRF 20 hosts

### Topology (VRF 20)

```
host3 (10.2.1.10) → CE3 (10.2.1.1) → PE1 [MPLS push] → LSR1 [swap] → LSR2 [GRE+swap]
  → PE-SEC [VRF 20 → FW] → FW [inspect, fib 2] → PE-SEC [VRF 21 → MPLS push]
  → LSR2 [swap] → PE2 [pop → VRF 20] → CE4 (10.2.2.1) → host4 (10.2.2.10)
```

### VRF 20 Label Chain (Forward: host3 → host4)

| Hop | Action | Labels |
|-----|--------|--------|
| PE1 | Push 2-label stack | [150][1200] — transport 150 (same as VRF 10!), VPN 1200 (VRF 20) |
| LSR1 | Swap transport | 150 → 250 |
| LSR2 | Swap + GRE encap | 250 → 310 + GRE(203.0.113.1→203.0.113.2) |
| PE-SEC | Decap GRE, pop 310 (deag), pop 1200 → VRF 20 | Route to FW via 100.64.102.20 |
| FW | Forward in fib 2 (VRF 20) | Plain IP, default via 100.64.103.1 (PE-SEC VRF 21 egress) |
| PE-SEC (VRF 21) | Push 2-label stack + GRE | [1500][700] + GRE |
| LSR2 | Swap transport | 1500 → 1501 |
| PE2 | Pop both labels → VRF 20 | Deliver to CE4 via 100.64.7.20 |

### Key Contrast: VRF 10 vs VRF 20 Labels

| Hop | VRF 10 | VRF 20 | Same? |
|-----|--------|--------|-------|
| PE1 transport | 150 | 150 | ✓ Same LSP |
| PE1 VPN | 1100 | 1200 | ✗ Different VPN |
| PE-SEC VPN disposition | → VRF 10 (fib 1) | → VRF 20 (fib 2) | ✗ Different FIB |
| FW egress | via 100.64.101.1 | via 100.64.103.1 | ✗ Different egress VRF |
| PE-SEC egress VPN | 500 (PE2 VRF 10) | 700 (PE2 VRF 20) | ✗ Different VPN |

### Ping Test: host3 → host4 (VRF 20)

```
$ docker exec host3 ping -c 5 10.2.2.10
PING 10.2.2.10 (10.2.2.10) 56(84) bytes of data.
64 bytes from 10.2.2.10: icmp_seq=2 ttl=57 time=290 ms
64 bytes from 10.2.2.10: icmp_seq=3 ttl=57 time=330 ms
64 bytes from 10.2.2.10: icmp_seq=4 ttl=57 time=351 ms
64 bytes from 10.2.2.10: icmp_seq=5 ttl=57 time=321 ms

--- 10.2.2.10 ping statistics ---
5 packets transmitted, 4 received, 20% packet loss, time 4004ms
rtt min/avg/max/mdev = 289.917/322.678/350.548/21.809 ms
```

**TTL=57** confirms the same 7-hop path as VRF 10: host3(64) → CE3(63) → PE1(62) → FW-in(61) → FW-out(60) → PE2→CE4(59→58) → host4 receives at 57.

### Ping Test: host4 → host3 (VRF 20 reverse)

```
$ docker exec host4 ping -c 3 10.2.1.10
PING 10.2.1.10 (10.2.1.10) 56(84) bytes of data.
64 bytes from 10.2.1.10: icmp_seq=1 ttl=57 time=328 ms
64 bytes from 10.2.1.10: icmp_seq=2 ttl=57 time=303 ms
64 bytes from 10.2.1.10: icmp_seq=3 ttl=57 time=237 ms

--- 10.2.1.10 ping statistics ---
3 packets transmitted, 3 received, 0% packet loss, time 1999ms
rtt min/avg/max/mdev = 237.353/289.310/327.556/38.080 ms
```

### FW VPP Trace — VRF 20 Traffic Through Firewall

This trace proves both ICMP request and reply traverse the FW for VRF 20 inspection.

```
$ docker exec fw vppctl "clear trace"
$ docker exec fw vppctl "trace add af-packet-input 50"
$ docker exec host3 ping -c 3 10.2.2.10    # then show trace

Packet 1 — ICMP echo_request (host3 → host4)

00:03:28:215200: ip4-input
  ICMP: 10.2.1.10 -> 10.2.2.10
    tos 0x00, ttl 61, length 84, checksum 0x243b dscp CS0 ecn NON_ECN
    fragment id 0x0257, flags DONT_FRAGMENT
  ICMP echo_request checksum 0x7ce5 id 21
00:03:28:215209: ip4-lookup
  fib 2 dpo-idx 18 flow hash: 0x00000000         ← VRF 20 (fib 2)
00:03:28:215215: ip4-rewrite
  tx_sw_if_index 5 : ipv4 via 100.64.103.1 host-eth4    ← egress to PE-SEC VRF 21
  ICMP: 10.2.1.10 -> 10.2.2.10   ttl 61 → 60

Packet 2 — ICMP echo_reply (host4 → host3)

00:03:28:385089: ip4-input
  ICMP: 10.2.2.10 -> 10.2.1.10
    tos 0x00, ttl 61, length 84, checksum 0x14fe
  ICMP echo_reply checksum 0x84e5 id 21
00:03:28:385093: ip4-lookup
  fib 2 dpo-idx 18 flow hash: 0x00000000         ← VRF 20 (fib 2) — reply also inspected
00:03:28:385097: ip4-rewrite
  tx_sw_if_index 5 : ipv4 via 100.64.103.1 host-eth4    ← egress to PE-SEC VRF 21
  ICMP: 10.2.2.10 -> 10.2.1.10   ttl 61 → 60
```

**Key observations:**
- Both request and reply arrive on FW in **fib 2** (VRF 20) — different from VRF 10 traffic which uses fib 1
- FW forwards via **100.64.103.1** (PE-SEC VRF 21 egress) — different from VRF 10 which uses 100.64.101.1 (VRF 11)
- TTL decremented 61→60 by FW, matching the expected hop count

### FW VPP Trace — VRF 10 Traffic Through Firewall (for comparison)

```
Packet — ICMP echo_request (host1 → host2)

00:03:48:417321: ip4-input
  ICMP: 10.1.1.10 -> 10.1.2.10
    ttl 61, length 84
  ICMP echo_request id 22
00:03:48:417327: ip4-lookup
  fib 1 dpo-idx 17 flow hash: 0x00000000         ← VRF 10 (fib 1)
00:03:48:417331: ip4-rewrite
  tx_sw_if_index 3 : ipv4 via 100.64.101.1 host-eth2    ← egress to PE-SEC VRF 11
  ICMP: 10.1.1.10 -> 10.1.2.10   ttl 61 → 60
```

### VRF Isolation Verification

```
$ docker exec host1 ping -c 2 -W 2 10.2.2.10    # VRF 10 host → VRF 20 host
2 packets transmitted, 0 received, 100% packet loss

$ docker exec host3 ping -c 2 -W 2 10.1.2.10    # VRF 20 host → VRF 10 host
2 packets transmitted, 0 received, 100% packet loss
```

✓ Cross-VRF traffic is correctly isolated — VRF 10 and VRF 20 share the same physical MPLS core and FW, but cannot communicate with each other.

### VRF 20 Quick Reference Commands

| What | Command |
|------|---------|
| Ping host3 → host4 | `docker exec -it host3 ping -c 3 10.2.2.10` |
| Ping host4 → host3 | `docker exec -it host4 ping -c 3 10.2.1.10` |
| CE3 → CE4 (CE level) | `docker exec -it ce3 vppctl ping 100.64.7.20` |
| FW VRF 20 FIB | `docker exec -i fw vppctl "show ip fib table 20"` |
| PE1 VRF 20 FIB | `docker exec -i pe1 vppctl "show ip fib table 20"` |
| PE-SEC VRF 20 BGP | `docker exec -i pe-sec vtysh -c "show bgp vrf VRF20 ipv4 unicast"` |
| FW trace (enable) | `docker exec -i fw vppctl "trace add af-packet-input 50"` |
| FW trace (view) | `docker exec -i fw vppctl "show trace"` |
| Cross-VRF test (must fail) | `docker exec -it host1 ping -c 2 -W 2 10.2.2.10` |
