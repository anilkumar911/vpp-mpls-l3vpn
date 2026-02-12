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
