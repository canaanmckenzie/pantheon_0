#!/bin/bash
# Subagent Spawning System
# Enables Weaver and Djinn to spawn specialized worker agents

SPAWN_DIR="$PANTHEON_ROOT/spawn"
SPAWN_QUEUE="$PANTHEON_ROOT/state/spawn_queue.json"
SPAWN_REGISTRY="$PANTHEON_ROOT/state/spawn_registry.json"

# ============================================================================
# SPAWN QUEUE MANAGEMENT
# ============================================================================

init_spawn_system() {
    mkdir -p "$SPAWN_DIR"
    [[ -f "$SPAWN_QUEUE" ]] || echo "[]" > "$SPAWN_QUEUE"
    [[ -f "$SPAWN_REGISTRY" ]] || echo "[]" > "$SPAWN_REGISTRY"
}

queue_spawn() {
    local parent=$1
    local spawn_spec=$2
    
    # Parse spawn spec: "specialization:task"
    local specialization=$(echo "$spawn_spec" | cut -d':' -f1)
    local task=$(echo "$spawn_spec" | cut -d':' -f2-)
    
    # Only Weaver and Djinn can spawn
    if [[ "$parent" != "weaver" && "$parent" != "djinn" ]]; then
        log_warning "Spawn denied: $parent is not authorized to spawn"
        return 1
    fi
    
    local spawn_id="spawn_$(date +%s%N | md5sum | head -c 8)"
    
    local updated=$(jq --arg id "$spawn_id" \
        --arg parent "$parent" \
        --arg spec "$specialization" \
        --arg task "$task" \
        --arg queued "$(date -Iseconds)" \
        '. += [{
            "id": $id,
            "parent": $parent,
            "specialization": $spec,
            "task": $task,
            "status": "queued",
            "queued": $queued
        }]' "$SPAWN_QUEUE")
    echo "$updated" > "$SPAWN_QUEUE"
    
    log_spawn "$parent" "$specialization" "$task"
    echo "$spawn_id"
}

# ============================================================================
# SUBAGENT SPECIALIZATIONS
# ============================================================================

get_specialization_prompt() {
    local specialization=$1
    
    case "$specialization" in
        "frontend")
            cat << 'SPEC'
You are a FRONTEND SPECIALIST subagent. Your expertise:
- React, Vue, Svelte, vanilla JS
- CSS, Tailwind, styled-components
- Accessibility, responsive design
- State management, routing
- Build tools, bundlers

Focus solely on frontend implementation. Be thorough and production-ready.
Output format: Use [ARTIFACT:path] for files, [COMPLETE] when done.
SPEC
            ;;
        "backend")
            cat << 'SPEC'
You are a BACKEND SPECIALIST subagent. Your expertise:
- API design (REST, GraphQL)
- Database design and queries
- Authentication, authorization
- Server architecture
- Performance optimization

Focus solely on backend implementation. Be thorough and production-ready.
Output format: Use [ARTIFACT:path] for files, [COMPLETE] when done.
SPEC
            ;;
        "database")
            cat << 'SPEC'
You are a DATABASE SPECIALIST subagent. Your expertise:
- Schema design and normalization
- Query optimization
- Migrations and versioning
- Indexing strategies
- Data integrity constraints

Focus solely on database work. Be thorough and production-ready.
Output format: Use [ARTIFACT:path] for files, [COMPLETE] when done.
SPEC
            ;;
        "testing")
            cat << 'SPEC'
You are a TESTING SPECIALIST subagent. Your expertise:
- Unit testing
- Integration testing
- E2E testing
- Test coverage analysis
- Mocking and fixtures

Focus solely on comprehensive testing. Be thorough.
Output format: Use [ARTIFACT:path] for files, [COMPLETE] when done.
SPEC
            ;;
        "security")
            cat << 'SPEC'
You are a SECURITY SPECIALIST subagent. Your expertise:
- Vulnerability assessment
- Input validation
- Authentication hardening
- Encryption and secrets management
- Security headers and CORS

Focus solely on security analysis and hardening. Be thorough.
Output format: Use [ARTIFACT:path] for files, [COMPLETE] when done.
SPEC
            ;;
        "devops")
            cat << 'SPEC'
You are a DEVOPS SPECIALIST subagent. Your expertise:
- Docker and containerization
- CI/CD pipelines
- Infrastructure as code
- Monitoring and logging
- Deployment strategies

Focus solely on DevOps implementation. Be thorough.
Output format: Use [ARTIFACT:path] for files, [COMPLETE] when done.
SPEC
            ;;
        "documentation")
            cat << 'SPEC'
You are a DOCUMENTATION SPECIALIST subagent. Your expertise:
- API documentation
- README and guides
- Code comments
- Architecture diagrams
- User documentation

Focus solely on comprehensive documentation. Be thorough.
Output format: Use [ARTIFACT:path] for files, [COMPLETE] when done.
SPEC
            ;;
        "refactor")
            cat << 'SPEC'
You are a REFACTORING SPECIALIST subagent. Your expertise:
- Code smell detection
- Design pattern application
- Performance optimization
- Readability improvements
- Technical debt reduction

