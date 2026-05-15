#!/bin/bash
set -euo pipefail

INFERENCE_URL="http://localhost:8000/health"
RPC_URL="https://rpc.allora.network:26657"
MIN_ALLO_BALANCE=10000000  # 10 ALLO in uallo
CHECK_INTERVAL=300

log() { echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] $*"; }

check_inference_service() {
    if ! curl -sf "$INFERENCE_URL" > /dev/null; then
        log "WARN: Inference service unreachable — restarting container"
        docker restart hailo-inference || true
        sleep 10
    fi
}

check_hailo_device() {
    if ! hailortcli fw-info > /dev/null 2>&1; then
        log "WARN: Hailo device not found — restarting inference container"
        docker restart hailo-inference || true
        sleep 15
    fi
}

check_rpc() {
    if ! curl -sf "${RPC_URL}/status" > /dev/null; then
        log "WARN: Primary RPC unreachable at $RPC_URL"
    fi
}

check_wallet_balance() {
    local addr="${WORKER_ADDRESS:-}"
    if [[ -z "$addr" ]]; then
        return
    fi
    local bal
    bal=$(allora-node query bank balances "$addr" --node "$RPC_URL" \
          --output json 2>/dev/null | jq -r '.balances[]|select(.denom=="uallo")|.amount' || echo 0)
    if [[ "${bal:-0}" -lt "$MIN_ALLO_BALANCE" ]]; then
        log "ALERT: Low ALLO balance: ${bal} uallo (minimum: $MIN_ALLO_BALANCE)"
    fi
}

log "Health monitor started (interval: ${CHECK_INTERVAL}s)"
while true; do
    check_hailo_device
    check_inference_service
    check_rpc
    check_wallet_balance
    sleep "$CHECK_INTERVAL"
done
