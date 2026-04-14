#!/bin/bash
# deploy.sh — Run this from your PC to copy files to the router and install.
# Requires: ssh, scp (OpenSSH or PuTTY's pscp)
# Usage: bash deploy.sh [router-ip]
#
# Default router IP for GL-iNet routers is 192.168.8.1

ROUTER_IP="${1:-192.168.8.1}"
ROUTER_USER="root"
SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

echo "Deploying to ${ROUTER_USER}@${ROUTER_IP}..."

# Copy files to /tmp on the router
scp "${SCRIPT_DIR}/scripts/auto-connect.sh"      "${ROUTER_USER}@${ROUTER_IP}:/tmp/auto-connect.sh"
scp "${SCRIPT_DIR}/init.d/auto-connect"           "${ROUTER_USER}@${ROUTER_IP}:/tmp/auto-connect-init"
scp "${SCRIPT_DIR}/hotplug/auto-connect-hotplug"  "${ROUTER_USER}@${ROUTER_IP}:/tmp/auto-connect-hotplug"
scp "${SCRIPT_DIR}/config/auto-connect.conf"      "${ROUTER_USER}@${ROUTER_IP}:/tmp/auto-connect.conf"
scp "${SCRIPT_DIR}/scripts/install.sh"            "${ROUTER_USER}@${ROUTER_IP}:/tmp/install.sh"

echo "Running installer on router..."
ssh "${ROUTER_USER}@${ROUTER_IP}" "sh /tmp/install.sh"

echo ""
echo "Done. To watch logs: ssh ${ROUTER_USER}@${ROUTER_IP} 'logread -f | grep auto-connect'"
