# Troubleshooting Guide

## The daemon isn't starting

**Check if the service is enabled:**
```sh
ls /etc/rc.d/ | grep auto-connect
```
You should see `S99auto-connect`. If not, run:
```sh
/etc/init.d/auto-connect enable
/etc/init.d/auto-connect start
```

**Check procd logs:**
```sh
logread | grep -i 'auto-connect\|procd'
```

---

## The router scans but never connects

**Confirm `iw` is available:**
```sh
iw --version
```
If missing: `opkg update && opkg install iw`

**Run a manual scan to see what the router sees:**
```sh
iw dev wlan0 scan | grep -E 'SSID|signal|RSN|WPA|Privacy'
```
Open networks will show an `SSID:` line with no `RSN:`, `WPA:`, or `Privacy` entries nearby.

**Check that your `SCAN_IFACE` is correct:**
```sh
iwinfo
```
The interface in AP mode (your LAN) cannot scan while transmitting. On the SFT1200, `wlan0` is typically the 2.4 GHz AP. If the scan returns nothing, the interface may be busy — the daemon briefly takes it off-channel to scan, which is normal.

---

## Connected but no internet

**Check DHCP lease:**
```sh
ifconfig wwan  # or: ip addr show wwan
```
If no IP is assigned, DHCP failed. Try increasing `CONNECT_WAIT` in `auto-connect.conf`.

**Check routing:**
```sh
ip route
```
You should see a default route via the `wwan` interface with metric 20.

**Check DNS:**
```sh
nslookup google.com
```

**Try pinging manually:**
```sh
ping -c 3 1.1.1.1
ping -c 3 google.com
```

---

## The daemon keeps blacklisting good networks

The ping check to `1.1.1.1` (Cloudflare) may be blocked by some captive portals even after association. In that case:

1. Change `CHECK_HOST` in `auto-connect.conf` to a host that the portal allows, or
2. Reduce `BLACKLIST_TTL` so networks are retried sooner, or
3. Add captive portal detection (see [Advanced Configuration](advanced.md))

---

## High CPU / daemon spinning

If `FAIL_SCAN_INTERVAL` is set very low (< 5s) and no networks are found, the scan loop runs frequently. Increase it:
```sh
# In /etc/auto-connect.conf
FAIL_SCAN_INTERVAL=30
```

Scanning also briefly interrupts client traffic on the same radio. On a travel router this is acceptable.

---

## Interface name is wrong

Run `iwinfo` and `uci show wireless` on the router to identify the correct names, then update `/etc/auto-connect.conf`:

```sh
# Example: 5 GHz radio
RADIO="radio1"
SCAN_IFACE="wlan1"
```

---

## Checking the blacklist

Blacklist entries are stored as files in `/tmp/auto-connect-blacklist/`. The filename is the sanitized SSID and the content is the Unix expiry timestamp.

```sh
# List blacklisted networks
ls /tmp/auto-connect-blacklist/

# See when a blacklist expires
cat /tmp/auto-connect-blacklist/SomeNetwork
date -d @$(cat /tmp/auto-connect-blacklist/SomeNetwork)  # GNU date
# or
date -r $(cat /tmp/auto-connect-blacklist/SomeNetwork)   # BusyBox

# Clear all blacklist entries
rm -f /tmp/auto-connect-blacklist/*
```

Note: the blacklist is in `/tmp` and clears on reboot.

---

## Resetting to a specific network manually

```sh
# Stop the daemon temporarily
/etc/init.d/auto-connect stop

# Connect to a specific network via UCI
uci set wireless.wwan=wifi-iface
uci set wireless.wwan.device=radio0
uci set wireless.wwan.mode=sta
uci set wireless.wwan.network=wwan
uci set wireless.wwan.ssid="MyNetwork"
uci set wireless.wwan.encryption=none
uci commit wireless
ifup wwan

# Resume auto-connect (it will take over if this network fails)
/etc/init.d/auto-connect start
```
