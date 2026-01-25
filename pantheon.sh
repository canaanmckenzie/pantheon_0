#!/bin/bash
#
# PANTHEON LAUNCHER
# Simple entry point to run the agent swarm
#

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

usage() {
    cat << USAGE
╔═══════════════════════════════════════════════════════════════════════╗
║                         PANTHEON SWARM                                 ║
║           Autonomous Multi-Agent Claude Code System                    ║
╚═══════════════════════════════════════════════════════════════════════╝

Usage: $0 <command> [options]

Commands:
  run <brief>       Run the swarm with a project brief (file or string)
  interactive       Run in interactive mode (enter brief via stdin)
  status            Show current swarm status
  logs              Show recent logs
  clean             Clean all state and start fresh
  
Options:
  --cycles N        Maximum cycles to run (default: 10)
  --verbose         Enable verbose output
  
Examples:
  $0 run "Build a REST API for user management"
  $0 run ./project_brief.md --cycles 20
  $0 interactive
  $0 status
  $0 clean

The Seven Agents:
  🐊 CROCODILE  - State management, garbage collection, the great database
  📜 SCRIBE     - Documentation, decision recording
  🏛️  ARCHITECT  - System design, task decomposition
  🕸️  WEAVER     - Integration, parallel coordination (spawns subagents)
  🏥 DOCTOR     - Testing, debugging, quality
  💡 LUMINARY   - Vision, synthesis, direction
  🧞 DJINN      - Implementation, code generation (spawns subagents)

USAGE
}

run_swarm() {
    local brief="$1"
    shift
    
    # Parse additional options
    local cycles=10
    local verbose=false
    
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --cycles)
                cycles="$2"
                shift 2
                ;;
            --verbose)
                verbose=true
                shift
                ;;
            *)
                shift
                ;;
        esac
    done
    
    if [[ "$verbose" == "true" ]]; then
        export PANTHEON_VERBOSE=1
    fi
    
    exec bash "$SCRIPT_DIR/orchestrator.sh" "$brief" "$cycles"
}

show_status() {
    echo "╔═══════════════════════════════════════╗"
    echo "║         PANTHEON STATUS               ║"
    echo "╚═══════════════════════════════════════╝"
    echo ""
    
    if [[ -f "$SCRIPT_DIR/state/cycle_count" ]]; then
        echo "Cycle: $(cat "$SCRIPT_DIR/state/cycle_count")"
    else
        echo "Cycle: Not running"
    fi
    
    echo ""
    echo "Agent Status:"
    if [[ -f "$SCRIPT_DIR/state/agent_status.json" ]]; then
        jq -r 'to_entries[] | "  \(.key): \(if .value.complete then "COMPLETE" else "ACTIVE" end)"' \
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
}

show_logs() {
    if [[ -f "$SCRIPT_DIR/logs/pantheon.log" ]]; then
        tail -50 "$SCRIPT_DIR/logs/pantheon.log"
    else
        echo "No logs found"
    fi
}

clean_state() {
    echo "Cleaning Pantheon state..."
    rm -rf "$SCRIPT_DIR/state/"*
    rm -rf "$SCRIPT_DIR/logs/"*
    rm -rf "$SCRIPT_DIR/tasks/"*
    rm -rf "$SCRIPT_DIR/spawn/"*
    rm -rf "$SCRIPT_DIR/output/"*
    echo "Clean complete. Ready for fresh run."
}

# Main
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
    interactive)
        run_swarm "--interactive"
        ;;
    status)
        show_status
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
