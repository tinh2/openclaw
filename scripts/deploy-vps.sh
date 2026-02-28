#!/bin/bash
# Deploy OpenClaw SaaS Org Chart agents to a VPS
#
# Usage:
#   ./deploy-vps.sh <user@host>                    # Deploy seed stage (default)
#   ./deploy-vps.sh <user@host> seed               # Deploy seed stage
#   ./deploy-vps.sh <user@host> series-a            # Deploy series-a
#   ./deploy-vps.sh <user@host> late-stage          # Deploy full org
#
# Prerequisites:
#   - SSH access to VPS
#   - Docker + Docker Compose on VPS
#   - ANTHROPIC_API_KEY set locally or on VPS
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
AGENTS_DIR="$(dirname "$SCRIPT_DIR")"

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
CYAN='\033[0;36m'
NC='\033[0m'

info()  { echo -e "${GREEN}[+]${NC} $1"; }
warn()  { echo -e "${YELLOW}[!]${NC} $1"; }
err()   { echo -e "${RED}[x]${NC} $1"; }
step()  { echo -e "\n${CYAN}=== $1 ===${NC}"; }

VPS="${1:?Usage: deploy-vps.sh <user@host> [stage]}"
STAGE="${2:-seed}"
REMOTE_DIR="/home/$(echo "$VPS" | cut -d@ -f1)/openclaw"

# Validate stage
case "$STAGE" in
  seed|series-a|series-b|late-stage) ;;
  *) err "Invalid stage: $STAGE (valid: seed, series-a, series-b, late-stage)"; exit 1 ;;
esac

# ── Phase 1: Test connection ──────────────────────────────────
step "Phase 1: Testing SSH connection"
if ! ssh -o ConnectTimeout=10 "$VPS" "echo connected" &>/dev/null; then
  err "Cannot connect to $VPS"
  exit 1
fi
info "Connected to $VPS"

# ── Phase 2: Check Docker on VPS ─────────────────────────────
step "Phase 2: Checking Docker on VPS"
if ! ssh "$VPS" "docker --version" &>/dev/null; then
  err "Docker not installed on VPS. Install first: curl -fsSL https://get.docker.com | sh"
  exit 1
fi
DOCKER_VERSION=$(ssh "$VPS" "docker --version" 2>/dev/null)
info "Docker: $DOCKER_VERSION"

if ! ssh "$VPS" "docker compose version" &>/dev/null; then
  err "Docker Compose not available. Install docker-compose-plugin."
  exit 1
fi
info "Docker Compose available"

# ── Phase 3: Create remote directories ───────────────────────
step "Phase 3: Creating directories on VPS"
ssh "$VPS" "mkdir -p $REMOTE_DIR/{configs,workspace-ceo,workspace-cfo,workspace-cto,workspace-software-engineer,workspace-qa-engineer,workspace-product-manager,workspace-growth-marketer,workspace-csm,workspace-board-skeptic,workspace-power-user,workspace-competitor-ceo,workspace-main,workspace-pm,workspace-engineer,workspace-qa}"

# Create all workspace dirs based on stage
if [ "$STAGE" != "seed" ]; then
  ssh "$VPS" "mkdir -p $REMOTE_DIR/{workspace-coo,workspace-cpo,workspace-cro,workspace-staff-engineer,workspace-devops,workspace-ux-designer,workspace-content-marketer,workspace-pmm,workspace-perf-marketer,workspace-sdr,workspace-account-exec,workspace-sales-ops,workspace-support-lead,workspace-revops,workspace-bizops,workspace-head-of-people,workspace-activist-investor,workspace-churned-customer}"
fi
if [ "$STAGE" = "series-b" ] || [ "$STAGE" = "late-stage" ]; then
  ssh "$VPS" "mkdir -p $REMOTE_DIR/{workspace-security-engineer,workspace-data-engineer,workspace-data-scientist,workspace-brand-strategist,workspace-marketing-ops,workspace-enterprise-sales,workspace-sales-engineer,workspace-implementation,workspace-community-manager,workspace-fpa-analyst,workspace-controller,workspace-legal-counsel,workspace-recruiter,workspace-chief-of-staff,workspace-procurement-officer}"
fi
if [ "$STAGE" = "late-stage" ]; then
  ssh "$VPS" "mkdir -p $REMOTE_DIR/{workspace-talent-ops,workspace-partnerships,workspace-corp-dev}"
fi
info "Directories created"

# ── Phase 4: Upload files ────────────────────────────────────
step "Phase 4: Uploading agent configs"

# Upload core files
scp "$AGENTS_DIR/docker-compose.yml" "$VPS:$REMOTE_DIR/"
scp "$AGENTS_DIR/Dockerfile.custom" "$VPS:$REMOTE_DIR/"
scp "$AGENTS_DIR/openclaw.json" "$VPS:$REMOTE_DIR/"
info "Core files uploaded"

# Upload all configs
scp "$AGENTS_DIR"/configs/*.yaml "$VPS:$REMOTE_DIR/configs/"
info "YAML configs uploaded ($(ls "$AGENTS_DIR"/configs/*.yaml | wc -l | tr -d ' ') files)"

# Upload all SOUL.md files
for workspace in "$AGENTS_DIR"/workspace-*/; do
  name=$(basename "$workspace")
  if [ -f "$workspace/SOUL.md" ]; then
    scp "$workspace/SOUL.md" "$VPS:$REMOTE_DIR/$name/" 2>/dev/null || true
  fi
