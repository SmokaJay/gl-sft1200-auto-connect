# GL-SFT1200 Auto-Connect WiFi Daemon

Automatically connects your **GL-iNet GL-SFT1200** travel router to open (unencrypted) WiFi networks and seamlessly switches to a better network if the current one loses internet connectivity.

No custom firmware compilation required — installs directly on top of the stock GL-iNet firmware via SSH.

---

## Features

- Scans for open WiFi networks and connects to the strongest one
- Verifies internet connectivity after connecting (pings `1.1.1.1`)
- Blacklists networks that have no internet for a configurable cooldown period
- Automatically reconnects if the current network drops
- Reacts instantly to link-down events via OpenWrt hotplug
- Survives reboots (runs as a `procd` service)
- Fully configurable via `/etc/auto-connect.conf`

---

## Requirements

- GL-iNet GL-SFT1200 running stock GL-iNet firmware (OpenWrt-based)
- SSH access to the router (enabled by default; password set in GL-iNet admin panel)
- A PC with `ssh` and `scp` available (macOS/Linux built-in; Windows via Git Bash, WSL, or OpenSSH)

---

## Quick Start

```bash
# Clone this repo on your PC
git clone https://github.com/SmokaJay/gl-sft1200-auto-connect.git
cd gl-sft1200-auto-connect

# Deploy to your router (default IP: 192.168.8.1)
bash scripts/deploy.sh

# Or specify a different IP
bash scripts/deploy.sh 192.168.100.1
```

That's it. The daemon will start immediately and enable itself on every boot.

---

## How It Works

```
Boot
 └─ init.d/auto-connect starts the daemon
      └─ Loop:
           ├─ Already have internet? → sleep 30s, check again
           ├─ No internet?
           │    ├─ Blacklist current network (if any)
           │    ├─ Disconnect
           │    └─ Scan for open networks (sorted by signal strength)
           │         └─ For each candidate:
           │              ├─ Skip if blacklisted or signal too weak
           │              ├─ Connect via UCI + ifup wwan
           │              ├─ Wait for DHCP (20s)
           │              ├─ Ping 1.1.1.1
           │              │    ├─ Success → done, sleep 30s
           │              │    └─ Fail → blacklist, try next
           └─ hotplug/30-auto-connect wakes daemon immediately on link-down
```

---

## File Overview

| File | Installed to | Purpose |
|------|-------------|---------|
| `scripts/auto-connect.sh` | `/usr/sbin/auto-connect.sh` | Main daemon |
| `init.d/auto-connect` | `/etc/init.d/auto-connect` | Boot service (procd) |
| `hotplug/auto-connect-hotplug` | `/etc/hotplug.d/iface/30-auto-connect` | Reacts to link events |
| `config/auto-connect.conf` | `/etc/auto-connect.conf` | User configuration |
| `scripts/deploy.sh` | Run on your PC | Copies files and runs installer |
| `scripts/install.sh` | Run on router | Places files and enables service |

---

## Configuration

Edit `config/auto-connect.conf` before deploying, or edit `/etc/auto-connect.conf` on the router directly and restart the service.

| Option | Default | Description |
|--------|---------|-------------|
| `RADIO` | `radio0` | Radio device for WAN (use `radio1` for 5 GHz) |
| `WAN_IFACE` | `wwan` | UCI interface name for the WAN station |
| `SCAN_IFACE` | `wlan0` | Physical WiFi interface used for scanning |
| `CHECK_HOST` | `1.1.1.1` | Host to ping for internet verification |
| `CHECK_TIMEOUT` | `5` | Seconds to wait for ping response |
| `CONNECT_WAIT` | `20` | Seconds to wait for DHCP after associating |
| `SCAN_INTERVAL` | `30` | Seconds between checks when connected |
| `FAIL_SCAN_INTERVAL` | `15` | Seconds between scans when no network found |
| `MIN_SIGNAL` | `-80` | Minimum signal strength in dBm (-90 to accept weaker networks) |
| `BLACKLIST_TTL` | `300` | Seconds to avoid a network with no internet (5 min) |

After editing on the router:
```sh
/etc/init.d/auto-connect restart
```

---

## Verifying Interface Names

The GL-SFT1200 usually uses `wlan0` / `radio0`, but confirm on your unit:

```sh
# SSH into the router
ssh root@192.168.8.1

# List radios
uci show wireless | grep '\.type='

# List physical interfaces and their current state
iwinfo
```

Update `RADIO` and `SCAN_IFACE` in `auto-connect.conf` if they differ.

---

## Monitoring & Troubleshooting

```sh
# Watch live logs
logread -f | grep auto-connect

# Check service status
/etc/init.d/auto-connect status

# Restart the daemon
/etc/init.d/auto-connect restart

# View blacklisted networks
ls /tmp/auto-connect-blacklist/

# Manually clear a blacklist entry
rm /tmp/auto-connect-blacklist/<ssid>

# Test internet check manually
ping -c 1 -W 5 1.1.1.1
```

---

## Uninstalling

```sh
# On the router:
/etc/init.d/auto-connect stop
/etc/init.d/auto-connect disable
rm /usr/sbin/auto-connect.sh
rm /etc/init.d/auto-connect
rm /etc/hotplug.d/iface/30-auto-connect
rm /etc/auto-connect.conf
uci delete network.wwan
uci commit network
```

---

## Legal Notice

Only connect to WiFi networks you are authorized to use. This tool is intended for legitimate use cases such as connecting to hotel, café, airport, or other public hotspots where open access is intentionally provided. Unauthorized access to computer networks may violate local laws.

---

## License

MIT
