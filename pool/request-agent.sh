#!/bin/bash
# Request another agent to be started in the pool.
# Usage: request-agent <agent-id>
# Mounted into containers at /usr/local/bin/request-agent
set -euo pipefail

AGENT_ID="${1:?Usage: request-agent <agent-id>}"
POOL_HOST="${POOL_HOST:-pool-manager}"
POOL_PORT="${POOL_PORT:-19000}"
MY_ID="${AGENT_ID:-unknown}"

payload=$(jq -n --arg a "$AGENT_ID" --arg by "$MY_ID" '{agent: $a, requested_by: $by}')

response=$(curl -sf --max-time 30 -X POST "http://$POOL_HOST:$POOL_PORT/request" \
  -H "Content-Type: application/json" \
  -d "$payload" 2>/dev/null) || {
  echo "ERROR: Could not reach pool manager at $POOL_HOST:$POOL_PORT" >&2
  exit 1
}

echo "$response"
status=$(echo "$response" | jq -r '.status // "error"' 2>/dev/null)
case "$status" in
  started|already_running) exit 0 ;;
  *) exit 1 ;;
esac
