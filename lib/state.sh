#!/bin/bash
# =============================================================================
# STATE MANAGEMENT LIBRARY
# =============================================================================
#
# Core state management for Pantheon. Handles task board, artifacts,
# memory, and checkpointing.
#
# OPTIMIZATIONS FROM ORIGINAL:
# - Added summarization functions for context building
# - Improved checkpoint compression
# - Better garbage collection
#
# =============================================================================

PANTHEON_ROOT="${PANTHEON_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
# Use .pantheon/ structure (fallback if not set)
PANTHEON_STATE_DIR="${PANTHEON_STATE_DIR:-$PANTHEON_ROOT/.pantheon/state}"
PANTHEON_LOGS_DIR="${PANTHEON_LOGS_DIR:-$PANTHEON_ROOT/.pantheon/logs}"
PANTHEON_SPAWN_DIR="${PANTHEON_SPAWN_DIR:-$PANTHEON_ROOT/.pantheon/spawn}"
PANTHEON_ARTIFACTS_DIR="${PANTHEON_ARTIFACTS_DIR:-$PANTHEON_ROOT/.pantheon/artifacts}"
PANTHEON_PROJECTS_DIR="${PANTHEON_PROJECTS_DIR:-$PANTHEON_ROOT/projects}"

# Use the .pantheon/ state directory
STATE_DIR="$PANTHEON_STATE_DIR"

# =============================================================================
# INITIALIZATION
# =============================================================================

init_state_db() {
    mkdir -p "$STATE_DIR"
    mkdir -p "$STATE_DIR/checkpoints"
    mkdir -p "$STATE_DIR/archive"
    
    # Initialize JSON state files (only if they don't exist)
    [[ -f "$STATE_DIR/task_board.json" ]] || echo "[]" > "$STATE_DIR/task_board.json"
    [[ -f "$STATE_DIR/message_queue.json" ]] || echo "[]" > "$STATE_DIR/message_queue.json"
    [[ -f "$STATE_DIR/agent_status.json" ]] || echo "{}" > "$STATE_DIR/agent_status.json"
    [[ -f "$STATE_DIR/artifacts.json" ]] || echo "[]" > "$STATE_DIR/artifacts.json"
    [[ -f "$STATE_DIR/spawn_queue.json" ]] || echo "[]" > "$STATE_DIR/spawn_queue.json"
    [[ -f "$STATE_DIR/spawn_registry.json" ]] || echo "[]" > "$STATE_DIR/spawn_registry.json"
    [[ -f "$STATE_DIR/memory.json" ]] || echo "{}" > "$STATE_DIR/memory.json"
    [[ -f "$STATE_DIR/decisions.json" ]] || echo "[]" > "$STATE_DIR/decisions.json"
    [[ -f "$STATE_DIR/cycle_count" ]] || echo "0" > "$STATE_DIR/cycle_count"
}

# =============================================================================
# AGENT REGISTRATION
# =============================================================================

register_agent() {
    local agent_name=$1
    local status_file="$STATE_DIR/agent_status.json"
    
    local updated=$(jq --arg name "$agent_name" \
        '.[$name] = {"registered": true, "complete": false, "cycles_run": 0, "last_active": null, "skipped": 0}' \
        "$status_file")
    echo "$updated" > "$status_file"
}

update_agent_status() {
    local agent_name=$1
    local key=$2
    local value=$3
    local status_file="$STATE_DIR/agent_status.json"
    
    local updated=$(jq --arg name "$agent_name" --arg key "$key" --arg val "$value" \
        '.[$name][$key] = $val' "$status_file")
    echo "$updated" > "$status_file"
}

mark_agent_complete() {
    local agent_name=$1
    update_agent_status "$agent_name" "complete" "true"
}

mark_agent_skipped() {
    local agent_name=$1
    local status_file="$STATE_DIR/agent_status.json"
    
    local updated=$(jq --arg name "$agent_name" \
        '.[$name].skipped = ((.[$name].skipped // 0) + 1)' "$status_file")
    echo "$updated" > "$status_file"
}