done
info "SOUL.md files uploaded"

# Upload scripts
ssh "$VPS" "mkdir -p $REMOTE_DIR/scripts"
scp "$AGENTS_DIR"/scripts/*.sh "$VPS:$REMOTE_DIR/scripts/"
ssh "$VPS" "chmod +x $REMOTE_DIR/scripts/*.sh"
info "Scripts uploaded"

# ── Phase 5: Setup .env ──────────────────────────────────────
step "Phase 5: Configuring environment"

# Check if .env already exists
if ssh "$VPS" "test -f $REMOTE_DIR/.env" 2>/dev/null; then
  info ".env already exists on VPS"
else
  # Generate gateway token
  GW_TOKEN=$(openssl rand -hex 32)
  REMOTE_USER=$(echo "$VPS" | cut -d@ -f1)

  # Check for API key
  API_KEY="${ANTHROPIC_API_KEY:-}"
  if [ -z "$API_KEY" ]; then
    warn "ANTHROPIC_API_KEY not set locally."
    warn "You'll need to edit $REMOTE_DIR/.env on the VPS manually."
    API_KEY="YOUR_KEY_HERE"
  fi

  ssh "$VPS" "cat > $REMOTE_DIR/.env << 'ENVEOF'
ANTHROPIC_API_KEY=$API_KEY
OPENCLAW_GATEWAY_TOKEN=$GW_TOKEN
OPENCLAW_CONFIG_DIR=$REMOTE_DIR
OPENCLAW_WORKSPACE_DIR=$REMOTE_DIR/workspace-main
OPENCLAW_IMAGE=openclaw:custom
OPENCLAW_GATEWAY_BIND=lan
OPENCLAW_GATEWAY_PORT=18789
OPENCLAW_BRIDGE_PORT=18790
ENVEOF
chmod 600 $REMOTE_DIR/.env"
  info "Created .env (gateway token: ${GW_TOKEN:0:8}...)"
fi

# ── Phase 6: Clone & build OpenClaw ──────────────────────────
step "Phase 6: Building OpenClaw Docker image"

# Check if openclaw:local exists
if ssh "$VPS" "docker images openclaw:local --format '{{.ID}}' | grep -q ." 2>/dev/null; then
  info "openclaw:local already built"
else
  info "Cloning and building openclaw:local (this takes a few minutes)..."
  ssh "$VPS" "
    if [ ! -d /tmp/openclaw-build ]; then
      git clone https://github.com/openclaw/openclaw.git /tmp/openclaw-build
    fi
    cd /tmp/openclaw-build && docker build -t openclaw:local -f Dockerfile .
  "
  info "openclaw:local built"
fi

# Build custom image
info "Building openclaw:custom..."
ssh "$VPS" "cd $REMOTE_DIR && docker build -f Dockerfile.custom -t openclaw:custom ."
info "openclaw:custom built"

# ── Phase 7: Copy openclaw.json to config dir ────────────────
step "Phase 7: Setting up OpenClaw config"
ssh "$VPS" "
  mkdir -p ~/.openclaw
  cp $REMOTE_DIR/openclaw.json ~/.openclaw/
  # Rewrite workspace paths to match remote
  cd $REMOTE_DIR
  for ws in workspace-*/; do
    name=\${ws%/}
    mkdir -p ~/.openclaw/\$name
    if [ -f \"\$ws/SOUL.md\" ]; then
      cp \"\$ws/SOUL.md\" ~/.openclaw/\$name/
    fi
  done
"
info "OpenClaw config deployed to ~/.openclaw/"

# ── Phase 8: Launch ──────────────────────────────────────────
step "Phase 8: Launching $STAGE stage"
ssh "$VPS" "cd $REMOTE_DIR && docker compose --profile $STAGE up -d"
info "Containers launching..."

# Wait a moment for startup
sleep 5

# ── Phase 9: Verify ──────────────────────────────────────────
step "Phase 9: Verification"
ssh "$VPS" "cd $REMOTE_DIR && docker compose ps --format 'table {{.Name}}\t{{.Status}}'"

GATEWAY_STATUS=$(ssh "$VPS" "cd $REMOTE_DIR && docker compose ps openclaw-gateway --format '{{.Status}}'" 2>/dev/null || echo "unknown")
if echo "$GATEWAY_STATUS" | grep -qi "up\|running"; then
  info "Gateway is running!"
else
  warn "Gateway status: $GATEWAY_STATUS"
fi

# Get access URL
VPS_IP=$(echo "$VPS" | cut -d@ -f2)
TS_IP=$(ssh "$VPS" "tailscale ip -4 2>/dev/null" || echo "$VPS_IP")
GW_TOKEN=$(ssh "$VPS" "grep OPENCLAW_GATEWAY_TOKEN $REMOTE_DIR/.env | cut -d= -f2")

echo ""
echo -e "${GREEN}=== Deployment Complete ===${NC}"
echo ""
echo "  Stage: $STAGE"
echo "  URL:   http://$TS_IP:18789/"
echo "  Token: $GW_TOKEN"
echo ""
echo "  Manage:"
echo "    ssh $VPS 'cd $REMOTE_DIR && docker compose ps'"
echo "    ssh $VPS 'cd $REMOTE_DIR && docker compose logs -f ceo'"
echo "    ssh $VPS 'cd $REMOTE_DIR && docker compose --profile series-a up -d'  # upgrade stage"
echo "    ssh $VPS 'cd $REMOTE_DIR && docker compose down'  # stop all"
