#!/bin/bash
# Entrypoint for VPP + FRR container
# Starts VPP first, then FRR daemons

set -e

echo "=== Starting VPP ==="
# Start VPP in the background
# The base image CMD is usually: vpp -c /etc/vpp/startup.conf
vpp -c /etc/vpp/startup.conf &
VPP_PID=$!

# Wait for VPP to be ready
echo "Waiting for VPP to initialize..."
for i in $(seq 1 30); do
    if vppctl show version > /dev/null 2>&1; then
        echo "VPP is ready."
        break
    fi
    sleep 1
done

# If FRR config exists for this node, copy it
# Config is volume-mounted to /etc/frr/frr.conf by docker-compose
if [ -f /etc/frr/frr.conf ]; then
    echo "=== FRR config found ==="
    cat /etc/frr/frr.conf
fi

echo "=== Starting FRR ==="
# Start FRR daemons
/usr/lib/frr/frrinit.sh start

echo "=== VPP + FRR running ==="

# Keep container alive — follow VPP process
wait $VPP_PID
