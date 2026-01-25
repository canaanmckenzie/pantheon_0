#!/bin/bash
#
# PANTHEON ORCHESTRATOR
# Autonomous Multi-Agent Claude Code Swarm
# 
# The Seven: Crocodile, Scribe, Architect, Weaver, Doctor, Luminary, Djinn
#

set -e

PANTHEON_ROOT="$(cd "$(dirname "$0")" && pwd)"
export PANTHEON_ROOT

# Source core libraries
source "$PANTHEON_ROOT/lib/colors.sh"
source "$PANTHEON_ROOT/lib/logging.sh"
source "$PANTHEON_ROOT/lib/state.sh"
source "$PANTHEON_ROOT/lib/messaging.sh"
source "$PANTHEON_ROOT/lib/spawner.sh"

# ============================================================================
# INITIALIZATION
# ============================================================================

init_pantheon() {
    log_header "PANTHEON SWARM INITIALIZING"

    # Create all required directories
    mkdir -p "$PANTHEON_ROOT/state"
    mkdir -p "$PANTHEON_ROOT/state/checkpoints"
    mkdir -p "$PANTHEON_ROOT/logs"
    mkdir -p "$PANTHEON_ROOT/tasks"
    mkdir -p "$PANTHEON_ROOT/spawn"
    mkdir -p "$PANTHEON_ROOT/spawn/archive"
    mkdir -p "$PANTHEON_ROOT/output"

    # Initialize state (Crocodile's domain)
    init_state_db

    # Clear previous run artifacts
    rm -f "$PANTHEON_ROOT/tasks/"*.task 2>/dev/null || true
    rm -f "$PANTHEON_ROOT/logs/"*.log 2>/dev/null || true
    rm -f "$PANTHEON_ROOT/state/"*.lock 2>/dev/null || true
    
    # Initialize task board and all state files
    echo "[]" > "$PANTHEON_ROOT/state/task_board.json"
    echo "[]" > "$PANTHEON_ROOT/state/message_queue.json"
    echo "{}" > "$PANTHEON_ROOT/state/agent_status.json"
    echo "[]" > "$PANTHEON_ROOT/state/artifacts.json"
    echo "[]" > "$PANTHEON_ROOT/state/spawn_queue.json"
    echo "[]" > "$PANTHEON_ROOT/state/spawn_registry.json"
    echo "{}" > "$PANTHEON_ROOT/state/memory.json"
    echo "[]" > "$PANTHEON_ROOT/state/decisions.json"
    echo "0" > "$PANTHEON_ROOT/state/cycle_count"
    
    # Register all agents
    for agent in crocodile scribe architect weaver doctor luminary djinn; do
        register_agent "$agent"
    done
    
    log_success "Pantheon initialized"
}

# ============================================================================
# MAIN EXECUTION CYCLE
# ============================================================================

run_cycle() {
    local cycle=$1
    local max_cycles=$2
    
    log_header "CYCLE $cycle/$max_cycles"
    
    # Phase 1: LUMINARY - Vision and synthesis
    run_agent "luminary" "Assess current state, synthesize direction, identify blockers"
    
    # Phase 2: ARCHITECT - Structure and planning  
    run_agent "architect" "Review structure, decompose tasks, ensure coherence"
    
    # Phase 3: WEAVER - Integration and spawning
    run_agent "weaver" "Integrate components, spawn workers for parallel tasks"
    
    # Phase 4: DJINN - Implementation and spawning
    run_agent "djinn" "Implement solutions, spawn specialists as needed"
    
    # Phase 5: DOCTOR - Testing and diagnostics
    run_agent "doctor" "Test implementations, diagnose issues, prescribe fixes"
    
    # Phase 6: SCRIBE - Documentation and recording
    run_agent "scribe" "Document changes, record decisions, update manifests"
    
    # Phase 7: CROCODILE - Compaction and state management (ALWAYS LAST)
    run_agent "crocodile" "Compact state, garbage collect, persist critical data"
    
    # Process any spawned subagents
    process_spawn_queue
    
    # Check completion
    if check_completion; then
        log_success "PROJECT COMPLETE"
        return 0
    fi
    
    return 1
}

