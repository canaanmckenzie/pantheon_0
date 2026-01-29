#!/bin/bash
#
# PANTHEON LAUNCHER - OPTIMIZED
# =============================
# Simple entry point to run the agent swarm
#
# USAGE:
#   ./pantheon.sh run "Your project brief"
#   ./pantheon.sh run ./brief.md --cycles 15
#   ./pantheon.sh resume 5
#   ./pantheon.sh status
#   ./pantheon.sh config
#

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# =============================================================================
# CONFIGURATION
# =============================================================================

# Load config file if exists
[[ -f "$SCRIPT_DIR/pantheon.conf" ]] && source "$SCRIPT_DIR/pantheon.conf"

# Defaults (can be overridden via environment or config file)
: "${PANTHEON_MAX_CYCLES:=10}"
: "${PANTHEON_MAX_SPAWNS_PER_CYCLE:=3}"
: "${PANTHEON_AGENT_TIMEOUT:=300}"
: "${PANTHEON_MODEL_TIER0:=opus}"
: "${PANTHEON_MODEL_TIER1:=sonnet}"
: "${PANTHEON_MODEL_TIER2:=sonnet}"
: "${PANTHEON_MODEL_TIER3:=haiku}"

export PANTHEON_MAX_CYCLES
export PANTHEON_MAX_SPAWNS_PER_CYCLE
export PANTHEON_AGENT_TIMEOUT
export PANTHEON_MODEL_TIER0
export PANTHEON_MODEL_TIER1
export PANTHEON_MODEL_TIER2
export PANTHEON_MODEL_TIER3

# =============================================================================
# USAGE
# =============================================================================

usage() {
    cat << USAGE
================================================================================
                           PANTHEON SWARM (OPTIMIZED)
              Autonomous Multi-Agent Claude Code System
================================================================================

Usage: $0 <command> [options]

COMMANDS:
  run <brief>       Run swarm with project brief (file or string)
  resume [cycles]   Resume from current state (default: 5 cycles)
  aletheia          Run Aletheia interactively (for manual supervision)
  distill           Run improvement cycle from distill.md
  status            Show current swarm status
  logs              Show recent logs
  config            Show current configuration
  clean             Clean all state and start fresh

OPTIONS:
  --no-aletheia     Don't auto-launch Aletheia supervisor (for run/resume)
  --cycles N        Set max cycles (for run)
  --spawns N        Set max spawns per cycle (for run)
  --timeout N       Set agent timeout in seconds (for run)

NOTE: Aletheia auto-launches as external supervisor on 'run' and 'resume'.
      She monitors in background and can fix issues/restart cycles.
      Use --no-aletheia to disable, or 'aletheia' command for interactive mode.

OPTIONS:
  --cycles N        Maximum cycles to run (default: $PANTHEON_MAX_CYCLES)
  --spawns N        Max spawns per cycle (default: $PANTHEON_MAX_SPAWNS_PER_CYCLE)
  --timeout N       Agent timeout in seconds (default: $PANTHEON_AGENT_TIMEOUT)

EXAMPLES:
  $0 run "Build a CLI tool for managing Docker containers"
  $0 run ./project_brief.md --cycles 20
  $0 resume 3
  $0 status
  $0 config

CONFIGURATION:
  Create pantheon.conf to set defaults:
    PANTHEON_MAX_CYCLES=15
    PANTHEON_MAX_SPAWNS_PER_CYCLE=5
    PANTHEON_MODEL_TIER0=opus
    PANTHEON_MODEL_TIER1=sonnet
    PANTHEON_MODEL_TIER2=sonnet
    PANTHEON_MODEL_TIER3=haiku

THE EIGHT AGENTS:
  LUMINARY   - Vision, synthesis, direction (Tier 1 - Sonnet)
  ARCHITECT  - System design, task decomposition (Tier 2 - Sonnet)
  WEAVER     - Integration, parallel coordination (Tier 3 - Haiku)
  DJINN      - Implementation, code generation (Tier 2 - Sonnet)
  DOCTOR     - Testing, debugging, quality (Tier 0 - Opus)
  ALETHEIA   - External supervisor, verification (Tier 0 - Opus)
  SCRIBE     - Documentation, recording (Tier 3 - Haiku)
  CROCODILE  - State management, cleanup (Tier 3 - Haiku)

TEMPLECAT (Guardian Daemon):
  Templecat watches over the Pantheon continuously.
  When problems arise, Templecat invokes Aletheia (Claude/Opus) to fix them.

  Commands:
    ./pantheon.sh watch <brief>   Start Pantheon under Templecat's watch
    ./templecat.sh --monitor      Watch existing run
    ./templecat.sh --status       Check status
    ./templecat.sh --stop         Stop Templecat

OPTIMIZATIONS:
  - Model tiering: Haiku for routine work, Sonnet for complex work
  - Conditional execution: Agents skip when they have no work
  - Smart context: Each agent gets only relevant information
  - Spawn budgets: Limited spawns per cycle to control token usage

USAGE
}

