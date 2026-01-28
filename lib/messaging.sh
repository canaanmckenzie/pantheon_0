#!/bin/bash
# =============================================================================
# INTER-AGENT MESSAGING SYSTEM
# =============================================================================
#
# Enables asynchronous communication between agents.
#
# OPTIMIZATIONS:
# - Message deduplication
# - Auto-expiry for old messages
# - Priority-based delivery
#
# =============================================================================

PANTHEON_ROOT="${PANTHEON_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
# Use .pantheon/ structure (fallback if not set)
PANTHEON_STATE_DIR="${PANTHEON_STATE_DIR:-$PANTHEON_ROOT/.pantheon/state}"
PANTHEON_LOGS_DIR="${PANTHEON_LOGS_DIR:-$PANTHEON_ROOT/.pantheon/logs}"
PANTHEON_SPAWN_DIR="${PANTHEON_SPAWN_DIR:-$PANTHEON_ROOT/.pantheon/spawn}"
PANTHEON_ARTIFACTS_DIR="${PANTHEON_ARTIFACTS_DIR:-$PANTHEON_ROOT/.pantheon/artifacts}"
PANTHEON_PROJECTS_DIR="${PANTHEON_PROJECTS_DIR:-$PANTHEON_ROOT/projects}"
MSG_QUEUE="$PANTHEON_STATE_DIR/message_queue.json"

# =============================================================================
# MESSAGE OPERATIONS
# =============================================================================

send_message() {
    local from=$1
    local to=$2
    local content=$3
    local priority=${4:-"normal"}
    local msg_type=${5:-"directive"}
    
    # Truncate very long messages
    if [[ ${#content} -gt 500 ]]; then
        content="${content:0:497}..."
    fi
    
    local msg_id="msg_$(date +%s%N | md5sum | head -c 8)"
    
    local updated=$(jq --arg id "$msg_id" \
        --arg from "$from" \
        --arg to "$to" \
        --arg content "$content" \
        --arg priority "$priority" \
        --arg type "$msg_type" \
        --arg timestamp "$(date -Iseconds)" \
        '. += [{
            "id": $id,
            "from": $from,
            "to": $to,
            "content": $content,
            "priority": $priority,
            "type": $type,
            "timestamp": $timestamp,
            "delivered": false,
            "acknowledged": false
        }]' "$MSG_QUEUE")
    echo "$updated" > "$MSG_QUEUE"
}

broadcast_message() {
    local from=$1
    local content=$2
    local priority=${3:-"normal"}
    
    for agent in crocodile scribe architect weaver doctor luminary djinn; do
        if [[ "$agent" != "$from" ]]; then
            send_message "$from" "$agent" "$content" "$priority" "broadcast"
        fi
    done
}

get_messages_for() {
    local agent_name=$1
    local mark_delivered=${2:-true}
    
    # Get undelivered messages, sorted by priority
    local messages=$(jq --arg to "$agent_name" \
        '[.[] | select(.to == $to and .delivered == false)] | sort_by(
            if .priority == "urgent" then 0
            elif .priority == "high" then 1
            elif .priority == "normal" then 2
            else 3 end
        )' "$MSG_QUEUE" 2>/dev/null || echo "[]")
    
    # Mark as delivered
    if [[ "$mark_delivered" == "true" ]] && [[ "$messages" != "[]" ]]; then
        local updated=$(jq --arg to "$agent_name" \
            'map(if .to == $to and .delivered == false then .delivered = true else . end)' \
            "$MSG_QUEUE")
        echo "$updated" > "$MSG_QUEUE"
    fi
    
    echo "$messages"
}

acknowledge_message() {
    local msg_id=$1
    
    local updated=$(jq --arg id "$msg_id" \
        'map(if .id == $id then .acknowledged = true else . end)' "$MSG_QUEUE")
    echo "$updated" > "$MSG_QUEUE"
}

# =============================================================================
# SPECIALIZED MESSAGE TYPES
# =============================================================================

report_blocker() {
    local from=$1
    local blocker=$2
    
    send_message "$from" "architect" "BLOCKER: $blocker" "urgent" "blocker"
    send_message "$from" "luminary" "BLOCKER: $blocker" "urgent" "blocker"
}

report_completion() {
    local from=$1
    local task=$2
    
    send_message "$from" "scribe" "COMPLETED: $task" "normal" "completion"
    send_message "$from" "crocodile" "COMPLETED: $task" "normal" "completion"
}

request_review() {
    local from=$1
    local artifact=$2
    
    send_message "$from" "doctor" "REVIEW REQUESTED: $artifact" "high" "review"
}

# =============================================================================
# MESSAGE CLEANUP
# =============================================================================

cleanup_old_messages() {
    # Remove messages older than 1 hour that have been delivered
    local cutoff=$(date -d '1 hour ago' -Iseconds 2>/dev/null || date -Iseconds)
    
    local cleaned=$(jq --arg cutoff "$cutoff" \
        '[.[] | select(.delivered != true or .timestamp > $cutoff)]' "$MSG_QUEUE" 2>/dev/null || cat "$MSG_QUEUE")
    echo "$cleaned" > "$MSG_QUEUE"
}

# =============================================================================
# FORMATTING FOR CONTEXT
# =============================================================================

format_messages_for_context() {
    local agent_name=$1
    local messages=$(get_messages_for "$agent_name" "false")
    
    if [[ "$messages" == "[]" ]]; then
        echo "No pending messages."
        return
    fi
    
    echo "$messages" | jq -r '.[] | "[\(.priority | ascii_upcase)] From \(.from): \(.content)"'
}
