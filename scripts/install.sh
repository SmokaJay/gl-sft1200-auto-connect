#!/bin/sh
# install.sh — Run this ON THE ROUTER after copying files via SCP.
# Usage: sh install.sh
#
# Prerequisites: SSH access to the router (default: root@192.168.8.1)

set -e

echo "==> Installing auto-connect daemon..."

# 1. Install main daemon script
cp /tmp/auto-connect.sh /usr/sbin/auto-connect.sh
chmod +x /usr/sbin/auto-connect.sh
echo "    [ok] /usr/sbin/auto-connect.sh"

# 2. Install init.d service
cp /tmp/auto-connect-init /etc/init.d/auto-connect
chmod +x /etc/init.d/auto-connect
echo "    [ok] /etc/init.d/auto-connect"

# 3. Install hotplug script
mkdir -p /etc/hotplug.d/iface
cp /tmp/auto-connect-hotplug /etc/hotplug.d/iface/30-auto-connect
chmod +x /etc/hotplug.d/iface/30-auto-connect
echo "    [ok] /etc/hotplug.d/iface/30-auto-connect"

# 4. Install config (don't overwrite if it already exists)
if [ ! -f /etc/auto-connect.conf ]; then
    cp /tmp/auto-connect.conf /etc/auto-connect.conf
    echo "    [ok] /etc/auto-connect.conf (new)"
else
    echo "    [skip] /etc/auto-connect.conf already exists — not overwritten"
fi

# 5. Add wwan interface to /etc/config/network if missing
if ! uci show network.wwan >/dev/null 2>&1; then
    uci set network.wwan=interface
    uci set network.wwan.proto=dhcp
    uci set network.wwan.metric=20
    uci commit network
    echo "    [ok] Added 'wwan' UCI interface"
else
    echo "    [skip] 'wwan' UCI interface already exists"
fi

# 6. Enable and start the service
/etc/init.d/auto-connect enable
/etc/init.d/auto-connect start
echo "    [ok] Service enabled and started"

echo ""
echo "==> Installation complete."
echo "    Monitor logs with: logread -f | grep auto-connect"
