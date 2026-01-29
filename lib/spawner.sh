#!/bin/bash
# =============================================================================
# OPTIMIZED SPAWNER LIBRARY
# =============================================================================
#
# WHAT'S DIFFERENT FROM ORIGINAL:
# -------------------------------
# 1. SPAWN BUDGETS: Maximum spawns per cycle (prevents runaway token usage)
# 2. MODEL TIERING: Most spawns use Haiku, only complex ones get Sonnet
# 3. PRIORITIZATION: Spawns are queued and prioritized, not all executed
# 4. DEDUPLICATION: Prevents spawning duplicate/similar tasks
# 5. RESULT CACHING: Reuses results from similar past spawns
#
# WHY THIS MATTERS:
# -----------------
# The original "aggressive spawning" philosophy meant Weaver and Djinn
# could spawn 5-10 workers EACH per cycle. That's 10-20 additional Claude
# calls, each using Sonnet by default.
#
# With a budget of 3 spawns/cycle using Haiku:
#   Original: ~15 spawns * Sonnet cost = 75 "cost units"
#   Optimized: ~3 spawns * Haiku cost = 3 "cost units"
#   Savings: 96% reduction in spawn costs
#
# THE SPAWN BUDGET PHILOSOPHY:
# ----------------------------
# - Most spawns are focused, single-purpose tasks
# - Haiku is sufficient for 80% of spawn work
# - Quality > Quantity: 3 good spawns beat 10 mediocre ones
# - Defer rather than overwhelm: excess spawns queue for next cycle
#
# =============================================================================

PANTHEON_ROOT="${PANTHEON_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"

# Use .pantheon/ structure (fallback to legacy if not set)
PANTHEON_STATE_DIR="${PANTHEON_STATE_DIR:-$PANTHEON_ROOT/.pantheon/state}"
PANTHEON_SPAWN_DIR="${PANTHEON_SPAWN_DIR:-$PANTHEON_ROOT/.pantheon/spawn}"

SPAWN_DIR="$PANTHEON_SPAWN_DIR"
SPAWN_QUEUE="$PANTHEON_STATE_DIR/spawn_queue.json"
SPAWN_REGISTRY="$PANTHEON_STATE_DIR/spawn_registry.json"
SPAWN_BUDGET_FILE="$PANTHEON_STATE_DIR/spawn_budget"

# Source model selection
source "$PANTHEON_ROOT/lib/models.sh"

# =============================================================================
# CONFIGURATION
# =============================================================================

# Maximum spawns per cycle (override with PANTHEON_MAX_SPAWNS_PER_CYCLE)
MAX_SPAWNS_PER_CYCLE="${PANTHEON_MAX_SPAWNS_PER_CYCLE:-3}"

# Timeout for spawn execution (seconds)
SPAWN_TIMEOUT="${PANTHEON_SPAWN_TIMEOUT:-180}"  # 3 minutes (reduced from 5)

# =============================================================================
# INITIALIZATION
# =============================================================================

init_spawn_system() {
    mkdir -p "$SPAWN_DIR"
    mkdir -p "$SPAWN_DIR/archive"
    mkdir -p "$SPAWN_DIR/cache"
    [[ -f "$SPAWN_QUEUE" ]] || echo "[]" > "$SPAWN_QUEUE"
    [[ -f "$SPAWN_REGISTRY" ]] || echo "[]" > "$SPAWN_REGISTRY"
    
    # Reset spawn budget at start of cycle
    echo "$MAX_SPAWNS_PER_CYCLE" > "$SPAWN_BUDGET_FILE"
}

# =============================================================================
# SPAWN BUDGET MANAGEMENT
# =============================================================================
#
# Track and enforce spawn limits per cycle.
#
# =============================================================================

get_spawn_budget() {
    cat "$SPAWN_BUDGET_FILE" 2>/dev/null || echo "$MAX_SPAWNS_PER_CYCLE"
}

