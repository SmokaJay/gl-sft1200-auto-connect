# Advanced Configuration

## Prioritizing Specific Networks

By default the daemon connects to the strongest open network. To prefer certain SSIDs (e.g., a known trusted hotspot), add a priority list to `/etc/auto-connect.conf`:

```sh
# Comma-separated list of preferred SSIDs (tried first, in order)
PREFERRED_NETWORKS="Starbucks,AirportFreeWifi,HotelGuest"
```

Then add this block to `auto-connect.sh` just before the main scan loop:

```sh
# Try preferred networks first
if [ -n "$PREFERRED_NETWORKS" ]; then
    echo "$PREFERRED_NETWORKS" | tr ',' '\n' | while read -r preferred; do
        is_blacklisted "$preferred" && continue
        connect_to "$preferred"
        if check_internet; then
            log "Connected to preferred network '$preferred'"
            CONNECTED=1
            break
        else
            blacklist "$preferred"
            disconnect
        fi
    done
fi
```

---

## Captive Portal Handling

Many public WiFi networks (hotels, airports) require you to accept terms in a browser before granting internet access. The daemon will blacklist these because the ping check fails.

**Option 1 — Use a captive portal detection URL**

Replace the `check_internet()` function in `auto-connect.sh`:

```sh
check_internet() {
    # Most captive portals redirect HTTP but not HTTPS
    # Use a known URL that returns a specific short response
    local response
    response=$(curl -s --max-time "$CHECK_TIMEOUT" \
        -o /dev/null -w "%{http_code}" \
        http://connectivitycheck.gstatic.com/generate_204)
    [ "$response" = "204" ]
}
```

Install curl if needed: `opkg update && opkg install curl`

**Option 2 — Increase `CONNECT_WAIT` and `BLACKLIST_TTL`**

Give more time for the portal redirect to settle, and shorten the blacklist so the router retries sooner:

```sh
CONNECT_WAIT=30
BLACKLIST_TTL=60
```

---

## Running on 5 GHz

The GL-SFT1200 is a single-band 2.4 GHz router, but if you have a dual-band GL-iNet model:

```sh
# In /etc/auto-connect.conf
RADIO="radio1"
SCAN_IFACE="wlan1"
```

---

## Restricting to Known SSIDs Only

If you only want to connect to a known set of networks (not any open network):

```sh
# In /etc/auto-connect.conf
ALLOWED_NETWORKS="CoffeeShopWifi,LibraryGuest,AirportFree"
```

Add this filter inside the scan loop in `auto-connect.sh`, after `is_blacklisted`:

```sh
# Check if ssid is in the allowed list
allowed=0
echo "$ALLOWED_NETWORKS" | tr ',' '\n' | while read -r allowed_ssid; do
    [ "$ssid" = "$allowed_ssid" ] && allowed=1
done
[ "$allowed" -eq 0 ] && continue
```

---

## Preventing Auto-Connect Temporarily

To pause auto-connect without stopping the service (useful when you've manually configured a VPN or specific network):

```sh
# Create a lock file
touch /tmp/auto-connect-pause

# Resume
rm /tmp/auto-connect-pause
```

Add this check at the top of the main loop in `auto-connect.sh`:

```sh
if [ -f /tmp/auto-connect-pause ]; then
    sleep "$SCAN_INTERVAL"
    continue
fi
```

---

## Email / Notification on Connect

To get notified when the router connects to a new network, add a notification hook. Example using a webhook (e.g., ntfy.sh):

```sh
notify_connect() {
    local ssid="$1"
    curl -s --max-time 5 \
        -d "Connected to '$ssid' on $(date)" \
        https://ntfy.sh/your-topic-here >/dev/null 2>&1 &
}
```

Call `notify_connect "$ssid"` after the successful `check_internet` in `auto-connect.sh`.

---

## Keeping Logs Across Reboots

By default OpenWrt logs are in RAM and lost on reboot. To persist them:

```sh
# On the router
opkg update && opkg install logd
uci set system.@system[0].log_file='/overlay/upper/var/log/auto-connect.log'
uci set system.@system[0].log_size=512
uci commit system
/etc/init.d/log restart
```
