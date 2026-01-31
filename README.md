# PANTHEON

## Autonomous Multi-Agent Claude Code Swarm

Pantheon is a shell-based orchestration system that coordinates multiple AI agents to autonomously build software projects. Each agent has a specialized role, and they communicate through a shared state system to deliver complete, tested, documented code.

**Version 11** - Optimized for token efficiency and self-healing resilience.

---

## Quick Start

```bash
# Make executable
chmod +x pantheon.sh orchestrator.sh templecat.sh
chmod +x lib/*.sh

# Run with a project brief
./pantheon.sh run "Build a REST API for managing tasks"

# Start Templecat guardian (monitors and self-heals)
./templecat.sh --daemon

# Check status
./pantheon.sh status

# Resume after interruption
./pantheon.sh resume 5
```

---

## Vision & Philosophy

Pantheon is built on **specialization**, **model-appropriate routing**, **conditional execution**, and **smart context building**. Each agent does one thing exceptionally well. Work routes to the cheapest model that can handle it. Agents only run when there's actual work. Context is lean and focused.

Result: 40-60% cost reduction vs baseline, faster cycles, better quality.

---

## The Eight Agents

| Agent | Role | Model Tier |
|-------|------|------------|
| **LUMINARY** | Vision, synthesis, strategic direction | Tier 1 (Sonnet) |
| **ARCHITECT** | System design, task decomposition | Tier 2 (Sonnet) |
| **WEAVER** | Coordination, parallel task management | Tier 3 (Haiku) |
| **DJINN** | Implementation, code generation | Tier 2 (Sonnet) |
| **DOCTOR** | Testing, debugging, quality assurance | Tier 0 (Opus) |
| **ALETHEIA** | External supervisor, verification watchdog | Tier 0 (Opus) |
| **SCRIBE** | Documentation, README, API docs | Tier 3 (Haiku) |
| **CROCODILE** | State management, cleanup, compaction | Tier 3 (Haiku) |

---

## Templecat Guardian

Templecat is the **heartbeat** of the Pantheon - a guardian daemon that monitors system health and triggers self-healing when issues occur.

### Starting Templecat

```bash
# Start as daemon (recommended)
./templecat.sh --daemon

# Brief mode (quick health check)
./templecat.sh --brief

# Stop the guardian
./templecat.sh --stop

# Check status
./templecat.sh --status
```

### How It Works

1. **Continuous Monitoring** - Checks Pantheon logs every 30 seconds
2. **Stall Detection** - Detects when agents hang or cycles stall (configurable threshold)
3. **Smart Detection** - Checks if Claude processes are actually running before declaring stall
4. **Self-Healing** - Spawns Aletheia to diagnose and fix issues
5. **Helper Djinns** - Can spawn focused helper agents for stuck tasks

### Configuration

In `pantheon.conf`:
```bash
# Templecat stall threshold (seconds before declaring stall)
TEMPLECAT_STALL=600

# Check interval (how often to check health)
TEMPLECAT_INTERVAL=30
```

---

## Aletheia - The Sentinel

Aletheia runs **OUTSIDE** the main cycle as a separate Claude Code session with **FULL AUTONOMY**. She is the immune system of the Pantheon:

- **Monitors continuously** - Watches state files, logs, agent health metrics
- **Self-healing** - When agents fail or timeout, she diagnoses and FIXES issues directly
- **Direct intervention** - Can edit code to fix compilation errors, not just report them
- **Cycle control** - Restarts cycles with context injection when needed
- **Quality enforcement** - All gates must pass before approval

**Starting Aletheia:**
```bash
./pantheon.sh aletheia
```

Her mandate: *"I am the immune system. When cells fail, I repair them. The organism survives because I am vigilant."*

---

## Key Optimizations

### 1. Model Tiering (40-60% cost reduction)
Routes each task to the cheapest model that can handle it. Strategic decisions use Sonnet; routine work uses Haiku (10-20x cheaper).

### 2. Conditional Execution (20-30% fewer API calls)
Agents only run when there's actual work. Architect skips if no tasks need decomposition.

### 3. Smart Context Building (50-70% fewer input tokens)
- Task summaries show **top 15 priority items only** (not all tasks)
- Descriptions truncated to 60 chars
- Each agent gets tailored context with only what they need
- No raw JSON dumps - human-readable summaries

### 4. Spawn Budget Controls (50-70% spawn cost reduction)
Maximum 3 spawns per cycle. Quality over quantity. Most spawn work uses Haiku.

### 5. Mid-Cycle Resume
Tracks which agents completed within a cycle. On restart, skips already-completed agents.

**Combined effect**: A cycle that would cost 100 "rate limit units" now costs 15-30 units.

---

## Configuration

Edit `pantheon.conf`:

```bash
# Templecat Guardian
TEMPLECAT_STALL=600          # Seconds before stall detection

# Model tiers (use correct model names!)
PANTHEON_MODEL_TIER0=claude-opus-4-20250514
PANTHEON_MODEL_TIER1=claude-sonnet-4-20250514
PANTHEON_MODEL_TIER2=claude-sonnet-4-20250514
PANTHEON_MODEL_TIER3=claude-3-5-haiku-20241022

# Timeouts
PANTHEON_AGENT_TIMEOUT=600   # 10 min per agent
PANTHEON_SPAWN_TIMEOUT=300   # 5 min per spawn

# Limits
PANTHEON_MAX_CYCLES=5
PANTHEON_MAX_SPAWNS_PER_CYCLE=3

# Verification
PANTHEON_REQUIRE_VERIFICATION=true
PANTHEON_VERIFICATION_STEPS=build,tests,smoke
```

**Important**: Claude 4 Haiku does not exist. Use `claude-3-5-haiku-20241022` for Tier 3.

---

## Directory Structure

```
pantheon/
├── pantheon.sh          # Main launcher
├── orchestrator.sh      # Orchestration engine
├── templecat.sh         # Guardian daemon
├── pantheon.conf        # Configuration
│
├── agents/              # Agent personality definitions
│   ├── luminary.md, architect.md, weaver.md
│   ├── djinn.md, doctor.md, scribe.md, crocodile.md
│
├── lib/                 # Core libraries
│   ├── models.sh        # Model selection logic
│   ├── context.sh       # Smart context building
│   ├── conditional.sh   # Conditional execution
│   ├── spawner.sh       # Spawn budget controls
│   ├── state.sh         # State management + mid-cycle resume
│   ├── messaging.sh     # Inter-agent messaging
│   ├── self_heal.sh     # Self-healing utilities
│   ├── colors.sh        # Terminal colors
│   └── logging.sh       # Logging utilities
│
├── .pantheon/           # Runtime (auto-generated)
│   ├── state/           # Task board, artifacts, messages
│   ├── logs/            # Pantheon logs, token usage
│   └── spawn/           # Worker workspaces
│
├── projects/            # Generated project code
└── output/              # Final deliverables
```

---

## Commands

```bash
./pantheon.sh run <brief>       # Start new project
./pantheon.sh run ./brief.md    # Start from file
./pantheon.sh resume [cycles]   # Resume from checkpoint
./pantheon.sh aletheia          # Run Aletheia as external supervisor
./pantheon.sh status            # Show current state
./pantheon.sh logs              # Show recent logs
./pantheon.sh config            # Show configuration
./pantheon.sh clean             # Reset all state

./templecat.sh --daemon         # Start guardian
./templecat.sh --stop           # Stop guardian
./templecat.sh --status         # Check guardian status
```

---

## Monitoring

### Live Monitoring
```bash
# Watch pantheon logs
tail -f .pantheon/logs/pantheon.log

# Watch templecat
tail -f .pantheon/logs/templecat.log

# Watch both
tail -f .pantheon/logs/*.log
```

### Token Usage
```bash
cat .pantheon/logs/token_usage.log
# [timestamp] agent=djinn input=2369 output=774 total=3143 tasks=6 efficiency=1
```

### Model Selection
```bash
cat .pantheon/logs/model_selection.log
# [timestamp] agent=weaver complexity=normal model=claude-3-5-haiku-20241022
```

---

## Self-Healing System

Pantheon includes multiple self-healing layers:

1. **Templecat Guardian** - External daemon monitoring for stalls
2. **Smart Stall Detection** - Checks if Claude is actually running before declaring stall
3. **Mid-Cycle Resume** - Tracks which agents completed, resumes from interruption point
4. **Helper Djinns** - Spawns focused workers for stuck agents
5. **Aletheia Intervention** - Full diagnostic and repair capability

### Health Files
- `.pantheon/state/agent_health.json` - Agent health metrics
- `.pantheon/state/current_agent.json` - Current running agent
- `.pantheon/logs/token_usage.log` - Token efficiency data

---

## Troubleshooting

### Hitting rate limits?
1. Reduce spawn budget: `PANTHEON_MAX_SPAWNS_PER_CYCLE=2`
2. Use longer timeouts: `PANTHEON_AGENT_TIMEOUT=600`
3. Reduce cycles: `./pantheon.sh run "brief" --cycles 3`

### Agents timing out?
1. Increase timeout: `PANTHEON_AGENT_TIMEOUT=600`
2. Increase stall threshold: `TEMPLECAT_STALL=600`
3. Check if tasks are too large (need decomposition)

### Haiku agents returning errors?
Ensure you're using the correct model name:
```bash
PANTHEON_MODEL_TIER3=claude-3-5-haiku-20241022  # Correct
# NOT: claude-haiku-4-20250514 (doesn't exist!)
```

### System stalling?
1. Check Templecat status: `./templecat.sh --status`
2. Check for stuck processes: `pgrep -af claude`
3. Manual restart: `./templecat.sh --stop && ./pantheon.sh resume 5`

---

## Requirements

- Bash 4.0+
- `claude` CLI (Claude Code)
- `jq` for JSON processing
- Standard Unix tools (grep, sed, awk)

---

## License

MIT - Use freely, attribute kindly.