# =============================================================================
# COMMANDS
# =============================================================================

launch_aletheia_supervisor() {
    # Launch Aletheia as external supervisor in background
    local state_dir="$SCRIPT_DIR/.pantheon/state"
    local logs_dir="$SCRIPT_DIR/.pantheon/logs"
    local agent_prompt="$SCRIPT_DIR/agents/aletheia.md"

    mkdir -p "$state_dir" "$logs_dir"

    # Build initial context
    local context_file="$state_dir/aletheia_supervisor_context.md"
    cat > "$context_file" << 'ALETHEIA_CTX'
# ALETHEIA SUPERVISOR - AUTO-LAUNCHED

You have been automatically launched to supervise the Pantheon.

## Your Mission
1. Monitor the pantheon's progress continuously
2. When you detect issues (compilation errors, agent timeouts), FIX THEM DIRECTLY
3. If cycles stall or complete prematurely, restart with `./pantheon.sh resume N`
4. Approve only when everything genuinely works

## Immediate Actions
1. Check compilation: `cd projects/[project] && cargo check`
2. Watch logs: `tail -f .pantheon/logs/pantheon.log`
3. Check agent health: `cat .pantheon/state/agent_health.json`

## Your Authority
- FULL tool access - read, write, execute anything
- Direct code fixes - edit files to fix compilation errors
- Cycle control - restart with context injection
- Final decision - approve or continue

START MONITORING NOW.
ALETHEIA_CTX

    echo "[ALETHEIA] Launching external supervisor..."

    # Build initial prompt from context file
    local initial_prompt=$(cat "$context_file")

    # Run in background with --print for non-interactive mode
    # Use -p to pass initial prompt instead of stdin (which doesn't work with nohup)
    nohup claude --print --model opus \
        --dangerously-skip-permissions \
        --system-prompt "$(cat "$agent_prompt")" \
        -p "$initial_prompt" \
        > "$logs_dir/aletheia_supervisor.log" 2>&1 &

    local aletheia_pid=$!
    echo "$aletheia_pid" > "$state_dir/aletheia.pid"
    echo "[ALETHEIA] Supervisor launched (PID: $aletheia_pid)"
    echo "[ALETHEIA] Log: $logs_dir/aletheia_supervisor.log"
}

