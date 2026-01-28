# PANTHEON

## Autonomous Multi-Agent Claude Code Swarm

Pantheon is a shell-based orchestration system that coordinates multiple AI agents to autonomously build software projects. Each agent has a specialized role, and they communicate through a shared state system to deliver complete, tested, documented code.

---

## Quick Start

```bash
# Make executable
chmod +x pantheon.sh orchestrator.sh
chmod +x lib/*.sh

# Run with a project brief
./pantheon.sh run "Build a REST API for managing tasks"

# Check status
./pantheon.sh status

# Resume after interruption
./pantheon.sh resume 5
```

---

## Vision & Philosophy

**→ [Read the full VISION](./docs/VISION.md)** for the philosophy, architecture, and long-term roadmap.

In brief: Pantheon is built on **specialization**, **model-appropriate routing**, **conditional execution**, and **smart context building**. Each agent does one thing exceptionally well. Work routes to the cheapest model that can handle it. Agents only run when there's actual work. Context is lean and focused.

Result: 40-60% cost reduction vs baseline, faster cycles, better quality.

---

## The Seven Agents

| Agent | Role | Model Tier |
|-------|------|------------|
| **LUMINARY** | Vision, synthesis, strategic direction | Tier 1 (Sonnet) |
| **ARCHITECT** | System design, task decomposition | Tier 2 (Sonnet) |
| **WEAVER** | Coordination, parallel task management | Tier 3 (Haiku) |
| **DJINN** | Implementation, code generation | Tier 2 (Sonnet) |
| **DOCTOR** | Testing, debugging, quality assurance | Tier 2 (Sonnet) |
| **SCRIBE** | Documentation, README, API docs | Tier 3 (Haiku) |
| **CROCODILE** | State management, cleanup, compaction | Tier 3 (Haiku) |

---

## Key Optimizations

Pantheon is optimized for **sustainable operation** - using minimum resources to get the job done.

### 1. Model Tiering (40-60% cost reduction)
Routes each task to the cheapest model that can handle it. Strategic decisions use Sonnet; routine work uses Haiku (10-20x cheaper).

### 2. Conditional Execution (20-30% fewer API calls)
Agents only run when there's actual work. Architect skips if no tasks need decomposition. Doctor skips if no untested code exists.

### 3. Smart Context Building (30-40% fewer input tokens)
Each agent gets tailored context with only what they need, not a full state dump.

### 4. Spawn Budget Controls (50-70% spawn cost reduction)
Maximum 3 spawns per cycle. Quality over quantity. Most spawn work uses Haiku.

### 5. Compressed Agent Prompts (30-40% fewer prompt tokens)
Removed inline code examples that taught Claude things it already knows.

**Combined effect**: A cycle that would cost 100 "rate limit units" now costs 15-30 units.

---

## Configuration

Create `pantheon.conf` for persistent settings:

```bash
# Model assignments
PANTHEON_MODEL_TIER1=claude-sonnet-4-20250514
PANTHEON_MODEL_TIER2=claude-sonnet-4-20250514
PANTHEON_MODEL_TIER3=claude-haiku-4-20250514

# Limits
PANTHEON_MAX_CYCLES=10
PANTHEON_MAX_SPAWNS_PER_CYCLE=3
PANTHEON_AGENT_TIMEOUT=120
PANTHEON_SPAWN_TIMEOUT=180
```

Override at runtime:
```bash
PANTHEON_MAX_SPAWNS_PER_CYCLE=5 ./pantheon.sh run "Build something complex"
```

---

## Directory Structure

```
pantheon/
├── pantheon.sh          # Main launcher
├── orchestrator.sh      # Orchestration engine
├── pantheon.conf        # Configuration (create this)
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
│   ├── state.sh         # State management
│   ├── messaging.sh     # Inter-agent messaging
│   ├── colors.sh        # Terminal colors
│   └── logging.sh       # Logging utilities
│
├── state/               # Runtime state (regenerated)
├── spawn/               # Agent workspaces (regenerated)
├── logs/                # Logs and metrics
├── output/              # Final deliverables
├── artifacts/           # Cycle reports and blueprints
└── docs/                # Documentation
```

---

## Commands

```bash
./pantheon.sh run <brief>       # Start new project
./pantheon.sh run ./brief.md    # Start from file
./pantheon.sh resume [cycles]   # Resume from checkpoint
./pantheon.sh status            # Show current state
./pantheon.sh logs              # Show recent logs
./pantheon.sh config            # Show configuration
./pantheon.sh clean             # Reset all state
./pantheon.sh distill           # Run improvement cycle
```

---

## Demo Project: rscan

Pantheon was tested by building **rscan**, a Rust-based port scanner similar to nmap.

### Project Brief
```
Build a standalone nmap-like port scanner CLI in Rust. Features:
- TCP connect scanning
- Configurable port ranges
- Host discovery (ping)
- Concurrent scanning with adjustable thread count
- Timeout handling
- Clean CLI output showing open/closed/filtered ports
```

### Run Command
```bash
./pantheon.sh run "Build rscan port scanner" --cycles 5
```

### Results
See `output/` for the generated project after a successful run.

---

## Documentation

- **[VISION.md](./docs/VISION.md)** - Complete vision, philosophy, and roadmap
- **[CHANGELOG.md](./CHANGELOG.md)** - All changes, decisions, and project history
- **[README.md](./README.md)** - This file, quick start and command reference
- **.pantheon/state/** - Runtime state files (internal, regenerated per cycle)

---

## Monitoring

### Token Usage
```bash
cat logs/model_selection.log
# [timestamp] agent=luminary complexity=normal model=sonnet
# [timestamp] agent=weaver complexity=simple model=haiku
```

### Agent Skips
```bash
cat logs/agent_skips.log
# [timestamp] SKIP architect: No undecomposed tasks
```

### Context Sizes
```bash
cat logs/context_sizes.log
# [timestamp] agent=djinn chars=2400 est_tokens=600
```

---

## Troubleshooting

### Hitting rate limits?
1. Reduce spawn budget: `PANTHEON_MAX_SPAWNS_PER_CYCLE=2`
2. Use more Haiku: Set `PANTHEON_MODEL_TIER2=claude-haiku-4-20250514`
3. Reduce cycles: `./pantheon.sh run "brief" --cycles 3`

### Agents not doing enough?
1. Force agent: `touch state/force_architect`
2. Increase spawn budget for complex projects
3. Check `logs/agent_skips.log` for skip reasons

### Quality issues?
1. Use more Sonnet for Tier 2
2. Increase spawn budget
3. Run more cycles: `./pantheon.sh resume 10`

---

## How It Works

1. **Initialization**: Pantheon reads the project brief and initializes state
2. **Cycle Loop**: Each cycle runs agents in order:
   - LUMINARY assesses state and sets direction
   - ARCHITECT decomposes tasks (if needed)
   - WEAVER coordinates parallel work (if available)
   - DJINN implements code (if tasks pending)
   - DOCTOR tests and debugs (if untested code)
   - SCRIBE documents (periodically)
   - CROCODILE compacts state and cleans up
3. **Spawning**: Agents can spawn focused sub-agents for parallel work
4. **Completion**: Project completes when all tasks done or max cycles reached
5. **Delivery**: Final code, tests, and docs in `output/`

---

## Requirements

- Bash 4.0+
- `claude` CLI (Claude Code)
- `jq` for JSON processing
- Standard Unix tools (grep, sed, awk)

---

## License

MIT - Use freely, attribute kindly.
