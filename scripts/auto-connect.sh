#!/bin/sh
# auto-connect.sh — Scan for open WiFi networks and connect automatically.
# Runs as a persistent daemon. Monitored by init.d/auto-connect.
#
# Behavior:
#   1. Scan for open (unencrypted) networks on the WAN radio.
#   2. Connect to the strongest available open network.
#   3. Verify internet connectivity; if it fails, blacklist the SSID
#      for BLACKLIST_TTL seconds and try the next best network.
#   4. If connected and link drops, immediately re-scan.
#
# Config is read from /etc/auto-connect.conf (UCI-style shell vars).

CONFIG_FILE="/etc/auto-connect.conf"

# ---------- Defaults (overridden by config file) ----------
RADIO="radio0"              # radio used for WAN (station mode)
WAN_IFACE="wwan"            # OpenWrt interface name for the WAN station
SCAN_IFACE="wlan0"          # physical wifi interface for scanning
CHECK_HOST="1.1.1.1"        # host to ping for internet check
CHECK_TIMEOUT=5             # seconds to wait for ping
CONNECT_WAIT=15             # seconds to wait for DHCP after association
SCAN_INTERVAL=30            # seconds between idle scans
FAIL_SCAN_INTERVAL=10       # seconds between scans when no network found
BLACKLIST_TTL=300           # seconds to blacklist a failing network
MIN_SIGNAL=-80              # dBm threshold; weaker networks are ignored
LOG_TAG="auto-connect"
# ----------------------------------------------------------

[ -f "$CONFIG_FILE" ] && . "$CONFIG_FILE"

BLACKLIST_DIR="/tmp/auto-connect-blacklist"
mkdir -p "$BLACKLIST_DIR"

log() { logger -t "$LOG_TAG" "$*"; }

# Return 0 if SSID is blacklisted, 1 otherwise
is_blacklisted() {
    local ssid="$1"
    local safe_name
    safe_name=$(printf '%s' "$ssid" | tr -cd 'A-Za-z0-9_-')
    local bl_file="$BLACKLIST_DIR/$safe_name"
    [ -f "$bl_file" ] || return 1
    local expires
    expires=$(cat "$bl_file")
    local now
    now=$(date +%s)
    if [ "$now" -ge "$expires" ]; then
        rm -f "$bl_file"
        return 1
    fi
    return 0
}

blacklist() {
    local ssid="$1"
    local safe_name
    safe_name=$(printf '%s' "$ssid" | tr -cd 'A-Za-z0-9_-')
    local expires=$(( $(date +%s) + BLACKLIST_TTL ))
    echo "$expires" > "$BLACKLIST_DIR/$safe_name"
    log "Blacklisted '$ssid' for ${BLACKLIST_TTL}s"
}

# Scan and return open networks sorted by signal strength (strongest first).
# Output: one "SIGNAL SSID" per line (signal is negative dBm integer).
scan_open_networks() {
    # Trigger a fresh scan; ignore errors on busy interface
    iw dev "$SCAN_IFACE" scan 2>/dev/null | awk '
        /^BSS / { signal=""; ssid=""; enc=0 }
        /signal:/ { signal=$2 }
        /SSID:/ { ssid=substr($0, index($0,$2)) }
        /capability:.*Privacy/ { enc=1 }
        /^BSS / && ssid!="" && enc==0 && signal!="" {
            print signal, ssid
        }
        END {
            # flush last record
        }
    ' | sort -rn
    # Note: awk above has a flush issue for the last record; use the
    # version below which buffers properly.
}