run_swarm() {
    local brief="$1"
    shift

    # Parse options
    local no_aletheia=false
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --cycles)
                PANTHEON_MAX_CYCLES="$2"
                export PANTHEON_MAX_CYCLES
                shift 2
                ;;
            --spawns)
                PANTHEON_MAX_SPAWNS_PER_CYCLE="$2"
                export PANTHEON_MAX_SPAWNS_PER_CYCLE
                shift 2
                ;;
            --timeout)
                PANTHEON_AGENT_TIMEOUT="$2"
                export PANTHEON_AGENT_TIMEOUT
                shift 2
                ;;
            --no-aletheia)
                no_aletheia=true
                shift
                ;;
            *)
                shift
                ;;
        esac
    done

    # Auto-launch Aletheia as external supervisor (unless disabled)
    if [[ "$no_aletheia" != "true" ]]; then
        launch_aletheia_supervisor
    fi

    exec bash "$SCRIPT_DIR/orchestrator.sh" "$brief" "$PANTHEON_MAX_CYCLES"
}

show_status() {
    echo "==============================================="
    echo "           PANTHEON STATUS"
    echo "==============================================="
    echo ""

    local state_dir="$SCRIPT_DIR/.pantheon/state"
    local logs_dir="$SCRIPT_DIR/.pantheon/logs"

    local cycle=$(cat "$state_dir/cycle_count" 2>/dev/null || echo "Not running")
    echo "Cycle: $cycle"
    echo ""

    echo "Agent Status:"
    if [[ -f "$state_dir/agent_status.json" ]]; then
        jq -r 'to_entries[] | "  \(.key): cycles=\(.value.cycles_run // 0) skipped=\(.value.skipped // 0) \(if .value.complete == "true" then "[COMPLETE]" else "" end)"' \
            "$state_dir/agent_status.json" 2>/dev/null || echo "  No agent data"
    fi
    echo ""

    echo "Task Board:"
    if [[ -f "$state_dir/task_board.json" ]]; then
        local pending=$(jq '[.[] | select(.status == "pending")] | length' "$state_dir/task_board.json" 2>/dev/null || echo 0)
        local in_progress=$(jq '[.[] | select(.status == "in_progress")] | length' "$state_dir/task_board.json" 2>/dev/null || echo 0)
        local complete=$(jq '[.[] | select(.status == "complete")] | length' "$state_dir/task_board.json" 2>/dev/null || echo 0)
        echo "  Pending: $pending"
        echo "  In Progress: $in_progress"
        echo "  Complete: $complete"
    fi
    echo ""

    echo "Artifacts: $(jq 'length' "$state_dir/artifacts.json" 2>/dev/null || echo 0)"
    echo "Spawns: $(jq 'length' "$state_dir/spawn_registry.json" 2>/dev/null || echo 0)"
    echo ""

    # Show efficiency metrics if available
    if [[ -f "$logs_dir/model_selection.log" ]]; then
        echo "Model Usage (last 20):"
        tail -20 "$logs_dir/model_selection.log" 2>/dev/null | \
            awk -F'model=' '{print $2}' | cut -d' ' -f1 | sort | uniq -c | sort -rn
    fi
}

show_config() {
    echo "==============================================="
    echo "           PANTHEON CONFIGURATION"
    echo "==============================================="
    echo ""
    echo "Cycles:     $PANTHEON_MAX_CYCLES max"
    echo "Spawns:     $PANTHEON_MAX_SPAWNS_PER_CYCLE per cycle"
    echo "Timeout:    ${PANTHEON_AGENT_TIMEOUT}s per agent"
    echo ""
    echo "Model Tiers:"
    echo "  Tier 1 (Strategic):  $PANTHEON_MODEL_TIER1"
    echo "  Tier 2 (Technical):  $PANTHEON_MODEL_TIER2"
    echo "  Tier 3 (Routine):    $PANTHEON_MODEL_TIER3"
    echo ""
    echo "Agent Assignments:"
    echo "  Tier 1: luminary"
    echo "  Tier 2: architect, djinn, doctor"
    echo "  Tier 3: weaver, scribe, crocodile, spawns"
}

show_logs() {
    if [[ -f "$SCRIPT_DIR/.pantheon/logs/pantheon.log" ]]; then
        tail -100 "$SCRIPT_DIR/.pantheon/logs/pantheon.log"
    else
        echo "No logs found"
    fi
}

