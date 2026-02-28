#!/bin/bash
# Generate a new OpenClaw agent workspace from a YAML config
#
# Usage:
#   ./gen-agent.sh configs/cfo.yaml
#   ./gen-agent.sh configs/*.yaml          # batch generate all
#   ./gen-agent.sh --list                  # list all configured agents
#   ./gen-agent.sh --stage seed            # list agents for a stage
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
AGENTS_DIR="$(dirname "$SCRIPT_DIR")"

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

info()  { echo -e "${GREEN}[+]${NC} $1"; }
warn()  { echo -e "${YELLOW}[!]${NC} $1"; }

# ── List mode ─────────────────────────────────────────────────
if [[ "${1:-}" == "--list" ]]; then
  echo "Configured agents:"
  for f in "$AGENTS_DIR"/configs/*.yaml; do
    id=$(grep '^ *id:' "$f" | head -1 | awk '{print $2}' | tr -d '"')
    role=$(grep '^ *role:' "$f" | head -1 | sed 's/.*role: *//' | tr -d '"')
    layer=$(grep '^ *layer:' "$f" | head -1 | awk '{print $2}' | tr -d '"')
    printf "  %-25s %-15s %s\n" "$id" "[$layer]" "$role"
  done
  exit 0
fi

if [[ "${1:-}" == "--stage" ]]; then
  stage="${2:?Usage: gen-agent.sh --stage <seed|series-a|series-b|late-stage>}"
  echo "Agents active at stage: $stage"
  for f in "$AGENTS_DIR"/configs/*.yaml; do
    if grep -q "$stage" "$f" 2>/dev/null; then
      id=$(grep '^ *id:' "$f" | head -1 | awk '{print $2}' | tr -d '"')
      role=$(grep '^ *role:' "$f" | head -1 | sed 's/.*role: *//' | tr -d '"')
      printf "  %-25s %s\n" "$id" "$role"
    fi
  done
  exit 0
fi

# ── Generate mode ─────────────────────────────────────────────
if [[ $# -eq 0 ]]; then
  echo "Usage:"
  echo "  $0 configs/cfo.yaml          # generate one agent"
  echo "  $0 configs/*.yaml            # generate all agents"
  echo "  $0 --list                    # list all agents"
  echo "  $0 --stage seed             # list agents for a stage"
  exit 1
fi

for config_file in "$@"; do
  if [[ ! -f "$config_file" ]]; then
    warn "Config not found: $config_file — skipping"
    continue
  fi

  # Extract agent ID from YAML
  agent_id=$(grep '^ *id:' "$config_file" | head -1 | awk '{print $2}' | tr -d '"')
  if [[ -z "$agent_id" ]]; then
    warn "No agent ID found in $config_file — skipping"
    continue
  fi

  workspace="$AGENTS_DIR/workspace-${agent_id}"

  if [[ -f "$workspace/SOUL.md" ]]; then
    info "$agent_id: workspace already exists at $workspace"
    continue
  fi

  mkdir -p "$workspace"

  # Copy the SOUL.md from the config's soul_file reference or generate placeholder
  soul_file="$AGENTS_DIR/workspace-${agent_id}/SOUL.md"
  if [[ ! -f "$soul_file" ]]; then
    role=$(grep '^ *role:' "$config_file" | head -1 | sed 's/.*role: *//' | tr -d '"')
    info "$agent_id: created workspace ($role)"
  fi
done

echo ""
info "Done. Workspaces created in $AGENTS_DIR/workspace-*/"
echo "  Total workspaces: $(ls -d "$AGENTS_DIR"/workspace-*/ 2>/dev/null | wc -l | tr -d ' ')"
