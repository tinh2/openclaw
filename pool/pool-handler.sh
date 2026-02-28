#!/bin/bash
# HTTP request handler for pool manager. Called by socat per-connection.
# Sources pool-lib.sh for shared functions.
set -euo pipefail

POOL_DIR="${POOL_DIR:-/home/tho/openclaw/pool}"
source "$POOL_DIR/pool-lib.sh"

send_response() {
  local code="$1" body="$2"
  local len=${#body}
  printf "HTTP/1.1 %s\r\nContent-Type: application/json\r\nContent-Length: %d\r\nConnection: close\r\n\r\n%s" "$code" "$len" "$body"
}

# Read HTTP request line
read -r method path version 2>/dev/null || exit 0
# Strip trailing CR from HTTP line endings
method="${method%$'\r'}"
path="${path%$'\r'}"

# Validate request line
[[ -n "${method:-}" && -n "${path:-}" ]] || exit 0

# Read headers (case-insensitive Content-Length matching)
content_length=0
while IFS= read -r header; do
  header="${header%$'\r'}"  # Strip trailing CR (HTTP uses CRLF)
  [ -z "$header" ] && break
  local_lower=$(echo "$header" | tr '[:upper:]' '[:lower:]')
  case "$local_lower" in
    content-length:*)
      content_length="${header#*: }"
      content_length="${content_length%$'\r'}"
      ;;
  esac
done

# Read body with size limit
body=""
if [ "$content_length" -gt 0 ] 2>/dev/null; then
  if [ "$content_length" -gt "$MAX_BODY_SIZE" ]; then
    send_response "413 Payload Too Large" '{"error":"request body too large"}'
    exit 0
  fi
  read -rn "$content_length" body 2>/dev/null || true
fi

path="${path%%\?*}"

status_code="200 OK"
response=""

case "$method $path" in
  "POST /request")
    agent=$(echo "$body" | jq -r '.agent // empty' 2>/dev/null)
    by=$(echo "$body" | jq -r '.requested_by // "api"' 2>/dev/null)
    if [ -z "$agent" ]; then
      status_code="400 Bad Request"
      response='{"error":"agent field required"}'
    elif ! validate_agent_name "$agent"; then
      status_code="400 Bad Request"
      response='{"error":"invalid agent name (alphanumeric, hyphens, dots, underscores only)"}'
    elif [ -n "$by" ] && ! validate_agent_name "$by"; then
      by="api"  # fallback to safe default
    fi
    if [ -z "$response" ]; then
      response=$(request_agent "$agent" "$by")
    fi
    ;;
  "POST /release")
    agent=$(echo "$body" | jq -r '.agent // empty' 2>/dev/null)
    if [ -z "$agent" ]; then
      status_code="400 Bad Request"
      response='{"error":"agent field required"}'
    elif ! validate_agent_name "$agent"; then
      status_code="400 Bad Request"
      response='{"error":"invalid agent name"}'
    else
      response=$(release_agent "$agent")
    fi
    ;;
  "POST /heartbeat")
    agent=$(echo "$body" | jq -r '.agent // empty' 2>/dev/null)
    if [ -z "$agent" ]; then
      status_code="400 Bad Request"
      response='{"error":"agent field required"}'
    elif ! validate_agent_name "$agent"; then
      status_code="400 Bad Request"
      response='{"error":"invalid agent name"}'
    else
      do_heartbeat "$agent"
      response='{"status":"ok"}'
    fi
    ;;
  "GET /status"|"GET /status/")
    response=$(get_status)
    ;;
  "GET /available"|"GET /available/")
    response=$(get_available)
    ;;
  "GET /health"|"GET /health/")
    response='{"status":"ok"}'
    ;;
  *)
    status_code="404 Not Found"
    response='{"error":"not found"}'
    ;;
esac

send_response "$status_code" "$response"