# More reliable scan parser
scan_open_networks() {
    iw dev "$SCAN_IFACE" scan 2>/dev/null | awk '
    BEGIN { signal=""; ssid=""; enc=0 }
    /^BSS [0-9a-f]/ {
        if (ssid != "" && enc == 0 && signal != "") {
            printf "%s\t%s\n", signal, ssid
        }
        signal=""; ssid=""; enc=0
    }
    /^\tSignal:/ { signal=$2 }
    /^\tSSID:/ {
        sub(/^\tSSID: /, "")
        ssid=$0
    }
    /RSN:|WPA:/ { enc=1 }
    /Privacy/ { enc=1 }
    END {
        if (ssid != "" && enc == 0 && signal != "") {
            printf "%s\t%s\n", signal, ssid
        }
    }
    ' | sort -rn
}

# Return the SSID we are currently associated with (empty if none)
current_ssid() {
    iwinfo "$SCAN_IFACE" info 2>/dev/null | awk '/ESSID:/ { gsub(/"/, "", $2); print $2 }'
}

# Check if we have a usable internet connection
check_internet() {
    ping -c 1 -W "$CHECK_TIMEOUT" "$CHECK_HOST" >/dev/null 2>&1
}

# Use UCI to configure the WWAN interface and bring it up
connect_to() {
    local ssid="$1"
    log "Connecting to open network: '$ssid'"

    uci set wireless.wwan=wifi-iface
    uci set wireless.wwan.device="$RADIO"
    uci set wireless.wwan.mode=sta
    uci set wireless.wwan.network="$WAN_IFACE"
    uci set wireless.wwan.ssid="$ssid"
    uci set wireless.wwan.encryption=none
    uci commit wireless

    # Bring up the network interface
    ifup "$WAN_IFACE" 2>/dev/null
    wifi up "$RADIO" 2>/dev/null

    log "Waiting ${CONNECT_WAIT}s for DHCP..."
    sleep "$CONNECT_WAIT"
}

# Disconnect and clean up the WWAN UCI stanza
disconnect() {
    log "Disconnecting from current network"
    ifdown "$WAN_IFACE" 2>/dev/null
    uci delete wireless.wwan 2>/dev/null
    uci commit wireless
    wifi up "$RADIO" 2>/dev/null
}

# ---------- Main loop ----------
log "Starting auto-connect daemon (radio=$RADIO iface=$SCAN_IFACE)"

while true; do
    # Check if we already have working internet
    if check_internet; then
        sleep "$SCAN_INTERVAL"
        continue
    fi

    SSID=$(current_ssid)
    if [ -n "$SSID" ] && [ "$SSID" != "unknown" ]; then
        log "Associated with '$SSID' but no internet — blacklisting and disconnecting"
        blacklist "$SSID"
        disconnect
    fi

    log "Scanning for open networks..."
    NETWORKS=$(scan_open_networks)

    if [ -z "$NETWORKS" ]; then
        log "No open networks found, retrying in ${FAIL_SCAN_INTERVAL}s"
        sleep "$FAIL_SCAN_INTERVAL"
        continue
    fi

    CONNECTED=0
    while IFS=$'\t' read -r signal ssid; do
        [ -z "$ssid" ] && continue

        # Filter weak signals
        sig_int=$(printf '%.0f' "$signal" 2>/dev/null || echo "$signal")
        if [ "$sig_int" -lt "$MIN_SIGNAL" ] 2>/dev/null; then
            log "Skipping '$ssid' (signal ${signal} dBm < threshold ${MIN_SIGNAL})"
            continue
        fi

        if is_blacklisted "$ssid"; then
            log "Skipping blacklisted network '$ssid'"
            continue
        fi

        connect_to "$ssid"

        if check_internet; then
            log "Successfully connected to '$ssid' (signal ${signal} dBm)"
            CONNECTED=1
            break
        else
            log "No internet on '$ssid' — blacklisting"
            blacklist "$ssid"
            disconnect
        fi
    done <<EOF
$NETWORKS
EOF

    if [ "$CONNECTED" -eq 0 ]; then
        log "Could not connect to any open network, retrying in ${FAIL_SCAN_INTERVAL}s"
        sleep "$FAIL_SCAN_INTERVAL"
    fi
done
