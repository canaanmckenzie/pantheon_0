#!/bin/bash
# Inter-Agent Messaging System
# Enables asynchronous communication between agents

MSG_QUEUE="$PANTHEON_ROOT/state/message_queue.json"

# ============================================================================
# MESSAGE OPERATIONS
# ============================================================================

send_message() {
    local from=$1
    local to=$2
    local content=$3
    local priority=${4:-"normal"}
    local msg_type=${5:-"directive"}
    
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
    
    log_info "Message $msg_id: $from → $to"
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
    
    # Get undelivered messages
    local messages=$(jq --arg to "$agent_name" \
        '[.[] | select(.to == $to and .delivered == false)]' "$MSG_QUEUE")
    
    # Mark as delivered if requested
    if [[ "$mark_delivered" == "true" ]] && [[ "$messages" != "[]" ]]; then
        local updated=$(jq --arg to "$agent_name" \
            'map(if .to == $to and .delivered == false then .delivered = true else . end)' \
            "$MSG_QUEUE")
        echo "$updated" > "$MSG_QUEUE"
    fi
    
    echo "$messages"
}

get_messages_from() {
    local agent_name=$1
    jq --arg from "$agent_name" '[.[] | select(.from == $from)]' "$MSG_QUEUE"
}

acknowledge_message() {
    local msg_id=$1
    
    local updated=$(jq --arg id "$msg_id" \
        'map(if .id == $id then .acknowledged = true else . end)' "$MSG_QUEUE")
    echo "$updated" > "$MSG_QUEUE"
}

# ============================================================================
# SPECIALIZED MESSAGE TYPES
# ============================================================================

request_assistance() {
    local from=$1
    local to=$2
    local task=$3
    
    send_message "$from" "$to" "ASSISTANCE REQUESTED: $task" "high" "request"
}

report_blocker() {
    local from=$1
    local blocker=$2
    
    # Send to Architect and Luminary
    send_message "$from" "architect" "BLOCKER: $blocker" "urgent" "blocker"
    send_message "$from" "luminary" "BLOCKER: $blocker" "urgent" "blocker"
}

report_completion() {
    local from=$1
    local task=$2
    
    # Notify Scribe for documentation
    send_message "$from" "scribe" "COMPLETED: $task" "normal" "completion"
    # Notify Crocodile for state update
    send_message "$from" "crocodile" "COMPLETED: $task" "normal" "completion"
}

request_review() {
    local from=$1
    local artifact=$2
    
    # Send to Doctor for testing
    send_message "$from" "doctor" "REVIEW REQUESTED: $artifact" "high" "review"
}

request_spawn() {
    local from=$1
    local task=$2
    local specialization=$3
    
    # Only Weaver and Djinn can spawn
    if [[ "$from" == "weaver" || "$from" == "djinn" ]]; then
        send_message "$from" "$from" "SPAWN: $specialization for $task" "high" "spawn_request"
    else
        # Redirect to Weaver
        send_message "$from" "weaver" "SPAWN REQUEST: Need $specialization for $task" "high" "spawn_delegation"
    fi
}

# ============================================================================
# MESSAGE FORMATTING FOR CONTEXT
# ============================================================================

format_messages_for_context() {
    local agent_name=$1
    local messages=$(get_messages_for "$agent_name" "false")
    
    if [[ "$messages" == "[]" ]]; then
        echo "No pending messages."
        return
    fi
    
    echo "$messages" | jq -r '.[] | "[\(.priority | ascii_upcase)] From \(.from): \(.content)"'
}