increment_agent_cycles() {
    local agent_name=$1
    local status_file="$STATE_DIR/agent_status.json"
    
    local updated=$(jq --arg name "$agent_name" --arg time "$(date -Iseconds)" \
        '.[$name].cycles_run = ((.[$name].cycles_run // 0) + 1) | .[$name].last_active = $time' \
        "$status_file")
    echo "$updated" > "$status_file"
}

get_agent_status() {
    local agent_name=$1
    jq -r --arg name "$agent_name" '.[$name] // {}' "$STATE_DIR/agent_status.json"
}

# =============================================================================
# CYCLE STATE TRACKING (for mid-cycle resume)
# =============================================================================

set_current_agent() {
    local agent_name=$1
    local cycle=$2
    local start_time=$(date +%s)

    cat > "$STATE_DIR/current_agent.json" << EOF
{
    "agent": "$agent_name",
    "cycle": $cycle,
    "started": $start_time,
    "started_iso": "$(date -Iseconds)"
}
EOF
}

clear_current_agent() {
    rm -f "$STATE_DIR/current_agent.json"
}

get_current_agent() {
    if [[ -f "$STATE_DIR/current_agent.json" ]]; then
        jq -r '.agent' "$STATE_DIR/current_agent.json"
    else
        echo ""
    fi
}

get_cycle_resume_point() {
    # Returns the agent to resume from (empty string if none)
    if [[ -f "$STATE_DIR/current_agent.json" ]]; then
        local agent=$(jq -r '.agent' "$STATE_DIR/current_agent.json")
        local started=$(jq -r '.started' "$STATE_DIR/current_agent.json")
        local now=$(date +%s)
        local elapsed=$((now - started))

        # If agent was running for > 30 seconds, it probably got interrupted
        if [[ $elapsed -gt 30 ]]; then
            echo "$agent"
        fi
    fi
    echo ""
}

mark_agent_in_cycle_complete() {
    local agent_name=$1
    local cycle_file="$STATE_DIR/cycle_progress.json"
    local cycle=$(cat "$STATE_DIR/cycle_count" 2>/dev/null || echo 0)

    # Initialize if doesn't exist
    if [[ ! -f "$cycle_file" ]]; then
        echo '{}' > "$cycle_file"
    fi

    # Mark agent as complete for this cycle
    local updated=$(jq --arg cycle "$cycle" --arg agent "$agent_name" \
        '.[$cycle] = ((.[$cycle] // []) + [$agent] | unique)' "$cycle_file")
    echo "$updated" > "$cycle_file"
}

get_completed_agents_this_cycle() {
    local cycle=$(cat "$STATE_DIR/cycle_count" 2>/dev/null || echo 0)
    local cycle_file="$STATE_DIR/cycle_progress.json"

    if [[ -f "$cycle_file" ]]; then
        jq -r --arg cycle "$cycle" '.[$cycle] // [] | .[]' "$cycle_file" 2>/dev/null
    fi
}

should_skip_agent_in_resume() {
    local agent_name=$1
    local completed=$(get_completed_agents_this_cycle)

    if echo "$completed" | grep -q "^${agent_name}$"; then
        return 0  # true, skip
    fi
    return 1  # false, don't skip
}

reset_cycle_progress() {
    local cycle=$(cat "$STATE_DIR/cycle_count" 2>/dev/null || echo 0)
    local cycle_file="$STATE_DIR/cycle_progress.json"

    if [[ -f "$cycle_file" ]]; then
        local updated=$(jq --arg cycle "$cycle" 'del(.[$cycle])' "$cycle_file")
        echo "$updated" > "$cycle_file"
    fi
}

# =============================================================================
# TASK MANAGEMENT
# =============================================================================

