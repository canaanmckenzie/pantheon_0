#!/bin/bash
# State Management Library - The Crocodile's Domain
# Handles all persistent state, garbage collection, and compaction

STATE_DIR="$PANTHEON_ROOT/state"
STATE_DB="$STATE_DIR/pantheon.db"

# ============================================================================
# INITIALIZATION
# ============================================================================

init_state_db() {
    mkdir -p "$STATE_DIR"
    
    # Initialize JSON state files
    [[ -f "$STATE_DIR/task_board.json" ]] || echo "[]" > "$STATE_DIR/task_board.json"
    [[ -f "$STATE_DIR/message_queue.json" ]] || echo "[]" > "$STATE_DIR/message_queue.json"
    [[ -f "$STATE_DIR/agent_status.json" ]] || echo "{}" > "$STATE_DIR/agent_status.json"
    [[ -f "$STATE_DIR/artifacts.json" ]] || echo "[]" > "$STATE_DIR/artifacts.json"
    [[ -f "$STATE_DIR/spawn_queue.json" ]] || echo "[]" > "$STATE_DIR/spawn_queue.json"
    [[ -f "$STATE_DIR/memory.json" ]] || echo "{}" > "$STATE_DIR/memory.json"
    [[ -f "$STATE_DIR/decisions.json" ]] || echo "[]" > "$STATE_DIR/decisions.json"
}

# ============================================================================
# AGENT REGISTRATION
# ============================================================================

register_agent() {
    local agent_name=$1
    local status_file="$STATE_DIR/agent_status.json"
    
    local updated=$(jq --arg name "$agent_name" \
        '.[$name] = {"registered": true, "complete": false, "cycles": 0, "last_active": null}' \
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

get_agent_status() {
    local agent_name=$1
    jq -r --arg name "$agent_name" '.[$name] // {}' "$STATE_DIR/agent_status.json"
}

# ============================================================================
# TASK MANAGEMENT
# ============================================================================

add_task() {
    local task_description=$1
    local creator=$2
    local priority=${3:-"normal"}
    local task_file="$STATE_DIR/task_board.json"
    
    local task_id="task_$(date +%s%N | md5sum | head -c 8)"
    
    local updated=$(jq --arg id "$task_id" \
        --arg desc "$task_description" \
        --arg creator "$creator" \
        --arg priority "$priority" \
        --arg created "$(date -Iseconds)" \
        '. += [{
            "id": $id,
            "description": $desc,
            "creator": $creator,
            "priority": $priority,
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
    
    local updated=$(jq --arg id "$task_id" --arg agent "$agent_name" \
        'map(if .id == $id then .status = "in_progress" | .assigned_to = $agent else . end)' \
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

# ============================================================================
# ARTIFACT MANAGEMENT
# ============================================================================

register_artifact() {
    local artifact_path=$1
    local creator=$2
    local artifact_type=${3:-"file"}
    local artifact_file="$STATE_DIR/artifacts.json"
    
    local updated=$(jq --arg path "$artifact_path" \
        --arg creator "$creator" \
        --arg type "$artifact_type" \
        --arg created "$(date -Iseconds)" \
        '. += [{
            "path": $path,
            "creator": $creator,
            "type": $type,
            "created": $created
        }]' "$artifact_file")
    echo "$updated" > "$artifact_file"
}

get_artifacts() {
    cat "$STATE_DIR/artifacts.json"
}

get_artifacts_by_type() {
    local artifact_type=$1
    jq --arg type "$artifact_type" '[.[] | select(.type == $type)]' "$STATE_DIR/artifacts.json"
}

# ============================================================================
# MEMORY (CROCODILE'S LONG-TERM STORAGE)
# ============================================================================

remember() {
    local key=$1
    local value=$2
    local memory_file="$STATE_DIR/memory.json"
    
    local updated=$(jq --arg key "$key" --arg val "$value" \
        '.[$key] = $val' "$memory_file")
    echo "$updated" > "$memory_file"
}

recall() {
    local key=$1
    jq -r --arg key "$key" '.[$key] // ""' "$STATE_DIR/memory.json"
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
            "timestamp": $timestamp
        }]' "$decisions_file")
    echo "$updated" > "$decisions_file"
}

# ============================================================================
# GARBAGE COLLECTION & COMPACTION (CROCODILE'S PRIMARY DUTY)
# ============================================================================

compact_state() {
    log_info "Crocodile: Beginning state compaction..."
    
    # Remove completed tasks older than threshold
    local task_file="$STATE_DIR/task_board.json"
    local threshold=$(date -d '1 hour ago' -Iseconds 2>/dev/null || date -Iseconds)
    
    # Archive completed tasks
    local completed=$(jq '[.[] | select(.status == "complete")]' "$task_file")
    if [[ "$completed" != "[]" ]]; then
        echo "$completed" >> "$STATE_DIR/task_archive.json"
    fi
    
    # Keep only pending and in-progress
    local active=$(jq '[.[] | select(.status != "complete")]' "$task_file")
    echo "$active" > "$task_file"
    
    # Compact message queue - remove delivered messages
    local msg_file="$STATE_DIR/message_queue.json"
    local undelivered=$(jq '[.[] | select(.delivered != true)]' "$msg_file")
    echo "$undelivered" > "$msg_file"
    
    # Trim decision log to last 100
    local decisions_file="$STATE_DIR/decisions.json"
    local trimmed=$(jq '.[-100:]' "$decisions_file")
    echo "$trimmed" > "$decisions_file"
    
    log_info "Crocodile: State compaction complete"
}

checkpoint_state() {
    local checkpoint_name=${1:-"checkpoint_$(date +%Y%m%d_%H%M%S)"}
    local checkpoint_dir="$STATE_DIR/checkpoints/$checkpoint_name"
    
    mkdir -p "$checkpoint_dir"
    
    cp "$STATE_DIR"/*.json "$checkpoint_dir/" 2>/dev/null || true
    cp "$STATE_DIR"/*.md "$checkpoint_dir/" 2>/dev/null || true
    
    log_info "Crocodile: Checkpoint saved: $checkpoint_name"
}

restore_checkpoint() {
    local checkpoint_name=$1
    local checkpoint_dir="$STATE_DIR/checkpoints/$checkpoint_name"
    
    if [[ -d "$checkpoint_dir" ]]; then
        cp "$checkpoint_dir"/*.json "$STATE_DIR/" 2>/dev/null || true
        cp "$checkpoint_dir"/*.md "$STATE_DIR/" 2>/dev/null || true
        log_info "Crocodile: Restored checkpoint: $checkpoint_name"
    else
        log_error "Crocodile: Checkpoint not found: $checkpoint_name"
        return 1
    fi
}