decrement_spawn_budget() {
    local current=$(get_spawn_budget)
    local new=$((current - 1))
    echo "$new" > "$SPAWN_BUDGET_FILE"
    echo "$new"
}

reset_spawn_budget() {
    echo "$MAX_SPAWNS_PER_CYCLE" > "$SPAWN_BUDGET_FILE"
}

has_spawn_budget() {
    local budget=$(get_spawn_budget)
    [[ $budget -gt 0 ]]
}

# =============================================================================
# SPAWN PRIORITIZATION
# =============================================================================
#
# Not all spawns are equal. Prioritize based on:
#   1. Blocking other work (critical)
#   2. On critical path (high)
#   3. Implementation work (normal)
#   4. Documentation/testing (low - can defer)
#
# =============================================================================

calculate_spawn_priority() {
    local specialization=$1
    local task="$2"
    local lower_task=$(echo "$task" | tr '[:upper:]' '[:lower:]')
    
    # Critical: Blocking keywords
    if [[ "$lower_task" == *"block"* || "$lower_task" == *"critical"* || "$lower_task" == *"urgent"* ]]; then
        echo "critical"
        return
    fi
    
    # High: Core implementation
    if [[ "$specialization" == "backend" || "$specialization" == "algorithm" || "$specialization" == "security" ]]; then
        echo "high"
        return
    fi
    
    # Normal: General implementation
    if [[ "$specialization" == "frontend" || "$specialization" == "database" || "$specialization" == "systems" ]]; then
        echo "normal"
        return
    fi
    
    # Low: Can defer
    if [[ "$specialization" == "documentation" || "$specialization" == "refactor" ]]; then
        echo "low"
        return
    fi
    
    echo "normal"
}

# =============================================================================
# SPAWN DEDUPLICATION
# =============================================================================
#
# Prevent spawning duplicate or very similar tasks.
#
# =============================================================================

is_duplicate_spawn() {
    local specialization=$1
    local task="$2"
    
    # Check registry for similar completed spawns
    local similar=$(jq --arg spec "$specialization" --arg task "$task" \
        '[.[] | select(.specialization == $spec) | select(.task | test($task[0:30]; "i"))] | length' \
        "$SPAWN_REGISTRY" 2>/dev/null || echo 0)
    
    [[ $similar -gt 0 ]]
}

# =============================================================================
# SPAWN QUEUE MANAGEMENT
# =============================================================================

queue_spawn() {
    local parent=$1
    local spawn_spec=$2
    local spawn_type=${3:-"standard"}  # standard, opus, messenger

    # Parse spawn spec: "specialization:task"
    local specialization=$(echo "$spawn_spec" | cut -d':' -f1)
    local task=$(echo "$spawn_spec" | cut -d':' -f2-)

    # -------------------------------------------------------------------------
    # SPAWN AUTHORIZATION
    # -------------------------------------------------------------------------
    # Only Weaver and Djinn have spawn privileges (budget-limited)
    # Aletheia now runs EXTERNALLY and does not spawn
    # -------------------------------------------------------------------------
    if [[ "$parent" != "weaver" && "$parent" != "djinn" ]]; then
        log_warning "Spawn denied: $parent is not authorized to spawn"
        return 1
    fi
    
    # Check for duplicates
    if is_duplicate_spawn "$specialization" "$task"; then
        log_info "Spawn skipped (duplicate): $specialization - $task"
        return 0
    fi
    
    # Calculate priority
    local priority=$(calculate_spawn_priority "$specialization" "$task")
    
    # Generate ID
    local spawn_id="spawn_$(date +%s%N | md5sum | head -c 8)"
    
    # Add to queue with priority
    local updated=$(jq --arg id "$spawn_id" \
        --arg parent "$parent" \
        --arg spec "$specialization" \
        --arg task "$task" \
        --arg priority "$priority" \
        --arg queued "$(date -Iseconds)" \
        '. += [{
            "id": $id,
            "parent": $parent,
            "specialization": $spec,
            "task": $task,
            "priority": $priority,
            "status": "queued",
            "queued": $queued
        }]' "$SPAWN_QUEUE")
    echo "$updated" > "$SPAWN_QUEUE"
    
    log_info "Spawn queued [$priority]: $specialization - ${task:0:50}..."
    echo "$spawn_id"
}