add_task() {
    local task_description=$1
    local creator=$2
    local priority=${3:-"normal"}
    local task_type=${4:-"general"}
    local task_file="$STATE_DIR/task_board.json"
    
    local task_id="task_$(date +%s%N | md5sum | head -c 8)"
    
    local updated=$(jq --arg id "$task_id" \
        --arg desc "$task_description" \
        --arg creator "$creator" \
        --arg priority "$priority" \
        --arg type "$task_type" \
        --arg created "$(date -Iseconds)" \
        '. += [{
            "id": $id,
            "description": $desc,
            "creator": $creator,
            "priority": $priority,
            "type": $type,
            "status": "pending",
            "created": $created,
            "assigned_to": null,
            "completed": null
        }]' "$task_file")
    echo "$updated" > "$task_file"
    
    echo "$task_id"
}

claim_task() {
    local task_id=$1
    local agent_name=$2
    local task_file="$STATE_DIR/task_board.json"
    
    local updated=$(jq --arg id "$task_id" --arg agent "$agent_name" --arg time "$(date -Iseconds)" \
        'map(if .id == $id then .status = "in_progress" | .assigned_to = $agent | .started = $time else . end)' \
        "$task_file")
    echo "$updated" > "$task_file"
}

complete_task() {
    local task_id=$1
    local task_file="$STATE_DIR/task_board.json"
    
    local updated=$(jq --arg id "$task_id" --arg completed "$(date -Iseconds)" \
        'map(if .id == $id then .status = "complete" | .completed = $completed else . end)' \
        "$task_file")
    echo "$updated" > "$task_file"
}

get_pending_tasks() {
    jq '[.[] | select(.status == "pending")]' "$STATE_DIR/task_board.json"
}

get_tasks_for_agent() {
    local agent_name=$1
    jq --arg agent "$agent_name" '[.[] | select(.assigned_to == $agent)]' "$STATE_DIR/task_board.json"
}

# =============================================================================
# ARTIFACT MANAGEMENT
# =============================================================================

register_artifact() {
    local artifact_path=$1
    local creator=$2
    local artifact_type=${3:-"file"}
    local artifact_file="$STATE_DIR/artifacts.json"
    
    # Check for duplicate
    local exists=$(jq --arg path "$artifact_path" '[.[] | select(.path == $path)] | length' "$artifact_file" 2>/dev/null || echo 0)
    if [[ $exists -gt 0 ]]; then
        return 0  # Already registered
    fi
    
    local updated=$(jq --arg path "$artifact_path" \
        --arg creator "$creator" \
        --arg type "$artifact_type" \
        --arg created "$(date -Iseconds)" \
        '. += [{
            "path": $path,
            "creator": $creator,
            "type": $type,
            "created": $created,
            "tested": false,
            "documented": false
        }]' "$artifact_file")
    echo "$updated" > "$artifact_file"
}

mark_artifact_tested() {
    local artifact_path=$1
    local artifact_file="$STATE_DIR/artifacts.json"
    
    local updated=$(jq --arg path "$artifact_path" \
        'map(if .path == $path then .tested = true else . end)' "$artifact_file")
    echo "$updated" > "$artifact_file"
}

mark_artifact_documented() {
    local artifact_path=$1
    local artifact_file="$STATE_DIR/artifacts.json"
    
    local updated=$(jq --arg path "$artifact_path" \
        'map(if .path == $path then .documented = true else . end)' "$artifact_file")
    echo "$updated" > "$artifact_file"
}

get_artifacts() {
    cat "$STATE_DIR/artifacts.json"
}

# =============================================================================
# MEMORY (KEY-VALUE STORE)
# =============================================================================

remember() {
    local key=$1
    local value=$2
    local important=${3:-false}
    local memory_file="$STATE_DIR/memory.json"
    local cycle=$(cat "$STATE_DIR/cycle_count" 2>/dev/null || echo 0)
    
    local updated=$(jq --arg key "$key" --arg val "$value" --argjson important "$important" --argjson cycle "$cycle" \
        '.[$key] = {"value": $val, "important": $important, "cycle": $cycle}' "$memory_file")
    echo "$updated" > "$memory_file"
}