clean_state() {
    echo "Cleaning Pantheon state..."
    rm -rf "$SCRIPT_DIR/.pantheon/state/"* 2>/dev/null || true
    rm -rf "$SCRIPT_DIR/.pantheon/logs/"* 2>/dev/null || true
    rm -rf "$SCRIPT_DIR/.pantheon/spawn/"* 2>/dev/null || true
    rm -rf "$SCRIPT_DIR/.pantheon/artifacts/"* 2>/dev/null || true
    echo "Clean complete. Ready for fresh run."
}

run_distill() {
    local distill_file="$SCRIPT_DIR/distill.md"
    local state_dir="$SCRIPT_DIR/.pantheon/state"

    if [[ ! -f "$distill_file" ]]; then
        echo "Error: distill.md not found"
        exit 1
    fi

    if [[ ! -f "$state_dir/project_state.md" ]]; then
        echo "Error: No existing project state to distill"
        exit 1
    fi

    # Create distill directive
    cat > "$state_dir/distill_directive.md" << DISTILL
# DISTILL MODE - PRIORITY IMPROVEMENTS

Focus ALL effort on resolving these items:

$(cat "$distill_file")

Mark items as [RESOLVED] when fixed.
DISTILL

    exec bash "$SCRIPT_DIR/orchestrator.sh" --resume 5
}

run_resume() {
    local cycles="${1:-5}"
    local no_aletheia=false

    # Check for --no-aletheia flag
    if [[ "$2" == "--no-aletheia" ]]; then
        no_aletheia=true
    fi

    # Check .pantheon/state/ (correct location) for resume state
    if [[ ! -f "$SCRIPT_DIR/.pantheon/state/project_state.md" ]]; then
        echo "Error: No existing state to resume"
        exit 1
    fi

    # Auto-launch Aletheia as external supervisor (unless disabled)
    if [[ "$no_aletheia" != "true" ]]; then
        launch_aletheia_supervisor
    fi

    exec bash "$SCRIPT_DIR/orchestrator.sh" --resume "$cycles"
}