run_agent() {
    local agent_name=$1
    local directive=$2
    
    log_agent "$agent_name" "ACTIVATING"
    
    # Build context for agent
    local context_file="$PANTHEON_ROOT/state/context_${agent_name}.md"
    build_agent_context "$agent_name" "$directive" > "$context_file"
    
    # Execute agent via Claude Code
    local response_file="$PANTHEON_ROOT/state/response_${agent_name}.md"
    
    # The actual Claude Code invocation
    # --dangerously-skip-permissions enables fully autonomous operation
    # Use timeout to prevent hangs, and optionally a faster model via PANTHEON_MODEL env var
    local model_flag=""
    if [[ -n "${PANTHEON_MODEL:-}" ]]; then
        model_flag="--model $PANTHEON_MODEL"
    fi

    timeout "${PANTHEON_TIMEOUT:-300}" claude --dangerously-skip-permissions --print $model_flag \
        --system-prompt "$(cat "$PANTHEON_ROOT/agents/${agent_name}.md")" \
        < "$context_file" > "$response_file" 2>/dev/null || true
    
    # Process agent response
    process_agent_response "$agent_name" "$response_file"
    
    # Log completion
    log_agent "$agent_name" "COMPLETE"
}
build_agent_context() {
    local agent_name=$1
    local directive=$2

    cat << CONTEXT
# OPERATING MODE: FULLY AUTONOMOUS

You have full tool access. Use Read, Write, Bash, Grep, Glob, Task - whatever you need.
Execute real commands. Create real files. Make real changes.

When you need to communicate with other agents or signal state changes, ALSO emit markers:
- [TASK]description[/TASK] - register a task on the board
- [MSG:agent_name]content[/MSG] - async message to another agent
- [SPAWN]specialization:task[/SPAWN] - request subagent (Weaver/Djinn only)
- [ARTIFACT:path]description[/ARTIFACT] - register an artifact you created
- [COMPLETE] - signal your phase is done

These markers are for orchestration. They don't replace actual work - do the work FIRST, then emit markers to record what you did.

# DIRECTIVE
$directive

# PROJECT ROOT
$PANTHEON_ROOT

# WORKING DIRECTORIES
- Source: $PANTHEON_ROOT/../src (or as defined in project brief)
- Output: $PANTHEON_ROOT/output
- State: $PANTHEON_ROOT/state

# CURRENT STATE
$(cat "$PANTHEON_ROOT/state/project_state.md" 2>/dev/null || echo "No project state yet.")

# TASK BOARD
$(cat "$PANTHEON_ROOT/state/task_board.json")

# MESSAGES FOR YOU
$(get_messages_for "$agent_name")

# ARTIFACTS REGISTRY
$(cat "$PANTHEON_ROOT/state/artifacts.json")

# YOUR PREVIOUS OUTPUT (for continuity)
$(tail -100 "$PANTHEON_ROOT/state/response_${agent_name}.md" 2>/dev/null || echo "First cycle.")

CONTEXT
}

process_agent_response() {
    local agent_name=$1
    local response_file=$2
    
    # Extract structured outputs from response
    # Agents output in a specific format with markers
    
    if [[ -f "$response_file" ]]; then
        # Extract tasks
        grep -oP '(?<=\[TASK\]).*(?=\[/TASK\])' "$response_file" 2>/dev/null | while read task; do
            add_task "$task" "$agent_name"
        done
        
        # Extract messages
        grep -oP '(?<=\[MSG:)[^]]+(?=\]).*(?=\[/MSG\])' "$response_file" 2>/dev/null | while read msg; do
            local target=$(echo "$msg" | cut -d']' -f1)
            local content=$(echo "$msg" | cut -d']' -f2-)
            send_message "$agent_name" "$target" "$content"
        done
        
        # Extract spawn requests (only weaver and djinn)
        if [[ "$agent_name" == "weaver" || "$agent_name" == "djinn" ]]; then
            grep -oP '(?<=\[SPAWN\]).*(?=\[/SPAWN\])' "$response_file" 2>/dev/null | while read spawn; do
                queue_spawn "$agent_name" "$spawn"
            done
        fi
        
        # Extract artifacts
        grep -oP '(?<=\[ARTIFACT:)[^]]+(?=\])' "$response_file" 2>/dev/null | while read artifact; do
            register_artifact "$artifact" "$agent_name"
        done
        
        # Extract completion signals
        if grep -q '\[COMPLETE\]' "$response_file" 2>/dev/null; then
            mark_agent_complete "$agent_name"
        fi
    fi
}

