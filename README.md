# PANTHEON

## Autonomous Multi-Agent Claude Code Swarm

Pantheon is a self-orchestrating system of seven specialized AI agents that work together to build software projects. Give it a brief, and the agents collaborate—spawning workers, managing state, testing code, and documenting everything—until the project is complete.

```
╔═══════════════════════════════════════════════════════════════════════╗
║                                                                       ║
║      CROCODILE ←──────────────────────────────────────┐            ║
║         ↑                                               │            ║
║         │ state                                         │ persist    ║
║         │                                               │            ║
║      LUMINARY ─── vision ───→ ARCHITECT           │            ║
║         │                           │                   │            ║
║         │ direction                 │ tasks             │            ║
║         ↓                           ↓                   │            ║
║      SCRIBE ←─── docs ─────── WEAVER ──┬──→ spawn │            ║
║         ↑                           │        │          │            ║
║         │ record                    │        ↓          │            ║
║         │                           │    [workers]      │            ║
║         │                           ↓                   │            ║
║      DOCTOR ←── test ───────  DJINN ────┴──→ spawn │            ║
║                                     │                   │            ║
║                                     └───────────────────┘            ║
║                                                                       ║
╚═══════════════════════════════════════════════════════════════════════╝
```

## The Seven Agents

### THE CROCODILE
**Role:** Database, Garbage Collection, State Management  
**Position:** Last in every cycle  
**Power:** Total memory, state persistence

The Crocodile is the foundation. It maintains the canonical state of the project, archives completed work, compacts redundant data, and ensures nothing important is ever lost. It runs LAST in every cycle, cleaning up after all other agents.

### THE SCRIBE
**Role:** Documentation, Recording, Changelog  
**Power:** Captures WHY, not just WHAT

The Scribe ensures the project is comprehensible. It documents decisions, maintains the README, writes API docs, and keeps the changelog current. Without the Scribe, the code is a locked room with no key.

### THE ARCHITECT
**Role:** System Design, Task Decomposition, Structure  
**Power:** Sees the whole system, defines boundaries

The Architect ensures coherent structure. It breaks complex problems into manageable tasks, defines interfaces between components, maps dependencies, and flags architectural risks. No circular dependencies on the Architect's watch.

### THE WEAVER
**Role:** Integration, Coordination, Parallel Work  
**Power:** AGGRESSIVE SUBAGENT SPAWNING 

The Weaver parallelizes everything. It identifies work that can happen simultaneously and SPAWNS specialist workers to handle it. Frontend, backend, testing—the Weaver spins up workers aggressively and weaves their outputs together.

### THE DOCTOR
**Role:** Testing, Debugging, Quality Assurance  
**Power:** Diagnoses problems, prescribes fixes

The Doctor trusts nothing and tests everything. It writes tests, diagnoses bugs, tracks quality metrics, and ensures no regression escapes. Untested code is broken code in the Doctor's eyes.

### THE LUMINARY
**Role:** Vision, Synthesis, Direction  
**Position:** First to assess, final approval  
**Power:** Decides when the project is complete

The Luminary holds the vision. It synthesizes insights from all agents, resolves blockers, arbitrates conflicts, and determines when the project has truly achieved its goals. The Luminary provides light when others are lost.

### THE DJINN
**Role:** Implementation, Code Generation  
**Power:**  AGGRESSIVE SUBAGENT SPAWNING 

The Djinn turns designs into reality. Your wish is its command. It implements features, writes production-ready code, and spawns specialist workers for complex implementations. What the Architect designs, the Djinn builds.

## Installation

```bash
# Clone or copy the pantheon directory
cp -r pantheon /path/to/your/projects/

# Make scripts executable
chmod +x /path/to/pantheon/*.sh
chmod +x /path/to/pantheon/lib/*.sh

# Ensure Claude CLI is installed and authenticated
# https://docs.anthropic.com/claude-code
```

## Usage

### Quick Start
```bash
# Run with a simple brief
./pantheon.sh run "Build a REST API for user management with authentication"

# Run with a detailed brief file
./pantheon.sh run ./my_project_brief.md

# Interactive mode
./pantheon.sh interactive

# Check status
./pantheon.sh status

# View logs
./pantheon.sh logs

# Clean and start fresh
./pantheon.sh clean
```

