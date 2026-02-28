#!/bin/bash
# Background heartbeat for pool manager.
# Touches activity file + pings HTTP endpoint periodically.
# Run as: pool-heartbeat &
AGENT_ID="${AGENT_ID:-unknown}"
POOL_HOST="${POOL_HOST:-pool-manager}"
POOL_PORT="${POOL_PORT:-19000}"
HEARTBEAT_INTERVAL="${HEARTBEAT_INTERVAL:-30}"

while true; do
  touch "/pool/activity/$AGENT_ID" 2>/dev/null || true
  curl -sf --max-time 5 -X POST "http://$POOL_HOST:$POOL_PORT/heartbeat" \
    -H "Content-Type: application/json" \
    -d "{\"agent\":\"$AGENT_ID\"}" 2>/dev/null || true
  sleep "$HEARTBEAT_INTERVAL"
done