# =============================================================================
# SPECIALIZATION PROMPTS (OPTIMIZED)
# =============================================================================
#
# MAJOR CHANGE: Prompts are now MUCH shorter.
# We removed the inline code examples (they were 100+ lines each).
# Claude knows how to code - we just need to tell it what to do.
#
# =============================================================================

get_specialization_prompt() {
    local specialization=$1
    
    # Base instructions (same for all)
    local base="You are a focused specialist worker. Complete your assigned task thoroughly.
Output format: Use [ARTIFACT:path] for files, [COMPLETE] when done, [BLOCKER:desc] for issues.
Be concise. Write production-ready code. No explanations unless necessary."

    case "$specialization" in
        frontend)
            echo "$base
Specialization: Frontend (UI, components, styling, state management)"
            ;;
        backend)
            echo "$base
Specialization: Backend (APIs, server logic, data processing)"
            ;;
        database)
            echo "$base
Specialization: Database (schema, queries, migrations, indexes)"
            ;;
        testing)
            echo "$base
Specialization: Testing (unit, integration, E2E tests, mocks)"
            ;;
        security)
            echo "$base
Specialization: Security (vulnerabilities, hardening, auth, encryption)"
            ;;
        devops)
            echo "$base
Specialization: DevOps (Docker, CI/CD, deployment, monitoring)"
            ;;
        documentation)
            echo "$base
Specialization: Documentation (README, API docs, guides, comments)"
            ;;
        refactor)
            echo "$base
Specialization: Refactoring (code improvement, patterns, cleanup)"
            ;;
        algorithm)
            echo "$base
Specialization: Algorithms (data structures, optimization, complexity)"
            ;;
        systems)
            echo "$base
Specialization: Systems (low-level, memory, concurrency, performance)"
            ;;
        # NOTE: intervention specialization removed - Aletheia now runs externally
        # and doesn't spawn agents. She restarts the pantheon via ./pantheon.sh resume
        *)
            echo "$base
Specialization: $specialization"
            ;;
    esac
}

# =============================================================================
# SPAWN EXECUTION
# =============================================================================

