#!/bin/bash
# Build the VPP + FRR Docker image
# Run from the repo root: ./frr-vpp/build.sh

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IMAGE_NAME="vpp-frr:latest"

echo "============================================"
echo "  Building VPP + FRR image: $IMAGE_NAME"
echo "============================================"
echo ""

docker build -t "$IMAGE_NAME" "$SCRIPT_DIR"

echo ""
echo "============================================"
echo "  Build complete: $IMAGE_NAME"
echo "============================================"
echo ""
echo "Verify:"
echo "  docker run --rm --privileged $IMAGE_NAME vppctl show version"
echo "  docker run --rm --privileged $IMAGE_NAME vtysh -c 'show version'"
