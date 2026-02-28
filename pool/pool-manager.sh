#!/bin/bash
# OpenClaw Agent Pool Manager
# Manages a fixed-size pool of agent containers with LRU eviction.
# Runs on host as systemd service, exposes HTTP API via socat.
set -euo pipefail

POOL_DIR="${POOL_DIR:-/home/tho/openclaw/pool}"
HTTP_PORT="${POOL_PORT:-19000}"
AUTOSTART_FILE="$POOL_DIR/autostart.txt"

source "$POOL_DIR/pool-lib.sh"

mkdir -p "$ACTIVITY_DIR"
touch "$LOCK_FILE"
[ -s "$STATE_FILE" ] || echo '{"agents":{}}' > "$STATE_FILE"

# --- Sync loop: reconcile state with actual Docker containers ---
sync_activity() {
  while true; do
    shopt -s nullglob
    for f in "$ACTIVITY_DIR"/*; do
      local agent
      agent=$(basename "$f")
      local container_state
      container_state=$(docker compose --project-directory "$COMPOSE_DIR" ps --format '{{.State}}' "$agent" 2>/dev/null || echo "")
      if [ -z "$container_state" ] || ! echo "$container_state" | grep -qi running; then
        if read_state | jq -e --arg a "$agent" '.agents[$a]' >/dev/null 2>&1; then
          log "Agent $agent container stopped externally, cleaning up"
          modify_state 'del(.agents[$a])' --arg a "$agent"
          rm -f "$ACTIVITY_DIR/$agent"
          update_roster
        else
          # Activity file exists but agent not in state — clean up orphan
          rm -f "$ACTIVITY_DIR/$agent"
        fi
      fi
    done
    shopt -u nullglob
    sleep "$SYNC_INTERVAL"
  done
}

# --- Reconcile state with running containers on startup ---
reconcile_state() {
  log "Reconciling state with running containers..."
  local agents
  agents=$(read_state | jq -r '.agents | keys[]' 2>/dev/null || true)
  for agent in $agents; do
    [ -z "$agent" ] && continue
    local container_state
    container_state=$(docker compose --project-directory "$COMPOSE_DIR" ps --format '{{.State}}' "$agent" 2>/dev/null || echo "")
    if [ -z "$container_state" ] || ! echo "$container_state" | grep -qi running; then
      log "Reconcile: removing stale agent $agent (not running)"
      modify_state 'del(.agents[$a])' --arg a "$agent"
      rm -f "$ACTIVITY_DIR/$agent"
    else
      log "Reconcile: agent $agent is running, keeping"
      touch "$ACTIVITY_DIR/$agent"
    fi
  done
  update_roster
  local running
  running=$(count_running)
  log "Reconcile complete: $running agents running"
}

# --- Main ---
log "========================================="
log "Pool manager starting (max=$MAX_AGENTS, port=$HTTP_PORT)"
log "========================================="

# Reconcile state before doing anything else
reconcile_state

# Start sync loop in background
sync_activity &
SYNC_PID=$!
trap "kill $SYNC_PID 2>/dev/null; log 'Pool manager stopped'; exit 0" EXIT INT TERM

# Autostart agents (only fill remaining slots)
if [ -f "$AUTOSTART_FILE" ]; then
  log "Processing autostart..."
  current_running=$(count_running)
  count=0
  while IFS= read -r agent; do
    agent="${agent%%#*}"
    agent="$(echo "$agent" | tr -d '[:space:]')"
    [ -z "$agent" ] && continue
    if [ "$((current_running + count))" -ge "$MAX_AGENTS" ]; then
      log "Autostart: skipping $agent (pool full)"
      continue
    fi
    # Skip if already running
    if read_state | jq -e --arg a "$agent" '.agents[$a]' >/dev/null 2>&1; then
      log "Autostart: $agent already running, skipping"
      continue
    fi
    log "Autostart: $agent"
    start_agent "$agent" "autostart"
    count=$((count + 1))
    sleep 3
  done < "$AUTOSTART_FILE"
  log "Autostart complete ($count new agents started, $((current_running + count)) total)"
fi

log "HTTP server listening on port $HTTP_PORT"
# max-children=5 limits concurrent connections to prevent DoS
exec socat TCP-LISTEN:"$HTTP_PORT",fork,reuseaddr,max-children=5 EXEC:"bash $POOL_DIR/pool-handler.sh"
