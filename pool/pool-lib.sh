#!/bin/bash
# Shared functions for pool manager and handler.
# Sourced by pool-manager.sh and pool-handler.sh.

# Load .env config (env vars and systemd EnvironmentFile= take precedence)
POOL_DIR="${POOL_DIR:-/home/tho/openclaw/pool}"
if [ -f "$POOL_DIR/pool.env" ]; then
  set -a
  # shellcheck source=/dev/null
  source "$POOL_DIR/pool.env"
  set +a
fi

# Apply defaults for anything not set by pool.env or environment
POOL_DIR="${POOL_DIR:-/home/tho/openclaw/pool}"
STATE_FILE="$POOL_DIR/state.json"
LOCK_FILE="$POOL_DIR/.lock"
ACTIVITY_DIR="$POOL_DIR/activity"
ROSTER_FILE="$POOL_DIR/roster.json"
COMPOSE_DIR="${COMPOSE_DIR:-/home/tho/openclaw}"
MAX_AGENTS="${MAX_AGENTS:-3}"
EVICT_GRACE_SECONDS="${EVICT_GRACE_SECONDS:-60}"
SYNC_INTERVAL="${SYNC_INTERVAL:-15}"
HEARTBEAT_INTERVAL="${HEARTBEAT_INTERVAL:-30}"
MAX_BODY_SIZE="${MAX_BODY_SIZE:-4096}"
LOG_FILE="$POOL_DIR/pool-manager.log"

log() { echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] $1" >> "$LOG_FILE"; }

# --- Input Validation ---

validate_agent_name() {
  local name="$1"
  [[ "$name" =~ ^[a-zA-Z0-9][a-zA-Z0-9._-]{0,63}$ ]]
}

# --- Atomic State Operations ---
# All state mutations use exclusive flock to prevent TOCTOU races.

read_state() { flock -s "$LOCK_FILE" cat "$STATE_FILE"; }

# Atomically modify state.json: reads current state, applies jq filter, validates, writes.
# Usage: modify_state '.agents[$a].last_active = $now' --arg a "$agent" --arg now "$now"
modify_state() {
  local jq_filter="$1"
  shift
  (
    flock -x 9
    local current new_state
    current=$(cat "$STATE_FILE")
    new_state=$(echo "$current" | jq "$jq_filter" "$@") || {
      log "ERROR: jq failed in modify_state, state unchanged"
      return 1
    }
    # Validate output is valid JSON before writing
    if echo "$new_state" | jq empty 2>/dev/null; then
      echo "$new_state" > "$STATE_FILE"
    else
      log "ERROR: modify_state produced invalid JSON, state unchanged"
      return 1
    fi
  ) 9>"$LOCK_FILE"
}

count_running() {
  local n
  n=$(read_state | jq '.agents | length' 2>/dev/null)
  # Fail closed: if jq fails, assume pool is full
  if [[ "$n" =~ ^[0-9]+$ ]]; then
    echo "$n"
  else
    echo "$MAX_AGENTS"
  fi
}

update_roster() {
  read_state | jq --argjson max "$MAX_AGENTS" '{
    running: [.agents | keys[]],
    slots_total: $max,
    slots_free: ($max - (.agents | length)),
    updated_at: (now | todate)
  }' > "$ROSTER_FILE" 2>/dev/null || true
}

do_heartbeat() {
  local agent="$1"
  # Only heartbeat tracked agents
  if ! read_state | jq -e --arg a "$agent" '.agents[$a]' >/dev/null 2>&1; then
    return 0
  fi
  touch "$ACTIVITY_DIR/$agent" 2>/dev/null || true
  local now
  now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  modify_state '.agents[$a].last_active = $now' --arg a "$agent" --arg now "$now"
}

get_lru_agent() {
  local exclude="${1:-}"
  local now
  now=$(date +%s)
  read_state | jq -r --argjson grace "$EVICT_GRACE_SECONDS" \
    --argjson now "$now" \
    --arg exclude "$exclude" \
    '[.agents | to_entries[]
     | select(.key != $exclude)
     | select((.value.last_active | fromdateiso8601) < ($now - $grace))]
     | sort_by(.value.last_active)
     | .[0].key // empty'
}