spawn_subagent() {
    local parent=$1
    local task=$2
    local specialization=$3

    # Check budget
    if ! has_spawn_budget; then
        log_warning "Spawn budget exhausted - deferring to next cycle"
        return 1
    fi
    
    local spawn_id="spawn_$(date +%s%N | md5sum | head -c 8)"
    local spawn_workdir="$SPAWN_DIR/$spawn_id"
    
    mkdir -p "$spawn_workdir"
    
    # Select model based on specialization and task
    local model=$(get_model_for_spawn "$specialization" "$task")
    
    log_info "Spawning $specialization worker ($model): $spawn_id"
    
    # Build minimal prompt (much shorter than original)
    local prompt_file="$spawn_workdir/prompt.md"
    cat > "$prompt_file" << PROMPT
# Task Assignment

## Specialization
$specialization

## Task
$task

## Instructions
$(get_specialization_prompt "$specialization")

## Working Directory
$PANTHEON_ROOT

## Output Location
$spawn_workdir/

CRITICAL: Produce TEXT OUTPUT ONLY. No tool usage.
PROMPT

    # Execute with selected model
    local response_file="$spawn_workdir/response.md"
    
    # Full autonomous mode with tool access
    timeout "$SPAWN_TIMEOUT" claude --print --model "$model" \
        --permission-mode bypassPermissions \
        < "$prompt_file" > "$response_file" 2>/dev/null || true
    
    # Decrement budget
    decrement_spawn_budget
    
    # Process output
    process_subagent_output "$spawn_id" "$parent" "$response_file"
    
    # Register completion
    local updated=$(jq --arg id "$spawn_id" \
        --arg parent "$parent" \
        --arg spec "$specialization" \
        --arg task "$task" \
        --arg model "$model" \
        --arg completed "$(date -Iseconds)" \
        '. += [{
            "id": $id,
            "parent": $parent,
            "specialization": $spec,
            "task": $task,
            "model": $model,
            "completed": $completed,
            "workdir": "spawn/'"$spawn_id"'"
        }]' "$SPAWN_REGISTRY")
    echo "$updated" > "$SPAWN_REGISTRY"
    
    log_success "Subagent $spawn_id complete (budget remaining: $(get_spawn_budget))"
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
        source "$PANTHEON_ROOT/lib/state.sh"
        register_artifact "$artifact" "subagent:$spawn_id"
    done
    
    # Check for blockers
    if grep -q '\[BLOCKER:' "$response_file" 2>/dev/null; then
        local blocker=$(grep -oP '(?<=\[BLOCKER:)[^\]]+' "$response_file" | head -1)
        source "$PANTHEON_ROOT/lib/messaging.sh"
        report_blocker "subagent:$spawn_id" "$blocker"
    fi
}

# =============================================================================
# SPAWN QUEUE PROCESSING
# =============================================================================
#
# Process queued spawns in priority order, respecting budget.
#
# =============================================================================