### Project Brief Format
Your brief can be a simple string or a detailed markdown file:

```markdown
# Project: User Management API

## Overview
Build a RESTful API for user management with the following features:
- User registration and authentication (JWT)
- Profile management
- Role-based access control

## Technical Requirements
- Language: Python 3.11+
- Framework: FastAPI
- Database: PostgreSQL
- Auth: JWT with refresh tokens

## Deliverables
- Working API with all endpoints
- Database migrations
- Unit and integration tests
- API documentation
- Docker configuration
```

### Configuration

Edit cycle count and other options:
```bash
./pantheon.sh run "Your brief" --cycles 20 --verbose
```

## Directory Structure

```
pantheon/
├── pantheon.sh          # Main launcher
├── orchestrator.sh      # Core orchestration logic
├── README.md            # This file
│
├── agents/              # Agent personalities and prompts
│   ├── crocodile.md
│   ├── scribe.md
│   ├── architect.md
│   ├── weaver.md
│   ├── doctor.md
│   ├── luminary.md
│   └── djinn.md
│
├── lib/                 # Shared libraries
│   ├── colors.sh        # Terminal formatting
│   ├── logging.sh       # Logging utilities
│   ├── state.sh         # State management (Crocodile's domain)
│   ├── messaging.sh     # Inter-agent messaging
│   └── spawner.sh       # Subagent spawning system
│
├── state/               # Runtime state (auto-generated)
│   ├── task_board.json
│   ├── message_queue.json
│   ├── agent_status.json
│   ├── artifacts.json
│   ├── spawn_registry.json
│   ├── memory.json
│   ├── decisions.json
│   └── project_state.md
│
├── spawn/               # Subagent workspaces
├── logs/                # Agent and system logs
├── tasks/               # Task files
└── output/              # Final deliverables
```

## Agent Communication Protocol

Agents communicate via structured markers in their output:

```markdown
# Tasks
[TASK]Description of work to be done[/TASK]
[TASK:high]High priority task[/TASK]

# Messages
[MSG:agent_name]Content for that agent[/MSG]

# Artifacts
[ARTIFACT:path/to/file.ext]
File contents
[/ARTIFACT]

# Spawning (Weaver and Djinn only)
[SPAWN]specialization:task description[/SPAWN]

# Completion
[COMPLETE]
```

## Spawn Specializations

The Weaver and Djinn can spawn these specialist workers:

| Specialization | Focus Area |
|---------------|------------|
| `frontend` | UI, components, styling |
| `backend` | APIs, server logic |
| `database` | Schema, queries, migrations |
| `testing` | Unit, integration, E2E tests |
| `security` | Audits, hardening |
| `devops` | CI/CD, Docker, deployment |
| `documentation` | Docs, comments, guides |
| `refactor` | Code improvement |
| `algorithm` | Complex logic, optimization |

## Cycle Flow

Each cycle follows this sequence:

1. **LUMINARY** - Assess state, synthesize direction
2. **ARCHITECT** - Review structure, decompose tasks
3. **WEAVER** - Integrate, spawn parallel workers
4. **DJINN** - Implement, spawn implementation workers
5. **DOCTOR** - Test, diagnose, prescribe
6. **SCRIBE** - Document changes and decisions
7. **CROCODILE** - Compact state, persist, archive

Cycles repeat until LUMINARY declares `[COMPLETE]` or max cycles reached.

## Extending Pantheon

### Adding New Agents
1. Create agent prompt file in `agents/`
2. Add to cycle in `orchestrator.sh`
3. Register in `init_pantheon()`

### Adding New Spawn Specializations
1. Add case in `lib/spawner.sh` `get_specialization_prompt()`
2. Document in README

### Custom State
Use the Crocodile's memory system:
```bash
source lib/state.sh
remember "key" "value"
recall "key"
```

## Troubleshooting

### Agents not executing
- Ensure Claude CLI is installed and authenticated
- Check `logs/pantheon.log` for errors

### State corruption
- Run `./pantheon.sh clean` to reset
- Check `state/checkpoints/` for restore points

### Spawned agents failing
- Check `spawn/*/response.md` for outputs
- Increase timeout in `lib/spawner.sh`

## License

MIT - Use freely, attribute kindly.

---

*"In the beginning was chaos. Into chaos we bring light. We are PANTHEON."*
