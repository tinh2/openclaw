#!/bin/bash
# Launch OpenClaw agents for a specific company stage
#
# Usage:
#   ./activate-stage.sh seed          # ~8 agents
#   ./activate-stage.sh series-a      # ~20 agents
#   ./activate-stage.sh series-b      # ~30 agents
#   ./activate-stage.sh late-stage    # ~47 agents (full org)
#   ./activate-stage.sh down          # stop all agents
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
AGENTS_DIR="$(dirname "$SCRIPT_DIR")"

GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'

info() { echo -e "${GREEN}[+]${NC} $1"; }
err()  { echo -e "${RED}[x]${NC} $1"; }

stage="${1:?Usage: activate-stage.sh <seed|series-a|series-b|late-stage|down>}"

cd "$AGENTS_DIR"

case "$stage" in
  seed|series-a|series-b|late-stage)
    info "Launching agents for stage: $stage"
    docker compose --profile "$stage" up -d
    echo ""
    info "Running containers:"
    docker compose ps --format "table {{.Name}}\t{{.Status}}\t{{.Ports}}"
    ;;
  down)
    info "Stopping all agents..."
    docker compose down
    ;;
  *)
    err "Unknown stage: $stage"
    echo "Valid stages: seed, series-a, series-b, late-stage, down"
    exit 1
    ;;
esac
