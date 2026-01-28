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
  distill           Run improvement cycle from distill.md
  status            Show current swarm status
  logs              Show recent logs
  config            Show current configuration
  clean             Clean all state and start fresh

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

THE SEVEN AGENTS:
  LUMINARY   - Vision, synthesis, direction (Tier 1 - Sonnet)
  ARCHITECT  - System design, task decomposition (Tier 2 - Sonnet)
  WEAVER     - Integration, parallel coordination (Tier 3 - Haiku)
  DJINN      - Implementation, code generation (Tier 2 - Sonnet)
  DOCTOR     - Testing, debugging, quality (Tier 0 - Opus)
  SCRIBE     - Documentation, recording (Tier 3 - Haiku)
  CROCODILE  - State management, cleanup (Tier 3 - Haiku)

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

run_swarm() {
    local brief="$1"
    shift
    
    # Parse options
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
            *)
                shift
                ;;
        esac
    done
    
    exec bash "$SCRIPT_DIR/orchestrator.sh" "$brief" "$PANTHEON_MAX_CYCLES"
}

show_status() {
    echo "==============================================="
    echo "           PANTHEON STATUS"
    echo "==============================================="
    echo ""
    
    local cycle=$(cat "$SCRIPT_DIR/state/cycle_count" 2>/dev/null || echo "Not running")
    echo "Cycle: $cycle"
    echo ""
    
    echo "Agent Status:"
    if [[ -f "$SCRIPT_DIR/state/agent_status.json" ]]; then
        jq -r 'to_entries[] | "  \(.key): cycles=\(.value.cycles_run // 0) skipped=\(.value.skipped // 0) \(if .value.complete == "true" then "[COMPLETE]" else "" end)"' \
            "$SCRIPT_DIR/state/agent_status.json" 2>/dev/null || echo "  No agent data"
    fi
    echo ""
    
    echo "Task Board:"
    if [[ -f "$SCRIPT_DIR/state/task_board.json" ]]; then
        local pending=$(jq '[.[] | select(.status == "pending")] | length' "$SCRIPT_DIR/state/task_board.json" 2>/dev/null || echo 0)
        local in_progress=$(jq '[.[] | select(.status == "in_progress")] | length' "$SCRIPT_DIR/state/task_board.json" 2>/dev/null || echo 0)
        local complete=$(jq '[.[] | select(.status == "complete")] | length' "$SCRIPT_DIR/state/task_board.json" 2>/dev/null || echo 0)
        echo "  Pending: $pending"
        echo "  In Progress: $in_progress"
        echo "  Complete: $complete"
    fi
    echo ""
    
    echo "Artifacts: $(jq 'length' "$SCRIPT_DIR/state/artifacts.json" 2>/dev/null || echo 0)"
    echo "Spawns: $(jq 'length' "$SCRIPT_DIR/state/spawn_registry.json" 2>/dev/null || echo 0)"
    echo ""
    
    # Show efficiency metrics if available
    if [[ -f "$SCRIPT_DIR/logs/model_selection.log" ]]; then
        echo "Model Usage (last 20):"
        tail -20 "$SCRIPT_DIR/logs/model_selection.log" 2>/dev/null | \
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
    if [[ -f "$SCRIPT_DIR/logs/pantheon.log" ]]; then
        tail -100 "$SCRIPT_DIR/logs/pantheon.log"
    else
        echo "No logs found"
    fi
}

clean_state() {
    echo "Cleaning Pantheon state..."
    rm -rf "$SCRIPT_DIR/state/"* 2>/dev/null || true
    rm -rf "$SCRIPT_DIR/logs/"* 2>/dev/null || true
    rm -rf "$SCRIPT_DIR/tasks/"* 2>/dev/null || true
    rm -rf "$SCRIPT_DIR/spawn/"* 2>/dev/null || true
    rm -rf "$SCRIPT_DIR/output/"* 2>/dev/null || true
    echo "Clean complete. Ready for fresh run."
}

run_distill() {
    local distill_file="$SCRIPT_DIR/distill.md"
    
    if [[ ! -f "$distill_file" ]]; then
        echo "Error: distill.md not found"
        exit 1
    fi
    
    if [[ ! -f "$SCRIPT_DIR/state/project_state.md" ]]; then
        echo "Error: No existing project state to distill"
        exit 1
    fi
    
    # Create distill directive
    cat > "$SCRIPT_DIR/state/distill_directive.md" << DISTILL
# DISTILL MODE - PRIORITY IMPROVEMENTS

Focus ALL effort on resolving these items:

$(cat "$distill_file")

Mark items as [RESOLVED] when fixed.
DISTILL
    
    exec bash "$SCRIPT_DIR/orchestrator.sh" --resume 5
}

run_resume() {
    local cycles="${1:-5}"
    
    if [[ ! -f "$SCRIPT_DIR/state/project_state.md" ]]; then
        echo "Error: No existing state to resume"
        exit 1
    fi
    
    exec bash "$SCRIPT_DIR/orchestrator.sh" --resume "$cycles"
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
    resume)
        shift
        run_resume "$1"
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