Focus solely on code improvement. Be thorough.
Output format: Use [ARTIFACT:path] for files, [COMPLETE] when done.
SPEC
            ;;
        "algorithm")
            cat << 'SPEC'
You are an ALGORITHM SPECIALIST subagent. Your expertise:
- Data structures
- Algorithm design
- Complexity analysis
- Optimization techniques
- Problem decomposition

Focus solely on algorithmic solutions. Be thorough.
Output format: Use [ARTIFACT:path] for files, [COMPLETE] when done.
SPEC
            ;;
        *)
            cat << SPEC
You are a GENERAL SPECIALIST subagent for: $specialization
Apply your expertise thoroughly to the assigned task.
Be comprehensive and production-ready.
Output format: Use [ARTIFACT:path] for files, [COMPLETE] when done.
SPEC
            ;;
    esac
}

# ============================================================================
# SPAWN EXECUTION
# ============================================================================

spawn_subagent() {
    local parent=$1
    local task=$2
    local specialization=$3
    
    local spawn_id="spawn_$(date +%s%N | md5sum | head -c 8)"
    local spawn_workdir="$SPAWN_DIR/$spawn_id"
    
    mkdir -p "$spawn_workdir"
    
    log_info "Spawning $specialization worker: $spawn_id"
    
    # Build subagent prompt
    local prompt_file="$spawn_workdir/prompt.md"
    cat > "$prompt_file" << PROMPT
# SUBAGENT ASSIGNMENT

## Parent Agent
$parent

## Specialization
$specialization

## Task
$task

## System Prompt
$(get_specialization_prompt "$specialization")

## Current Project State
$(cat "$PANTHEON_ROOT/state/project_state.md" 2>/dev/null || echo "See task for context.")

## Existing Artifacts
$(cat "$PANTHEON_ROOT/state/artifacts.json")

## Instructions
1. Focus ONLY on your assigned task
2. Produce complete, working code
3. Mark files with [ARTIFACT:relative/path]
4. Signal completion with [COMPLETE]
5. Report blockers with [BLOCKER:description]

## CRITICAL: TEXT-ONLY MODE
Do NOT use any tools (Read, Bash, Task, etc.). Produce your response as structured text only.
PROMPT

    # Execute subagent
    local response_file="$spawn_workdir/response.md"

    # --dangerously-skip-permissions enables fully autonomous operation
    local model_flag=""
    if [[ -n "${PANTHEON_MODEL:-}" ]]; then
        model_flag="--model $PANTHEON_MODEL"
    fi

    timeout "${PANTHEON_TIMEOUT:-300}" claude --dangerously-skip-permissions --print $model_flag \
        < "$prompt_file" > "$response_file" 2>/dev/null || true
    
    # Process subagent output
    process_subagent_output "$spawn_id" "$parent" "$response_file"
    
    # Register spawn
    local updated=$(jq --arg id "$spawn_id" \
        --arg parent "$parent" \
        --arg spec "$specialization" \
        --arg task "$task" \
        --arg completed "$(date -Iseconds)" \
        '. += [{
            "id": $id,
            "parent": $parent,
            "specialization": $spec,
            "task": $task,
            "completed": $completed,
            "workdir": "spawn/'"$spawn_id"'"
        }]' "$SPAWN_REGISTRY")
    echo "$updated" > "$SPAWN_REGISTRY"
    
    log_success "Subagent $spawn_id complete"
}

process_subagent_output() {
    local spawn_id=$1
    local parent=$2
    local response_file=$3
    
    if [[ ! -f "$response_file" ]]; then
        log_warning "No output from subagent $spawn_id"
        return
    fi
    
    # Extract artifacts
    grep -oP '(?<=\[ARTIFACT:)[^\]]+' "$response_file" 2>/dev/null | while read artifact; do
        register_artifact "$artifact" "subagent:$spawn_id"
    done
    
    # Check for blockers
    if grep -q '\[BLOCKER:' "$response_file" 2>/dev/null; then
        local blocker=$(grep -oP '(?<=\[BLOCKER:)[^\]]+' "$response_file" | head -1)
        report_blocker "subagent:$spawn_id" "$blocker"
    fi
    
    # Notify parent of completion
    if grep -q '\[COMPLETE\]' "$response_file" 2>/dev/null; then
        send_message "subagent:$spawn_id" "$parent" "Task complete. See spawn/$spawn_id/"
    fi
}

# ============================================================================
# SPAWN MANAGEMENT
# ============================================================================

get_active_spawns() {
    jq '[.[] | select(.status == "running")]' "$SPAWN_QUEUE"
}

get_spawn_count() {
    local parent=$1
    jq --arg parent "$parent" '[.[] | select(.parent == $parent)] | length' "$SPAWN_REGISTRY"
}

cleanup_spawns() {
    # Archive completed spawn workdirs older than threshold
    find "$SPAWN_DIR" -maxdepth 1 -type d -mmin +60 -exec mv {} "$SPAWN_DIR/archive/" \; 2>/dev/null || true
}

# Initialize on source
init_spawn_system