run_aletheia() {
    echo "==============================================="
    echo "           ALETHEIA - THE SENTINEL"
    echo "     External Supervisor + Self-Healing Mode"
    echo "==============================================="
    echo ""

    local state_dir="$SCRIPT_DIR/.pantheon/state"
    local logs_dir="$SCRIPT_DIR/.pantheon/logs"
    local agent_prompt="$SCRIPT_DIR/agents/aletheia.md"

    # Check if there's state to monitor
    if [[ ! -d "$state_dir" ]]; then
        echo "Warning: No pantheon state directory found."
        echo "Aletheia will still run but may need to wait for a cycle to start."
        mkdir -p "$state_dir" "$logs_dir"
    fi

    # Detect project
    local project_dir=$(ls -d "$SCRIPT_DIR/projects"/*/ 2>/dev/null | head -1)
    local project_name=$(basename "$project_dir" 2>/dev/null || echo "unknown")

    # Check compilation status
    local compile_status="UNKNOWN"
    local compile_errors=""
    if [[ -f "$project_dir/Cargo.toml" ]]; then
        compile_errors=$(cd "$project_dir" && cargo check 2>&1)
        if echo "$compile_errors" | grep -q "^error\[E"; then
            compile_status="FAILED"
        else
            compile_status="OK"
        fi
    fi

    # Build comprehensive context for Aletheia
    local context_file="$state_dir/aletheia_supervisor_context.md"
    cat > "$context_file" << CONTEXT
# ALETHEIA SUPERVISOR SESSION - FULL AUTONOMY

## Your Mission
You are the immune system of the Pantheon. Your job is to:
1. **Monitor** - Watch pantheon progress, check agent health
2. **Diagnose** - Identify what's blocking progress
3. **Heal** - Fix simple issues DIRECTLY (you have full tool access)
4. **Restart** - Run \`./pantheon.sh resume N\` when needed

## Current Status
- **Cycle**: $(cat "$state_dir/cycle_count" 2>/dev/null || echo "0")
- **Project**: $project_name
- **Project Directory**: $project_dir
- **Compilation**: $compile_status

$(if [[ "$compile_status" == "FAILED" ]]; then
echo "## COMPILATION ERRORS (FIX THESE FIRST)"
echo "\`\`\`"
echo "$compile_errors" | grep -E "^error|Error:" | head -10
echo "\`\`\`"
echo ""
echo "**YOU CAN FIX THESE DIRECTLY** - edit the files, add missing derives, etc."
fi)

## Key Paths
- Working Directory: $SCRIPT_DIR
- State Directory: $state_dir
- Logs Directory: $logs_dir
- Project Directory: $project_dir

## Files to Monitor
- \`$state_dir/cycle_count\` - Current cycle
- \`$state_dir/agent_health.json\` - Agent health metrics
- \`$state_dir/task_board.json\` - Task progress
- \`$logs_dir/pantheon.log\` - Main log
- \`$logs_dir/token_usage.log\` - Token efficiency

## Commands Available
\`\`\`bash
# Resume pantheon
./pantheon.sh resume 5

# Check compilation
cd $project_dir && cargo check

# Run tests
cd $project_dir && cargo test

# Check agent health
cat $state_dir/agent_health.json

# Check logs
tail -50 $logs_dir/pantheon.log
\`\`\`

## Your Authority
- **FULL TOOL ACCESS** - Read, write, execute anything
- **DIRECT CODE FIXES** - Edit files to fix compilation errors
- **CYCLE CONTROL** - Restart cycles with context injection
- **FINAL DECISION** - Approve or continue cycles

## START NOW
1. Check current compilation status
2. If errors exist, FIX THEM DIRECTLY
3. Check agent health for issues
4. Monitor pantheon progress
5. Make decisions: fix, restart, or approve
CONTEXT

    echo "Context built. Launching Aletheia..."
    echo ""
    echo "Project: $project_name"
    echo "Compilation: $compile_status"
    echo ""

    # Build initial prompt from context
    local initial_prompt=$(cat "$context_file")

    # Run Aletheia as a full Claude Code session with bypass permissions
    # Use --print for non-interactive/background mode, -p for initial prompt
    exec claude --print --model opus \
        --dangerously-skip-permissions \
        --system-prompt "$(cat "$agent_prompt")" \
        -p "$initial_prompt"
        < "$context_file"
}

# =============================================================================
# MAIN
# =============================================================================

case "${1:-}" in
    run)
        shift
        if [[ -z "$1" ]]; then
            echo "Error: Project brief required"
            usage
            exit 1
        fi
        run_swarm "$@"
        ;;
    watch)
        # Run with Templecat supervision
        shift
        if [[ -z "$1" ]]; then
            echo "Error: Project brief required"
            usage
            exit 1
        fi
        echo "Starting Pantheon with Templecat supervision..."
        exec "$SCRIPT_DIR/templecat.sh" "$@"
        ;;
    resume)
        shift
        run_resume "$@"
        ;;
    aletheia)
        # Show Templecat status or start monitor mode
        if [[ -f "$SCRIPT_DIR/.pantheon/templecat.pid" ]]; then
            "$SCRIPT_DIR/templecat.sh" --status
        else
            echo "Starting Templecat (which invokes Aletheia when needed)..."
            exec "$SCRIPT_DIR/templecat.sh" --monitor
        fi
        ;;
    distill)
        run_distill
        ;;
    status)
        show_status
        ;;
    config)
        show_config
        ;;
    logs)
        show_logs
        ;;
    clean)
        clean_state
        ;;
    -h|--help|help|"")
        usage
        ;;
    *)
        echo "Unknown command: $1"
        usage
        exit 1
        ;;
esac