process_spawn_queue() {
    local spawn_queue="$PANTHEON_ROOT/state/spawn_queue.json"
    
    if [[ -f "$spawn_queue" ]] && [[ "$(cat "$spawn_queue")" != "[]" ]]; then
        log_info "Processing spawn queue..."
        
        # Process each spawn request
        jq -r '.[] | @base64' "$spawn_queue" 2>/dev/null | while read spawn_b64; do
            local spawn_data=$(echo "$spawn_b64" | base64 -d)
            local parent=$(echo "$spawn_data" | jq -r '.parent')
            local task=$(echo "$spawn_data" | jq -r '.task')
            local specialization=$(echo "$spawn_data" | jq -r '.specialization')
            
            spawn_subagent "$parent" "$task" "$specialization"
        done
        
        # Clear queue
        echo "[]" > "$spawn_queue"
    fi
}

check_completion() {
    # Check if all critical tasks are done
    local pending=$(jq '[.[] | select(.status == "pending" or .status == "in_progress")] | length' \
        "$PANTHEON_ROOT/state/task_board.json" 2>/dev/null || echo "999")
    
    if [[ "$pending" == "0" ]]; then
        # Verify with Luminary
        local luminary_complete=$(jq -r '.luminary.complete // false' \
            "$PANTHEON_ROOT/state/agent_status.json" 2>/dev/null)
        
        [[ "$luminary_complete" == "true" ]]
    else
        return 1
    fi
}

# ============================================================================
# MAIN ENTRY POINT
# ============================================================================

main() {
    local project_brief="$1"
    local max_cycles="${2:-10}"
    
    if [[ -z "$project_brief" ]]; then
        echo "Usage: $0 <project_brief_file> [max_cycles]"
        echo "       $0 --interactive"
        exit 1
    fi
    
    # Initialize
    init_pantheon
    
    # Load project brief
    if [[ "$project_brief" == "--interactive" ]]; then
        echo "Enter project brief (Ctrl+D when done):"
        project_brief=$(cat)
        echo "$project_brief" > "$PANTHEON_ROOT/state/project_brief.md"
    elif [[ -f "$project_brief" ]]; then
        cp "$project_brief" "$PANTHEON_ROOT/state/project_brief.md"
    else
        echo "$project_brief" > "$PANTHEON_ROOT/state/project_brief.md"
    fi
    
    # Initialize project state
    cat > "$PANTHEON_ROOT/state/project_state.md" << STATE
# PROJECT STATE

## Brief
$(cat "$PANTHEON_ROOT/state/project_brief.md")

## Status
INITIALIZING

## Phase
0 - INCEPTION

## Critical Path
- [ ] Requirements analysis
- [ ] Architecture design
- [ ] Implementation
- [ ] Testing
- [ ] Documentation
- [ ] Delivery
STATE

    # Main execution loop
    for ((cycle=1; cycle<=max_cycles; cycle++)); do
        echo "$cycle" > "$PANTHEON_ROOT/state/cycle_count"
        
        if run_cycle "$cycle" "$max_cycles"; then
            break
        fi
        
        # Brief pause between cycles
        sleep 1
    done
    
    # Final synthesis
    log_header "FINAL SYNTHESIS"
    run_agent "luminary" "Produce final synthesis and deliverables manifest"
    run_agent "scribe" "Produce final documentation package"
    run_agent "crocodile" "Final state compaction and archive"
    
    log_success "PANTHEON COMPLETE"
    
    # Output deliverables location
    echo ""
    echo "Deliverables: $PANTHEON_ROOT/output/"
    echo "Logs: $PANTHEON_ROOT/logs/"
    echo "Final State: $PANTHEON_ROOT/state/"
}

# Run if executed directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
