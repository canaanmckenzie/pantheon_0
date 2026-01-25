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
  distill           Run focused improvement cycle from distill.md
  resume [cycles]   Resume from current state (default: 5 cycles)
  status            Show current swarm status
  logs              Show recent logs
  clean             Clean all state and start fresh

Options:
  --cycles N        Maximum cycles to run (default: 10)
  --verbose         Enable verbose output

Examples:
  $0 run "Build a REST API for user management"
  $0 run ./project_brief.md --cycles 20
  $0 distill                    # Run improvement cycle from distill.md
  $0 resume 3                   # Resume with 3 more cycles
  $0 interactive
  $0 status
  $0 clean

The Seven Agents:
   CROCODILE  - State management, garbage collection, the great database
   SCRIBE     - Documentation, decision recording
    ARCHITECT  - System design, task decomposition
    WEAVER     - Integration, parallel coordination (spawns subagents)
   DOCTOR     - Testing, debugging, quality
   LUMINARY   - Vision, synthesis, direction
   DJINN      - Implementation, code generation (spawns subagents)

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

run_distill() {
    local distill_file="$SCRIPT_DIR/distill.md"

    # Check if distill.md exists
    if [[ ! -f "$distill_file" ]]; then
        echo "Error: distill.md not found at $distill_file"
        echo "Create distill.md with improvement items (one per numbered line)"
        exit 1
    fi

    # Check if there's existing state to resume from
    if [[ ! -f "$SCRIPT_DIR/state/project_state.md" ]]; then
        echo "Error: No existing project state to distill"
        echo "Run a project first with: $0 run <brief>"
        exit 1
    fi

    # Count issues in distill.md (lines starting with number or dash)
    local issue_count=$(grep -cE '^\s*[0-9]+\.|^\s*-' "$distill_file" 2>/dev/null || echo "1")

    # Calculate cycles: min(issue_count * 2, 5)
    local cycles=$((issue_count * 2))
    if [[ $cycles -gt 5 ]]; then
        cycles=5
    fi
    if [[ $cycles -lt 1 ]]; then
        cycles=1
    fi

    echo "╔═══════════════════════════════════════╗"
    echo "║         PANTHEON DISTILL              ║"
    echo "╚═══════════════════════════════════════╝"
    echo ""
    echo "Distill file: $distill_file"
    echo "Issues found: $issue_count"
    echo "Cycles planned: $cycles"
    echo ""
    echo "Issues to address:"
    grep -E '^\s*[0-9]+\.|^\s*-' "$distill_file" | head -10
    echo ""

    # Inject distill.md content as priority directive for Luminary
    local distill_content=$(cat "$distill_file")

    # Create a distill directive file that will be picked up by context builder
    cat > "$SCRIPT_DIR/state/distill_directive.md" << DISTILL
# DISTILL MODE - PRIORITY IMPROVEMENTS

The following issues have been identified for immediate attention.
Focus ALL agent effort on resolving these items this cycle.

---

$distill_content

---

## Instructions for Agents

- LUMINARY: Prioritize these issues above all else. Direct other agents to fix them.
- ARCHITECT: Review if any architectural changes are needed for these fixes.
- WEAVER: Coordinate fixes, spawn specialists if needed for parallel work.
- DJINN: Implement the actual code fixes.
- DOCTOR: Verify fixes work, write tests if needed.
- SCRIBE: Document any changes made.
- CROCODILE: Track which distill items are resolved.

Mark items as [RESOLVED] in your output when fixed.
DISTILL

    # Verify directive was created
    if [[ ! -f "$SCRIPT_DIR/state/distill_directive.md" ]]; then
        echo "Error: Failed to create distill directive"
        exit 1
    fi

    # Reset agent completion status so they run full cycles
    if [[ -f "$SCRIPT_DIR/state/agent_status.json" ]]; then
        echo "Resetting agent completion status..."
        # Set all agents to complete: false
        jq 'to_entries | map(.value.complete = "false") | from_entries' \
            "$SCRIPT_DIR/state/agent_status.json" > "$SCRIPT_DIR/state/agent_status.tmp" && \
            mv "$SCRIPT_DIR/state/agent_status.tmp" "$SCRIPT_DIR/state/agent_status.json"
    fi

    echo "Starting distill cycle..."
    echo ""

    # Run orchestrator in resume mode with calculated cycles
    exec bash "$SCRIPT_DIR/orchestrator.sh" --resume "$cycles"
}

run_resume() {
    local cycles="${1:-5}"

    if [[ ! -f "$SCRIPT_DIR/state/project_state.md" ]]; then
        echo "Error: No existing project state to resume"
        echo "Run a project first with: $0 run <brief>"
        exit 1
    fi

    echo "Resuming Pantheon with $cycles cycles..."
    exec bash "$SCRIPT_DIR/orchestrator.sh" --resume "$cycles"
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
    distill)
        run_distill
        ;;
    resume)
        shift
        run_resume "$1"
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
