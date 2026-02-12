# VPP + FRR combined image for MPLS L3VPN with MP-BGP
# Base: ligato/vpp-base:latest (Ubuntu 22.04, VPP 25.10)
# Adds: FRRouting (FRR) for BGP/MPLS control plane

FROM ligato/vpp-base:latest

# Avoid interactive prompts during package installation
ENV DEBIAN_FRONTEND=noninteractive

# Install dependencies and FRR
RUN apt-get update && apt-get install -y --no-install-recommends \
    curl \
    gnupg \
    lsb-release \
    iproute2 \
    iputils-ping \
    tcpdump \
    net-tools \
    ca-certificates \
    && curl -s https://deb.frrouting.org/frr/keys.gpg \
       -o /usr/share/keyrings/frrouting.gpg \
    && echo "deb [signed-by=/usr/share/keyrings/frrouting.gpg] https://deb.frrouting.org/frr jammy frr-stable" \
       > /etc/apt/sources.list.d/frr.list \
    && apt-get update \
    && apt-get install -y --no-install-recommends \
       frr \
       frr-pythontools \
    && rm -rf /var/lib/apt/lists/*

# Enable required FRR daemons: zebra (RIB manager) + bgpd (BGP)
RUN sed -i 's/^zebra=no/zebra=yes/' /etc/frr/daemons \
    && sed -i 's/^bgpd=no/bgpd=yes/' /etc/frr/daemons

# Create directories for FRR runtime
RUN mkdir -p /var/run/frr && chown frr:frr /var/run/frr

# Copy entrypoint script
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

CMD ["/entrypoint.sh"]