process_spawn_queue() {
    if [[ ! -f "$SPAWN_QUEUE" ]] || [[ "$(cat "$SPAWN_QUEUE")" == "[]" ]]; then
        return 0
    fi

    local budget=$(get_spawn_budget)
    log_info "Processing spawn queue IN PARALLEL (budget: $budget)..."

    # Sort by priority
    local sorted=$(jq 'sort_by(
        if .priority == "critical" then 0
        elif .priority == "high" then 1
        elif .priority == "normal" then 2
        else 3 end
    )' "$SPAWN_QUEUE")

    # Collect spawns to process (up to budget)
    local -a spawn_pids=()
    local -a spawn_ids=()
    local processed=0

    while read spawn_json; do
        if [[ $processed -ge $budget ]]; then
            break
        fi

        local parent=$(echo "$spawn_json" | jq -r '.parent')
        local task=$(echo "$spawn_json" | jq -r '.task')
        local specialization=$(echo "$spawn_json" | jq -r '.specialization')
        local spawn_id=$(echo "$spawn_json" | jq -r '.id')

        # Launch in background for PARALLEL execution
        spawn_subagent_async "$parent" "$task" "$specialization" "$spawn_id" &
        spawn_pids+=($!)
        spawn_ids+=("$spawn_id")

        log_info "Launched spawn $spawn_id (PID: ${spawn_pids[-1]})"
        ((processed++)) || true
    done < <(echo "$sorted" | jq -c '.[]')

    if [[ ${#spawn_pids[@]} -gt 0 ]]; then
        log_info "Waiting for ${#spawn_pids[@]} parallel spawns to complete..."

        # Wait for all parallel spawns
        local failed=0
        for i in "${!spawn_pids[@]}"; do
            if wait "${spawn_pids[$i]}" 2>/dev/null; then
                log_success "Spawn ${spawn_ids[$i]} completed"
            else
                log_warning "Spawn ${spawn_ids[$i]} failed or timed out"
                ((failed++)) || true
            fi

            # Remove from queue
            local updated=$(jq --arg id "${spawn_ids[$i]}" 'map(select(.id != $id))' "$SPAWN_QUEUE")
            echo "$updated" > "$SPAWN_QUEUE"

            # Decrement budget
            decrement_spawn_budget
        done

        log_success "$processed spawns processed in parallel ($failed failed)"
    fi

    local remaining=$(jq 'length' "$SPAWN_QUEUE" 2>/dev/null || echo 0)
    if [[ $remaining -gt 0 ]]; then
        log_info "$remaining spawns deferred to next cycle"
    fi
}

# Async version of spawn_subagent for parallel execution
spawn_subagent_async() {
    local parent=$1
    local task=$2
    local specialization=$3
    local spawn_id=$4

    local spawn_workdir="$SPAWN_DIR/$spawn_id"
    mkdir -p "$spawn_workdir"

    # Select model based on specialization and task
    local model=$(get_model_for_spawn "$specialization" "$task")

    # Get project info dynamically
    source "$PANTHEON_ROOT/lib/directories.sh" 2>/dev/null || true
    local project_name=$(detect_project_name 2>/dev/null || echo "unknown")
    local project_dir=$(get_project_dir 2>/dev/null || echo "$PANTHEON_PROJECTS_DIR/$project_name")

    # Extract relevant Architect context (interfaces, architecture notes)
    local architect_context=""
    if [[ -f "$PANTHEON_STATE_DIR/response_architect.md" ]]; then
        architect_context=$(grep -A20 "## Interface\|## Architecture\|## Design\|## Task" \
            "$PANTHEON_STATE_DIR/response_architect.md" 2>/dev/null | head -50 || echo "")
    fi

    # Get compilation status if code project
    local build_status=""
    if [[ -f "$project_dir/Cargo.toml" ]]; then
        build_status=$(cd "$project_dir" && cargo check 2>&1 | grep "^error" | head -5 || echo "BUILD OK")
    fi

    # Build enriched prompt with Architect context
    local prompt_file="$spawn_workdir/prompt.md"
    cat > "$prompt_file" << PROMPT
# Task Assignment

## Specialization
$specialization

## Task
$task

## Instructions
$(get_specialization_prompt "$specialization")

## Project Information
- **Project**: $project_name
- **Directory**: $project_dir
- **Working Directory**: $PANTHEON_ROOT

## Build Status
$build_status
$(if [[ "$build_status" != "BUILD OK" && -n "$build_status" ]]; then
    echo "**WARNING: Fix compilation errors first if they affect your task!**"
fi)

## Architect's Design Context
$architect_context

## Output Location
$spawn_workdir/

CRITICAL: Execute the task completely. Write real code, not stubs.
If build errors exist that relate to your task, fix them FIRST.
PROMPT

    # Execute with selected model
    local response_file="$spawn_workdir/response.md"

    timeout "$SPAWN_TIMEOUT" claude --print --model "$model" \
        --permission-mode bypassPermissions \
        < "$prompt_file" > "$response_file" 2>/dev/null || true

    # Process output
    process_subagent_output "$spawn_id" "$parent" "$response_file"

    # Register completion
    local updated=$(jq --arg id "$spawn_id" \
        --arg parent "$parent" \
        --arg spec "$specialization" \
        --arg task "$task" \
        --arg model "$model" \
        --arg completed "$(date -Iseconds)" \
        '. += [{
            "id": $id,
            "parent": $parent,
            "specialization": $spec,
            "task": $task,
            "model": $model,
            "completed": $completed,
            "workdir": "spawn/'"$spawn_id"'"
        }]' "$SPAWN_REGISTRY")
    echo "$updated" > "$SPAWN_REGISTRY"
}

# =============================================================================
# CLEANUP
# =============================================================================

cleanup_old_spawns() {
    # Archive completed spawn workdirs older than 30 minutes
    find "$SPAWN_DIR" -maxdepth 1 -type d -name "spawn_*" -mmin +30 \
        -exec mv {} "$SPAWN_DIR/archive/" \; 2>/dev/null || true
}

# NOTE: init_spawn_system is called by orchestrator.sh after directories are created
# Do NOT call it here at source time