recall() {
    local key=$1
    jq -r --arg key "$key" '.[$key].value // ""' "$STATE_DIR/memory.json"
}

remember_decision() {
    local decision=$1
    local rationale=$2
    local agent=$3
    local decisions_file="$STATE_DIR/decisions.json"
    
    local updated=$(jq --arg decision "$decision" \
        --arg rationale "$rationale" \
        --arg agent "$agent" \
        --arg timestamp "$(date -Iseconds)" \
        '. += [{
            "decision": $decision,
            "rationale": $rationale,
            "agent": $agent,
            "timestamp": $timestamp,
            "adr_written": false
        }]' "$decisions_file")
    echo "$updated" > "$decisions_file"
}

# =============================================================================
# GARBAGE COLLECTION & COMPACTION
# =============================================================================

compact_state() {
    local task_file="$STATE_DIR/task_board.json"
    local msg_file="$STATE_DIR/message_queue.json"
    local decisions_file="$STATE_DIR/decisions.json"
    local memory_file="$STATE_DIR/memory.json"
    
    # Archive completed tasks
    local completed=$(jq '[.[] | select(.status == "complete")]' "$task_file" 2>/dev/null || echo "[]")
    if [[ "$completed" != "[]" ]] && [[ $(echo "$completed" | jq 'length') -gt 0 ]]; then
        echo "$completed" >> "$STATE_DIR/archive/completed_tasks.json"
        # Keep only non-complete tasks
        local active=$(jq '[.[] | select(.status != "complete")]' "$task_file")
        echo "$active" > "$task_file"
    fi
    
    # Clear delivered messages
    if [[ -f "$msg_file" ]]; then
        local undelivered=$(jq '[.[] | select(.delivered != true)]' "$msg_file" 2>/dev/null || echo "[]")
        echo "$undelivered" > "$msg_file"
    fi
    
    # Trim decision log to last 50
    if [[ -f "$decisions_file" ]]; then
        local trimmed=$(jq '.[-50:]' "$decisions_file" 2>/dev/null || echo "[]")
        echo "$trimmed" > "$decisions_file"
    fi
    
    # Compact memory - keep important + recent
    if [[ -f "$memory_file" ]]; then
        local cycle=$(cat "$STATE_DIR/cycle_count" 2>/dev/null || echo 0)
        local min_cycle=$((cycle - 5))
        local compacted=$(jq --argjson min "$min_cycle" \
            'to_entries | map(select(.value.important == true or (.value.cycle // 0) >= $min)) | from_entries' \
            "$memory_file" 2>/dev/null || echo "{}")
        echo "$compacted" > "$memory_file"
    fi
}

checkpoint_state() {
    local checkpoint_name=${1:-"cycle_$(cat "$STATE_DIR/cycle_count" 2>/dev/null || echo 0)"}
    local checkpoint_dir="$STATE_DIR/checkpoints"
    
    mkdir -p "$checkpoint_dir"
    
    # Create compressed checkpoint
    tar -czf "$checkpoint_dir/${checkpoint_name}.tar.gz" \
        -C "$STATE_DIR" \
        task_board.json \
        project_state.md \
        artifacts.json \
        decisions.json \
        memory.json \
        agent_status.json \
        2>/dev/null || true
}

restore_checkpoint() {
    local checkpoint_name=$1
    local checkpoint_file="$STATE_DIR/checkpoints/${checkpoint_name}.tar.gz"
    
    if [[ -f "$checkpoint_file" ]]; then
        tar -xzf "$checkpoint_file" -C "$STATE_DIR"
        return 0
    fi
    return 1
}

# =============================================================================
# STATE HEALTH CHECK
# =============================================================================

check_state_health() {
    local errors=0

    # Check JSON validity
    for json_file in "$STATE_DIR"/*.json; do
        if [[ -f "$json_file" ]]; then
            if ! jq . "$json_file" >/dev/null 2>&1; then
                echo "INVALID JSON: $json_file"
                ((errors++)) || true
            fi
        fi
    done

    return $errors
}
