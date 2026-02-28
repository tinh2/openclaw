# OpenClaw Agent Pool Manager

Lightweight pool manager for OpenClaw agent containers. Keeps a fixed number of agents running (default 3) and uses LRU eviction when the pool is full. Agents can request peers on demand — the pool manager handles starting, stopping, and load balancing automatically.

## Architecture

```
Host (systemd)                    Docker containers
┌─────────────────┐              ┌──────────────────┐
│  pool-manager.sh │◄────HTTP────│  agent (ceo)     │
│  :19000 (socat)  │             │  request-agent X  │
│                  │             └──────────────────┘
│  state.json      │──compose──► docker compose up/stop
│  activity/       │
│  roster.json     │──mounted──► /pool/ in containers
└─────────────────┘
```

Infrastructure containers (gateway, litellm, ollama) are always-on. Only agent containers are pooled.

## Configuration

All settings are in `pool.env`. Edit this file and restart the service:

```bash
sudo systemctl restart openclaw-pool
```

| Variable | Default | Description |
|----------|---------|-------------|
| `MAX_AGENTS` | `3` | Max concurrent agent containers |
| `POOL_PORT` | `19000` | HTTP API port |
| `EVICT_GRACE_SECONDS` | `60` | Seconds of protection from eviction after activity |
| `SYNC_INTERVAL` | `15` | Seconds between Docker state reconciliation |
| `HEARTBEAT_INTERVAL` | `30` | Seconds between container heartbeat pings |
| `COMPOSE_DIR` | `/home/tho/openclaw` | Docker Compose project directory |
| `POOL_DIR` | `/home/tho/openclaw/pool` | Pool data directory |
| `MAX_BODY_SIZE` | `4096` | Max HTTP request body size (bytes) |

### Sizing MAX_AGENTS

Each agent uses ~330MB RAM. Formula:

```
MAX_AGENTS = floor((total_ram - 2GB_overhead) / 330MB)
```

| VPS RAM | Recommended MAX_AGENTS |
|---------|----------------------|
| 4GB | 2 |
| 8GB | 3-4 |
| 16GB | 8-10 |

## CLI Usage

```bash
poolctl start <agent>   # Start agent (evicts LRU if full)
poolctl stop <agent>    # Stop agent, free a slot
poolctl status          # Show pool status with details
poolctl who             # List running agent IDs
poolctl health          # Check pool manager health
```

## API Endpoints

| Method | Path | Body | Description |
|--------|------|------|-------------|
| POST | `/request` | `{"agent":"cfo","requested_by":"ceo"}` | Start agent, evict LRU if needed |
| POST | `/release` | `{"agent":"cfo"}` | Stop agent, free slot |
| POST | `/heartbeat` | `{"agent":"ceo"}` | Update activity timestamp |
| GET | `/status` | — | Pool state (running agents, free slots) |
| GET | `/available` | — | List running agent IDs |
| GET | `/health` | — | Health check |

### Response Examples

**Request (started with eviction):**
```json
{"status":"started","agent":"cfo","evicted":"software-engineer"}
```

**Request (pool full, all active):**
```json
{"status":"pool_full","error":"all agents recently active, try again later"}
```

**Status:**
```json
{
  "running": [
    {"id":"ceo","started":"2026-02-28T05:17:04Z","last_active":"2026-02-28T05:20:00Z","requested_by":"autostart"},
    {"id":"cto","started":"2026-02-28T05:17:09Z","last_active":"2026-02-28T05:18:30Z","requested_by":"autostart"}
  ],
  "slots_total": 3,
  "slots_free": 1
}
```

## Cross-Container Agent Requests

Inside any agent container, request a peer:

```bash
request-agent cfo
```

This calls the pool manager API. If the pool is full, the least-recently-active agent is evicted to make room (unless all agents are within the grace period).

## Eviction Rules

1. **LRU** — agent with the oldest `last_active` timestamp is evicted first
2. **Grace period** — agents active within the last `EVICT_GRACE_SECONDS` are protected
3. **Self-protection** — the agent being requested is never evicted
4. **Infrastructure** — gateway, litellm, ollama are never touched
5. **Pool full** — if all agents are within grace period, the request returns an error

## Autostart

On boot, the pool manager starts agents listed in `autostart.txt` (one per line, up to `MAX_AGENTS`):

```
ceo
cto
software-engineer
```

Lines starting with `#` are ignored.

## Systemd Management

```bash
sudo systemctl start openclaw-pool     # Start pool manager
sudo systemctl stop openclaw-pool      # Stop pool manager + agents
sudo systemctl restart openclaw-pool   # Restart (reconciles state)
sudo systemctl status openclaw-pool    # Check status
journalctl -u openclaw-pool -f         # Follow logs
```

The service auto-restarts on failure (10s delay) and starts on boot.

## Files

```
pool/
├── pool.env              # Configuration (edit this)
├── pool-manager.sh       # Main daemon (systemd ExecStart)
├── pool-lib.sh           # Shared functions
├── pool-handler.sh       # HTTP request handler (called by socat)
├── poolctl               # CLI tool
├── autostart.txt         # Agents to start on boot
├── request-agent.sh      # In-container script (baked into Docker image)
├── heartbeat.sh          # In-container heartbeat (baked into Docker image)
├── state.json            # Runtime state (auto-managed)
├── roster.json           # Read-only roster for containers
├── activity/             # Activity tracking files
└── pool-manager.log      # Log file (rotated weekly)
```

## Troubleshooting

**Pool manager not responding:**
```bash
sudo systemctl status openclaw-pool
curl -s http://localhost:19000/health
```

**Agent won't start (pool full):**
```bash
poolctl status                    # Check who's running
poolctl stop <idle-agent>         # Free a slot manually
poolctl start <desired-agent>     # Start the agent you need
```

**State out of sync with Docker:**
```bash
sudo systemctl restart openclaw-pool   # Triggers full reconciliation
```

**Check logs:**
```bash
tail -50 /home/tho/openclaw/pool/pool-manager.log
```