start_agent() {
  local agent="$1"
  local requested_by="${2:-api}"
  log "Starting agent: $agent (requested by: $requested_by)"
  if ! docker compose --project-directory "$COMPOSE_DIR" up -d "$agent" >> "$LOG_FILE" 2>&1; then
    log "ERROR: failed to start agent $agent"
    return 1
  fi
  local now
  now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  modify_state \
    '.agents[$agent] = {status:"running",started_at:$now,last_active:$now,requested_by:$by}' \
    --arg agent "$agent" --arg now "$now" --arg by "$requested_by"
  touch "$ACTIVITY_DIR/$agent"
  update_roster
  log "Agent $agent started"
}

stop_agent() {
  local agent="$1"
  log "Stopping agent: $agent"
  timeout 30 docker compose --project-directory "$COMPOSE_DIR" stop -t 10 "$agent" >> "$LOG_FILE" 2>&1 || {
    log "WARNING: docker compose stop timed out for $agent, force killing"
    timeout 10 docker compose --project-directory "$COMPOSE_DIR" kill "$agent" >> "$LOG_FILE" 2>&1 || true
  }
  modify_state 'del(.agents[$agent])' --arg agent "$agent"
  rm -f "$ACTIVITY_DIR/$agent"
  update_roster
  log "Agent $agent stopped"
}

request_agent() {
  local agent="$1"
  local requested_by="${2:-api}"

  # Entire request is serialized via exclusive lock to prevent races
  (
    flock -x 9

    # Already running?
    local state
    state=$(cat "$STATE_FILE")
    if echo "$state" | jq -e --arg a "$agent" '.agents[$a]' >/dev/null 2>&1; then
      # Update heartbeat inline (we hold the lock)
      local now
      now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
      echo "$state" | jq --arg a "$agent" --arg now "$now" \
        '.agents[$a].last_active = $now' > "$STATE_FILE"
      touch "$ACTIVITY_DIR/$agent" 2>/dev/null || true
      echo "{\"status\":\"already_running\",\"agent\":\"$agent\"}"
      return
    fi

    local running
    running=$(echo "$state" | jq '.agents | length')
    running=${running:-0}

    if [ "$running" -lt "$MAX_AGENTS" ]; then
      # Release lock before docker compose (slow operation)
      # Re-acquire after to update state
      flock -u 9
      start_agent "$agent" "$requested_by"
      if [ $? -eq 0 ]; then
        echo "{\"status\":\"started\",\"agent\":\"$agent\"}"
      else
        echo "{\"status\":\"error\",\"error\":\"failed to start container\"}"
      fi
    else
      # Find LRU victim — exclude the requesting agent (not the requester string)
      local victim
      local epoch_now
      epoch_now=$(date +%s)
      victim=$(echo "$state" | jq -r --argjson grace "$EVICT_GRACE_SECONDS" \
        --argjson now "$epoch_now" \
        --arg exclude "$agent" \
        '[.agents | to_entries[]
         | select(.key != $exclude)
         | select((.value.last_active | fromdateiso8601) < ($now - $grace))]
         | sort_by(.value.last_active)
         | .[0].key // empty')

      if [ -n "$victim" ]; then
        log "Evicting $victim to make room for $agent"
        flock -u 9
        stop_agent "$victim"
        start_agent "$agent" "$requested_by"
        if [ $? -eq 0 ]; then
          echo "{\"status\":\"started\",\"agent\":\"$agent\",\"evicted\":\"$victim\"}"
        else
          echo "{\"status\":\"error\",\"error\":\"evicted $victim but failed to start $agent\"}"
        fi
      else
        log "Pool full, all agents recently active - cannot start $agent"
        echo "{\"status\":\"pool_full\",\"error\":\"all agents recently active, try again later\"}"
      fi
    fi
  ) 9>"$LOCK_FILE"
}

release_agent() {
  local agent="$1"
  if read_state | jq -e --arg a "$agent" '.agents[$a]' >/dev/null 2>&1; then
    stop_agent "$agent"
    echo "{\"status\":\"stopped\",\"agent\":\"$agent\"}"
  else
    echo "{\"status\":\"not_running\",\"agent\":\"$agent\"}"
  fi
}

get_status() {
  read_state | jq --argjson max "$MAX_AGENTS" '{
    running: [.agents | to_entries[] | {id: .key, started: .value.started_at, last_active: .value.last_active, requested_by: .value.requested_by}],
    slots_total: $max,
    slots_free: ($max - (.agents | length))
  }'
}

get_available() {
  read_state | jq '{agents: [.agents | keys[]]}'
}
