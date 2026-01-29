#!/bin/bash
# shellcheck source-path=SCRIPTDIR

# =============================================================================
# PANTHEON ORCHESTRATOR - OPTIMIZED
# =============================================================================
#
# Autonomous Multi-Agent Claude Code Swarm
#
# MAJOR OPTIMIZATIONS:
# --------------------
# 1. MODEL TIERING: Each agent uses the cheapest appropriate model
# 2. CONDITIONAL EXECUTION: Agents skip when they have no work
# 3. SMART CONTEXT: Each agent gets tailored context, not full state dump
# 4. SPAWN BUDGETS: Limited spawns per cycle to control token usage
# 5. RATE LIMIT HANDLING: Graceful pause and resume capability
#
# ESTIMATED SAVINGS vs ORIGINAL:
# ------------------------------
# - Model tiering:       40-60% reduction (Haiku for routine work)
# - Conditional exec:    20-30% reduction (skip idle agents)
# - Smart context:       30-40% reduction (less input tokens)
# - Spawn budgets:       50-70% reduction (controlled spawning)
# - Combined:            70-85% total reduction in token usage
#
# =============================================================================

set -e

PANTHEON_ROOT="$(cd "$(dirname "$0")" && pwd)"
export PANTHEON_ROOT

# =============================================================================
# SOURCE LIBRARIES
# =============================================================================

# Source directories.sh FIRST to set up path variables
source "$PANTHEON_ROOT/lib/directories.sh"

# Then other libraries
source "$PANTHEON_ROOT/lib/colors.sh"
source "$PANTHEON_ROOT/lib/logging.sh"
source "$PANTHEON_ROOT/lib/state.sh"
source "$PANTHEON_ROOT/lib/messaging.sh"
source "$PANTHEON_ROOT/lib/spawner.sh"
source "$PANTHEON_ROOT/lib/models.sh"
source "$PANTHEON_ROOT/lib/context.sh"
source "$PANTHEON_ROOT/lib/conditional.sh"
source "$PANTHEON_ROOT/lib/verify.sh"
source "$PANTHEON_ROOT/lib/quality.sh"
source "$PANTHEON_ROOT/lib/self_heal.sh"

# =============================================================================
# CONFIGURATION
# =============================================================================

# Maximum cycles (override with PANTHEON_MAX_CYCLES or --cycles flag)
MAX_CYCLES="${PANTHEON_MAX_CYCLES:-10}"

# Maximum spawns per cycle (override with PANTHEON_MAX_SPAWNS_PER_CYCLE)
export PANTHEON_MAX_SPAWNS_PER_CYCLE="${PANTHEON_MAX_SPAWNS_PER_CYCLE:-3}"

# Agent timeout in seconds (increased for implementation agents)
AGENT_TIMEOUT="${PANTHEON_AGENT_TIMEOUT:-300}"

# =============================================================================
# INITIALIZATION
# =============================================================================

init_pantheon() {
    log_header "PANTHEON SWARM INITIALIZING (RIGID STRUCTURE)"

    # =========================================================================
    # RIGID DIRECTORY STRUCTURE - ALL system directories inside .pantheon/
    # =========================================================================
    # NO directories created in root except .pantheon/ and projects/
    # This is ENFORCED - do not add mkdir for root-level directories
    # =========================================================================
    init_pantheon_directories

    # Initialize subsystems (AFTER directories exist)
    init_state_db
    init_spawn_system

    # Clear previous run artifacts (ONLY from .pantheon/)
    rm -f "$PANTHEON_STATE_DIR/"*.lock 2>/dev/null || true
    rm -f "$PANTHEON_STATE_DIR/rate_limit.flag" 2>/dev/null || true

    # =========================================================================
    # STATE FILE INITIALIZATION - ONLY in .pantheon/state/
    # =========================================================================
    echo "[]" > "$PANTHEON_STATE_DIR/task_board.json"
    echo "[]" > "$PANTHEON_STATE_DIR/message_queue.json"
    echo "{}" > "$PANTHEON_STATE_DIR/agent_status.json"
    echo "[]" > "$PANTHEON_STATE_DIR/artifacts.json"
    echo "[]" > "$PANTHEON_STATE_DIR/spawn_queue.json"
    echo "[]" > "$PANTHEON_STATE_DIR/spawn_registry.json"
    echo "{}" > "$PANTHEON_STATE_DIR/memory.json"
    echo "[]" > "$PANTHEON_STATE_DIR/decisions.json"
    echo "0" > "$PANTHEON_STATE_DIR/cycle_count"

    # =========================================================================
    # DIRECTORY STRUCTURE VALIDATION & CLEANUP
    # =========================================================================
    local dir_mode="${PANTHEON_DIRECTORY_MODE:-fix}"  # Default to fix mode
    log_info "Directory structure validation (mode: $dir_mode)..."

    case "$dir_mode" in
        fix)
            log_info "Fixing directory structure and cleaning up..."
            fix_directory_structure 2>&1 | while read line; do
                [[ -n "$line" ]] && log_info "  $line"
            done
            ;;
        strict)
            if ! validate_directory_structure >/dev/null 2>&1; then
                log_error "Directory structure validation failed in strict mode"
                validate_directory_structure
                exit 1
            fi
            ;;
        warn|*)
            validate_directory_structure 2>&1 | while read line; do
                [[ "$line" == *"ERROR"* ]] && log_warning "$line"
                [[ "$line" == *"WARNING"* ]] && log_warning "$line"
            done
            ;;
    esac

    # Detect and store project name (ONLY in .pantheon/state/)
    local project_name=$(detect_project_name)
    if [[ -n "$project_name" ]]; then
        echo "$project_name" > "$PANTHEON_STATE_DIR/project_name"
        local project_dir=$(get_project_dir)
        log_info "Detected project: $project_name"
        log_info "Project directory: $project_dir"
    fi

    # Register agents (Aletheia excluded - she runs externally via ./pantheon.sh aletheia)
    for agent in luminary architect weaver djinn doctor scribe crocodile; do
        register_agent "$agent"
    done

    log_success "Pantheon initialized"
    log_info "System directory: $PANTHEON_SYSTEM_DIR"
    log_info "Projects directory: $PANTHEON_PROJECTS_DIR"
    log_info "Model tiers: T1=${MODEL_TIER1##*-} T2=${MODEL_TIER2##*-} T3=${MODEL_TIER3##*-}"
    log_info "Spawn budget: $PANTHEON_MAX_SPAWNS_PER_CYCLE per cycle"
}

# =============================================================================
# AGENT EXECUTION
# =============================================================================
#
# This is where the magic happens. Each agent call now:
# 1. Checks if it should run (conditional execution)
# 2. Selects the appropriate model (model tiering)
# 3. Builds tailored context (smart context)
# 4. Executes with timeout and rate limit detection
#
# =============================================================================

run_agent() {
    local agent_name=$1
    local directive="$2"
    
    # -------------------------------------------------------------------------
    # STEP 1: Check if agent should run (CONDITIONAL EXECUTION)
    # -------------------------------------------------------------------------
    if ! is_agent_forced "$agent_name"; then
        if ! should_run_agent "$agent_name"; then
            log_agent_skip "$agent_name" "No work this cycle"
            mark_agent_skipped "$agent_name"
            return 0
        fi
    fi
    
    # -------------------------------------------------------------------------
    # STEP 2: Select model based on agent and task (MODEL TIERING)
    # -------------------------------------------------------------------------
    local model=$(select_model "$agent_name" "$directive")
    
    log_agent "$agent_name" "Starting (directive: ${directive:0:50}...)"
    log_model_selection "$agent_name" "$model" "$(detect_task_complexity "$directive" "$agent_name")"
    
    # -------------------------------------------------------------------------
    # STEP 3: Load agent prompt (OPTIMIZED - shorter prompts)
    # -------------------------------------------------------------------------
    local agent_prompt_file="$PANTHEON_ROOT/agents/${agent_name}.md"
    local agent_prompt=""
    if [[ -f "$agent_prompt_file" ]]; then
        agent_prompt=$(cat "$agent_prompt_file")
    else
        log_warning "No prompt file for $agent_name"
        agent_prompt="You are the $agent_name agent. Complete your assigned task."
    fi
    
    # -------------------------------------------------------------------------
    # STEP 4: Build tailored context (SMART CONTEXT)
    # -------------------------------------------------------------------------
    local context=$(build_context "$agent_name" "$directive")
    log_context_size "$agent_name" "$context"
    
    # -------------------------------------------------------------------------
    # STEP 5: Save context for debugging and input
    # -------------------------------------------------------------------------
    local context_file="$PANTHEON_STATE_DIR/context_${agent_name}.md"
    echo "$context" > "$context_file"

    # -------------------------------------------------------------------------
    # STEP 6: Execute agent with timeout and rate limit detection
    # -------------------------------------------------------------------------
    local response_file="$PANTHEON_STATE_DIR/response_${agent_name}.md"
    local start_time=$(date +%s)

    # DIAGNOSTIC: Doctor-specific logging
    if [[ "$agent_name" == "doctor" ]]; then
        local diag_file="$PANTHEON_LOGS_DIR/doctor_diagnostic.log"
        echo "" >> "$diag_file"
        echo "========================================" >> "$diag_file"
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] DOCTOR ACTIVATION" >> "$diag_file"
        echo "----------------------------------------" >> "$diag_file"
        echo "Model: $model" >> "$diag_file"
        echo "Context size: $(wc -c < "$context_file") bytes" >> "$diag_file"
        echo "Context lines: $(wc -l < "$context_file")" >> "$diag_file"
        echo "Artifacts to test: $(jq '[.[] | select(.tested==false)] | length' "$PANTHEON_STATE_DIR/artifacts.json" 2>/dev/null || echo 0)" >> "$diag_file"
        echo "Pending test tasks: $(jq '[.[] | select(.status=="pending") | select(.description | test("test"; "i"))] | length' "$PANTHEON_STATE_DIR/task_board.json" 2>/dev/null || echo 0)" >> "$diag_file"
        echo "Messages for Doctor: $(jq '[.[] | select(.to=="doctor")] | length' "$PANTHEON_STATE_DIR/message_queue.json" 2>/dev/null || echo 0)" >> "$diag_file"
        echo "Timeout: ${AGENT_TIMEOUT}s" >> "$diag_file"
        echo "----------------------------------------" >> "$diag_file"
    fi

    # Execute with timeout - matching pantheon_0 invocation style
    # Use --system-prompt for agent identity, pipe context as input
    timeout "$AGENT_TIMEOUT" claude --print --model "$model" \
        --dangerously-skip-permissions \
        --system-prompt "$(cat "$agent_prompt_file")" \
        < "$context_file" > "$response_file" 2>&1 || {
        local exit_code=$?
        if [[ $exit_code -eq 124 ]]; then
            log_warning "$agent_name timed out after ${AGENT_TIMEOUT}s"
            # DIAGNOSTIC: Doctor timeout analysis
            if [[ "$agent_name" == "doctor" ]]; then
                echo "[$(date '+%H:%M:%S')] TIMEOUT after ${AGENT_TIMEOUT}s" >> "$PANTHEON_LOGS_DIR/doctor_diagnostic.log"
                echo "Response size at timeout: $(wc -c < "$response_file" 2>/dev/null || echo 0) bytes" >> "$PANTHEON_LOGS_DIR/doctor_diagnostic.log"
                echo "Response preview (last 500 chars):" >> "$PANTHEON_LOGS_DIR/doctor_diagnostic.log"
                tail -c 500 "$response_file" >> "$PANTHEON_LOGS_DIR/doctor_diagnostic.log" 2>/dev/null || true
            fi
        fi
    }

    # DIAGNOSTIC: Doctor post-execution analysis
    if [[ "$agent_name" == "doctor" ]]; then
        local end_diag=$(date +%s)
        local dur=$((end_diag - start_time))
        echo "[$(date '+%H:%M:%S')] Execution completed in ${dur}s" >> "$PANTHEON_LOGS_DIR/doctor_diagnostic.log"
        echo "Response size: $(wc -c < "$response_file" 2>/dev/null || echo 0) bytes" >> "$PANTHEON_LOGS_DIR/doctor_diagnostic.log"
        echo "Response lines: $(wc -l < "$response_file" 2>/dev/null || echo 0)" >> "$PANTHEON_LOGS_DIR/doctor_diagnostic.log"
        echo "Markers found:" >> "$PANTHEON_LOGS_DIR/doctor_diagnostic.log"
        echo "  [DONE]: $(grep -c '\[DONE' "$response_file" 2>/dev/null || echo 0)" >> "$PANTHEON_LOGS_DIR/doctor_diagnostic.log"
        echo "  [BUG]: $(grep -c '\[BUG\]' "$response_file" 2>/dev/null || echo 0)" >> "$PANTHEON_LOGS_DIR/doctor_diagnostic.log"
        echo "  [MSG]: $(grep -c '\[MSG:' "$response_file" 2>/dev/null || echo 0)" >> "$PANTHEON_LOGS_DIR/doctor_diagnostic.log"
        echo "  [ARTIFACT]: $(grep -c '\[ARTIFACT:' "$response_file" 2>/dev/null || echo 0)" >> "$PANTHEON_LOGS_DIR/doctor_diagnostic.log"
        echo "  [TEST_RESULTS]: $(grep -c '\[TEST_RESULTS\]' "$response_file" 2>/dev/null || echo 0)" >> "$PANTHEON_LOGS_DIR/doctor_diagnostic.log"
        echo "========================================" >> "$PANTHEON_LOGS_DIR/doctor_diagnostic.log"
    fi
    
    local end_time=$(date +%s)
    local duration=$((end_time - start_time))
    
    # -------------------------------------------------------------------------
    # STEP 7: Check for rate limiting
    # -------------------------------------------------------------------------
    # NOTE: Be careful with pattern matching - don't false positive on code
    # that discusses rate limiting as a feature. Look for API-specific phrases.
    if grep -qi "you.ve hit your.*limit\|your.*limit.*resets\|too many requests.*try again\|rate limit exceeded\|API rate limit" "$response_file" 2>/dev/null; then
        log_rate_limit "$agent_name"
        touch "$PANTHEON_STATE_DIR/rate_limit.flag"
        return 1
    fi
    
    # -------------------------------------------------------------------------
    # STEP 8: Process response and extract markers
    # -------------------------------------------------------------------------
    process_agent_response "$agent_name" "$response_file"

    # Update agent status
    increment_agent_cycles "$agent_name"

    # Track agent health and token usage (self-healing metrics)
    track_agent_health "$agent_name" "$duration" 2>/dev/null || true
    log_token_usage "$agent_name" 2>/dev/null || true

    log_success "$agent_name complete (${duration}s)"
    return 0
}

# =============================================================================
# RESPONSE PROCESSING
# =============================================================================

process_agent_response() {
    local agent_name=$1
    local response_file=$2

    if [[ ! -f "$response_file" ]]; then
        return
    fi

    # -------------------------------------------------------------------------
    # FIXED: Use perl for multi-line pattern matching + process substitution
    #
    # Two bugs fixed:
    # 1. Original grep patterns failed on multi-line content
    # 2. Pipe | while runs in subshell, causing file writes to be lost
    #    Solution: Use process substitution < <(command) instead
    # -------------------------------------------------------------------------

    # Extract tasks (multi-line support)
    while IFS= read -r task; do
        local clean_task=$(echo "$task" | head -1 | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        [[ -n "$clean_task" ]] && add_task "$clean_task" "$agent_name"
    done < <(perl -0777 -ne 'while (/\[TASK\](.*?)\[\/TASK\]/gs) { print "$1\n"; }' "$response_file" 2>/dev/null)

    # Extract high priority tasks
    while IFS= read -r task; do
        local clean_task=$(echo "$task" | head -1 | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        [[ -n "$clean_task" ]] && add_task "$clean_task" "$agent_name" "high"
    done < <(perl -0777 -ne 'while (/\[TASK:high\](.*?)\[\/TASK\]/gs) { print "$1\n"; }' "$response_file" 2>/dev/null)

    # Extract messages (multi-line support) - CRITICAL FIX
    while IFS= read -r -d $'\0' target && IFS= read -r -d $'\0' content; do
        [[ -n "$target" && -n "$content" ]] && send_message "$agent_name" "$target" "$content"
    done < <(perl -0777 -ne 'while (/\[MSG:(\w+)\](.*?)\[\/MSG\]/gs) { print "$1\x00$2\x00"; }' "$response_file" 2>/dev/null)

    # Extract spawn requests (only weaver and djinn have spawn privileges)
    # NOTE: Aletheia removed from internal agents - she runs externally and doesn't spawn
    if [[ "$agent_name" == "weaver" || "$agent_name" == "djinn" ]]; then
        # Standard spawn format: [SPAWN]task[/SPAWN]
        while IFS= read -r spawn; do
            local clean_spawn=$(echo "$spawn" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
            [[ -n "$clean_spawn" ]] && queue_spawn "$agent_name" "$clean_spawn"
        done < <(perl -0777 -ne 'while (/\[SPAWN\](.*?)\[\/SPAWN\]/gs) { print "$1\n"; }' "$response_file" 2>/dev/null)
    fi

    # Extract artifacts (single line - process substitution still better)
    # Note: grep returns 1 when no matches, so add || true to prevent set -e exit
    while read -r artifact; do
        [[ -n "$artifact" ]] && register_artifact "$artifact" "$agent_name"
    done < <(grep -oP '(?<=\[ARTIFACT:)[^\]]+' "$response_file" 2>/dev/null || true)

    # -------------------------------------------------------------------------
    # TASK COMPLETION - Mark tasks as done
    # -------------------------------------------------------------------------
    # Format: [DONE:task_id] or [DONE]task description[/DONE]
    # This was MISSING - tasks were never being marked complete!
    # -------------------------------------------------------------------------

    # By task ID
    while read -r task_id; do
        [[ -n "$task_id" ]] && complete_task "$task_id"
    done < <(grep -oP '(?<=\[DONE:)[^\]]+' "$response_file" 2>/dev/null || true)

    # By description match (fuzzy with keyword extraction)
    while IFS= read -r task_desc; do
        local clean_desc=$(echo "$task_desc" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | head -c 100)
        if [[ -n "$clean_desc" ]]; then
            # DIAGNOSTIC: Log what we're trying to match
            echo "[$(date +%H:%M:%S)] DONE marker: '$clean_desc'" >> "$PANTHEON_LOGS_DIR/task_matching.log"

            # Extract keywords for broader matching (3+ char words)
            local keywords=$(echo "$clean_desc" | tr '[:upper:]' '[:lower:]' | grep -oE '[a-z]{3,}' | head -5 | tr '\n' '|' | sed 's/|$//')

            # Try exact substring match first
            local task_id=$(jq -r --arg desc "$clean_desc" \
                '.[] | select(.status=="pending") | select(.description | test($desc; "i")) | .id' \
                "$PANTHEON_STATE_DIR/task_board.json" 2>/dev/null | head -1)

            # If no match, try keyword matching (any 2+ keywords)
            if [[ -z "$task_id" || "$task_id" == "null" ]] && [[ -n "$keywords" ]]; then
                task_id=$(jq -r --arg kw "$keywords" \
                    '.[] | select(.status=="pending") | select(.description | test($kw; "i")) | .id' \
                    "$PANTHEON_STATE_DIR/task_board.json" 2>/dev/null | head -1)
                echo "[$(date +%H:%M:%S)]   Keyword match ($keywords) -> $task_id" >> "$PANTHEON_LOGS_DIR/task_matching.log"
            else
                echo "[$(date +%H:%M:%S)]   Exact match -> $task_id" >> "$PANTHEON_LOGS_DIR/task_matching.log"
            fi

            if [[ -n "$task_id" && "$task_id" != "null" ]]; then
                complete_task "$task_id"
                echo "[$(date +%H:%M:%S)]   COMPLETED: $task_id" >> "$PANTHEON_LOGS_DIR/task_matching.log"
            else
                echo "[$(date +%H:%M:%S)]   NO MATCH FOUND" >> "$PANTHEON_LOGS_DIR/task_matching.log"
            fi
        fi
    done < <(perl -0777 -ne 'while (/\[DONE\](.*?)\[\/DONE\]/gs) { print "$1\n"; }' "$response_file" 2>/dev/null)

    # Check for project completion (only Luminary can declare completion)
    # FIXED: Match [COMPLETE] at start of line to avoid false positives like
    # "I will NOT declare [COMPLETE] until..."
    if grep -qE '^\[COMPLETE\]' "$response_file" 2>/dev/null; then
        if [[ "$agent_name" == "luminary" ]]; then
            log_info "Luminary declared [COMPLETE] - will verify at end of cycle"
            mark_agent_complete "$agent_name"
        else
            log_warning "$agent_name attempted [COMPLETE] - only Luminary can declare completion"
        fi
    fi

    # -------------------------------------------------------------------------
    # NOTE: Aletheia special markers removed - she now runs EXTERNALLY
    # via ./pantheon.sh aletheia and can restart with ./pantheon.sh resume
    # -------------------------------------------------------------------------
}

# =============================================================================
# CYCLE EXECUTION
# =============================================================================
#
# A cycle runs through all agents in order:
# 1. LUMINARY - Strategic assessment (always runs)
# 2. ARCHITECT - Task decomposition (conditional)
# 3. WEAVER - Parallel coordination (conditional)
# 4. DJINN - Implementation (conditional)
# 5. DOCTOR - Testing (conditional)
# 6. ALETHEIA - Now runs EXTERNALLY via ./pantheon.sh aletheia (removed from internal loop)
# 7. SCRIBE - Documentation (conditional)
# 8. CROCODILE - State maintenance (always runs)
#
# After agents, process spawn queue (with budget).
# Aletheia can force cycle continuation via [OVERRIDE] marker.
#
# =============================================================================

run_cycle() {
    local cycle=$1
    local max_cycles=$2
    local cycle_start=$(date +%s)
    
    log_header "CYCLE $cycle / $max_cycles"
    
    # Reset spawn budget for this cycle
    reset_spawn_budget

    # -------------------------------------------------------------------------
    # PRE-CYCLE HEALTH CHECK (Self-Healing)
    # -------------------------------------------------------------------------
    if ! pre_cycle_health_check; then
        log_warning "Health check found issues - attempting auto-fixes"
        # If compilation still fails after auto-fix, the priority directive is set
        # and Djinn will see it in context
    fi

    # Track metrics
    local agents_run=0
    local agents_skipped=0

    # -------------------------------------------------------------------------
    # AGENT EXECUTION ORDER
    # -------------------------------------------------------------------------
    # Note: Order matters! Luminary sets direction, others follow.
    
    # NOTE: Aletheia removed from internal loop - she runs EXTERNALLY via ./pantheon.sh aletheia
    local agents=(luminary architect weaver djinn doctor scribe crocodile)
    
    for agent in "${agents[@]}"; do
        # Build appropriate directive based on cycle phase
        local directive
        case "$agent" in
            luminary)
                directive="Assess project state. Synthesize direction for cycle $cycle. Check for completion."
                ;;
            architect)
                directive="Review structure. Decompose any large tasks. Define interfaces."
                ;;
            weaver)
                directive="Identify parallel work opportunities. Spawn workers as needed (budget: $(get_spawn_budget))."
                ;;
            djinn)
                directive="Implement pending tasks. Write production code. Spawn for complex work if needed."
                ;;
            doctor)
                directive="Test new artifacts. Diagnose any bugs. Write regression tests."
                ;;
            # NOTE: aletheia removed - runs externally via ./pantheon.sh aletheia
            scribe)
                directive="Document completed work. Update README and changelog."
                ;;
            crocodile)
                directive="Compact state. Archive completed tasks. Create checkpoint if needed."
                ;;
        esac
        
        if run_agent "$agent" "$directive"; then
            # Note: ((expr++)) returns 1 when expr is 0, which triggers set -e
            # Use || true to prevent exit
            ((agents_run++)) || true
        else
            # Check if we hit rate limit
            if [[ -f "$PANTHEON_STATE_DIR/rate_limit.flag" ]]; then
                log_error "Rate limit hit - stopping cycle"
                return 2
            fi
            ((agents_skipped++)) || true
        fi

        # CRITICAL: Process spawns IMMEDIATELY after Weaver finishes
        # This enables parallel work alongside Djinn instead of after
        if [[ "$agent" == "weaver" ]]; then
            local queue_size=$(jq 'length' "$PANTHEON_STATE_DIR/spawn_queue.json" 2>/dev/null || echo 0)
            if [[ $queue_size -gt 0 ]]; then
                log_info "Processing $queue_size spawns IN PARALLEL with upcoming agents..."
                # Launch spawns in background - they run ALONGSIDE Djinn
                process_spawn_queue &
                SPAWN_PID=$!
                log_info "Spawn processing started in background (PID: $SPAWN_PID)"
            fi
        fi
    done

    # Wait for any background spawn processing to complete
    if [[ -n "${SPAWN_PID:-}" ]]; then
        log_info "Waiting for parallel spawn workers to complete..."
        wait $SPAWN_PID 2>/dev/null || true
        log_success "Parallel spawn processing complete"
    fi

    # -------------------------------------------------------------------------
    # SPAWN PROCESSING (for any remaining in queue)
    # -------------------------------------------------------------------------
    local spawns_before=$(jq 'length' "$PANTHEON_STATE_DIR/spawn_queue.json" 2>/dev/null || echo 0)
    if [[ $spawns_before -gt 0 ]]; then
        log_info "Processing $spawns_before remaining spawns..."
        process_spawn_queue
    fi
    local spawns_after=$(jq 'length' "$PANTHEON_STATE_DIR/spawn_queue.json" 2>/dev/null || echo 0)
    local spawns_processed=$((spawns_before - spawns_after))
    
    # -------------------------------------------------------------------------
    # CYCLE METRICS
    # -------------------------------------------------------------------------
    local cycle_end=$(date +%s)
    local duration=$((cycle_end - cycle_start))
    log_cycle_metrics "$cycle" "$agents_run" "$agents_skipped" "$spawns_processed" "$duration"
    
    # -------------------------------------------------------------------------
    # COMPLETION CHECK
    # -------------------------------------------------------------------------
    if check_completion; then
        log_success "Project marked COMPLETE by Luminary"
        return 0
    fi
    
    return 1
}

check_completion() {
    # Check if Luminary has declared completion
    local luminary_complete=$(jq -r '.luminary.complete // "false"' \
        "$PANTHEON_STATE_DIR/agent_status.json" 2>/dev/null)

    if [[ "$luminary_complete" == "true" ]]; then
        log_info "Luminary declared [COMPLETE] - running mandatory verification..."

        # =====================================================================
        # MANDATORY QUALITY GATE - NO HALF-FINISHED PRODUCTS
        # =====================================================================
        # This gate CANNOT be bypassed. A project is NOT complete until:
        # 1. It builds
        # 2. Tests compile and pass
        # 3. Core features actually work (not stubs/unimplemented)
        # 4. No critical tasks remain
        # =====================================================================

        local gate_failures=0
        local failure_reasons=""

        # -------------------------------------------------------------------------
        # CHECK 1: No critical/high tasks pending
        # -------------------------------------------------------------------------
        local critical_pending=$(jq '[.[] | select(.status=="pending") | select(.priority=="critical" or .priority=="high")] | length' \
            "$PANTHEON_STATE_DIR/task_board.json" 2>/dev/null || echo 0)

        if [[ "$critical_pending" != "0" ]]; then
            log_warning "GATE FAILED: $critical_pending critical/high tasks still pending"
            failure_reasons="${failure_reasons}\n- $critical_pending critical/high priority tasks not complete"
            ((gate_failures++))
        fi

        # -------------------------------------------------------------------------
        # CHECK 2: Build verification (must compile)
        # -------------------------------------------------------------------------
        log_info "Running build verification..."
        if ! verify_build > "$PANTHEON_LOGS_DIR/build_verification.log" 2>&1; then
            log_warning "GATE FAILED: Build does not compile"
            failure_reasons="${failure_reasons}\n- Build failed (see logs/build_verification.log)"
            ((gate_failures++))
        fi

        # -------------------------------------------------------------------------
        # CHECK 3: Test compilation (tests must at least compile)
        # -------------------------------------------------------------------------
        log_info "Running test compilation check..."
        local test_compile_output=""
        local test_compile_ok=true

        local project_dir=$(get_project_dir)
        local build_system=$(detect_build_system)

        case "$build_system" in
            rust)
                test_compile_output=$(cd "$project_dir" && cargo test --no-run 2>&1) || test_compile_ok=false
                ;;
            python)
                test_compile_output=$(cd "$project_dir" && python -m py_compile tests/*.py 2>&1) || test_compile_ok=false
                ;;
            node)
                # Node tests generally don't need pre-compilation
                test_compile_ok=true
                ;;
        esac

        if ! $test_compile_ok; then
            log_warning "GATE FAILED: Tests don't compile"
            echo "$test_compile_output" > "$PANTHEON_LOGS_DIR/test_compile.log"
            failure_reasons="${failure_reasons}\n- Tests don't compile (see logs/test_compile.log)"
            ((gate_failures++))
        fi

        # -------------------------------------------------------------------------
        # CHECK 4: Quality gate (no stubs, features work)
        # -------------------------------------------------------------------------
        log_info "Running quality gate..."
        source "$PANTHEON_ROOT/lib/quality.sh"

        if ! run_quality_gate > "$PANTHEON_LOGS_DIR/quality_gate_output.log" 2>&1; then
            log_warning "GATE FAILED: Quality gate did not pass"
            failure_reasons="${failure_reasons}\n- Quality gate failed (see logs/quality_gate.log)"
            ((gate_failures++))
        fi

        # -------------------------------------------------------------------------
        # CHECK 5: Full verification (build + tests + smoke)
        # -------------------------------------------------------------------------
        log_info "Running full verification pipeline..."
        if ! run_full_verification > "$PANTHEON_LOGS_DIR/verification_output.log" 2>&1; then
            log_warning "GATE FAILED: Full verification did not pass"
            failure_reasons="${failure_reasons}\n- Verification failed (see logs/verification_output.log)"
            ((gate_failures++))
        fi

        # =========================================================================
        # GATE DECISION
        # =========================================================================
        if [[ $gate_failures -gt 0 ]]; then
            log_error "=========================================="
            log_error "COMPLETION REJECTED: $gate_failures gate(s) failed"
            log_error "=========================================="
            echo -e "$failure_reasons" | while read -r reason; do
                [[ -n "$reason" ]] && log_warning "  $reason"
            done

            # Reset Luminary's complete flag - project is NOT done
            local updated=$(jq '.luminary.complete = "false"' \
                "$PANTHEON_STATE_DIR/agent_status.json")
            echo "$updated" > "$PANTHEON_STATE_DIR/agent_status.json"

            # Send detailed failure message to Luminary
            send_message "orchestrator" "luminary" \
                "COMPLETION REJECTED - $gate_failures quality gates failed. Project is NOT complete. Failures:$failure_reasons\n\nDo NOT declare [COMPLETE] again until all issues are fixed. Direct agents to fix the issues." \
                "urgent"

            # Also notify Doctor about test/quality issues
            send_message "orchestrator" "doctor" \
                "QUALITY GATE FAILED - Tests don't compile or quality checks failed. Review logs/test_compile.log and logs/quality_gate.log. Fix test compilation errors and any unimplemented features." \
                "urgent"

            # Store gate results for agents to see
            cat > "$PANTHEON_STATE_DIR/gate_results.json" << EOF
{
    "timestamp": "$(date -Iseconds)",
    "luminary_declared_complete": true,
    "gate_passed": false,
    "failures": $gate_failures,
    "reasons": "$(echo -e "$failure_reasons" | tr '\n' '|')"
}
EOF

            return 1
        fi

        # All gates passed!
        log_success "=========================================="
        log_success "ALL QUALITY GATES PASSED"
        log_success "=========================================="
        log_success "Project is genuinely complete and verified"

        cat > "$PANTHEON_STATE_DIR/gate_results.json" << EOF
{
    "timestamp": "$(date -Iseconds)",
    "luminary_declared_complete": true,
    "gate_passed": true,
    "failures": 0,
    "reasons": ""
}
EOF

        return 0
    else
        return 1
    fi
}

# =============================================================================
# MAIN ENTRY POINT
# =============================================================================

main() {
    local project_brief="$1"
    local max_cycles="${2:-$MAX_CYCLES}"
    local resume_mode=false
    local start_cycle=1
    
    # Parse arguments
    if [[ "$1" == "--resume" ]]; then
        resume_mode=true
        max_cycles="${2:-5}"
        shift 2 || true
    fi
    
    # Validate arguments
    if [[ "$resume_mode" == false && -z "$project_brief" ]]; then
        echo "Usage: $0 <project_brief_file> [max_cycles]"
        echo "       $0 --resume [additional_cycles]"
        exit 1
    fi
    
    # -------------------------------------------------------------------------
    # RESUME MODE
    # -------------------------------------------------------------------------
    if [[ "$resume_mode" == true ]]; then
        log_header "RESUMING PANTHEON"
        
        if [[ ! -f "$PANTHEON_STATE_DIR/project_state.md" ]]; then
            log_error "No existing state to resume from"
            exit 1
        fi
        
        start_cycle=$(cat "$PANTHEON_STATE_DIR/cycle_count" 2>/dev/null || echo 1)
        max_cycles=$((start_cycle + max_cycles))
        
        # Clear rate limit flag
        rm -f "$PANTHEON_STATE_DIR/rate_limit.flag" 2>/dev/null || true
        
        log_info "Resuming from cycle $start_cycle (running until $max_cycles)"
        
    # -------------------------------------------------------------------------
    # FRESH START
    # -------------------------------------------------------------------------
    else
        init_pantheon
        
        # Load project brief
        if [[ "$project_brief" == "--interactive" ]]; then
            echo "Enter project brief (Ctrl+D when done):"
            project_brief=$(cat)
            echo "$project_brief" > "$PANTHEON_STATE_DIR/project_brief.md"
        elif [[ -f "$project_brief" ]]; then
            cp "$project_brief" "$PANTHEON_STATE_DIR/project_brief.md"
        else
            echo "$project_brief" > "$PANTHEON_STATE_DIR/project_brief.md"
        fi
        
        # Initialize project state
        cat > "$PANTHEON_STATE_DIR/project_state.md" << STATE
# PROJECT STATE

## Brief
$(cat "$PANTHEON_STATE_DIR/project_brief.md")

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
    fi
    
    # -------------------------------------------------------------------------
    # MAIN EXECUTION LOOP
    # -------------------------------------------------------------------------
    local project_complete=false
    local consecutive_gate_failures=0
    local max_gate_failures="${PANTHEON_MAX_GATE_FAILURES:-5}"  # Max attempts before giving up
    local auto_extend_cycles="${PANTHEON_AUTO_EXTEND:-true}"     # Auto-extend on gate failure

    for ((cycle=start_cycle; cycle<=max_cycles; cycle++)); do
        echo "$cycle" > "$PANTHEON_STATE_DIR/cycle_count"
        echo "$cycle" > "$PANTHEON_STATE_DIR/cycle_count" 2>/dev/null || true

        # CRITICAL: Protect run_cycle from set -e
        # run_cycle returns 0=complete, 1=continue, 2=rate_limit
        # Without || true, set -e exits on return 1
        local cycle_result=0
        run_cycle "$cycle" "$max_cycles" || cycle_result=$?

        log_info "Cycle $cycle returned: $cycle_result"

        # =====================================================================
        # NOTE: Aletheia force_continuation removed - she now runs EXTERNALLY
        # via ./pantheon.sh aletheia and restarts with ./pantheon.sh resume
        # =====================================================================

        if [[ $cycle_result -eq 0 ]]; then
            project_complete=true
            log_info "Breaking - project complete and verified"
            break
        elif [[ $cycle_result -eq 2 ]]; then
            # Rate limit - exit gracefully
            log_error "Rate limit detected - pausing orchestrator"
            log_info "Resume with: $0 --resume $((max_cycles - cycle))"
            exit 2
        fi

        # =====================================================================
        # AUTO-EXTENSION: Don't give up if verification keeps failing
        # =====================================================================
        # Check if we're near the end but verification is failing
        if [[ $cycle -ge $((max_cycles - 1)) ]]; then
            local gate_result=$(jq -r '.gate_passed // "true"' "$PANTHEON_STATE_DIR/gate_results.json" 2>/dev/null)

            if [[ "$gate_result" == "false" ]]; then
                ((consecutive_gate_failures++))

                if [[ "$auto_extend_cycles" == "true" ]] && [[ $consecutive_gate_failures -lt $max_gate_failures ]]; then
                    log_warning "=========================================="
                    log_warning "QUALITY GATE FAILED - EXTENDING CYCLES"
                    log_warning "=========================================="
                    log_warning "Gate failure $consecutive_gate_failures of $max_gate_failures"
                    log_warning "Adding 2 more cycles to fix issues..."

                    # Extend max_cycles
                    max_cycles=$((max_cycles + 2))

                    # Notify Luminary about the extension
                    send_message "orchestrator" "luminary" \
                        "CYCLES EXTENDED: Quality gate failed, cycles extended to $max_cycles. DO NOT declare [COMPLETE] until issues are fixed." \
                        "urgent"
                else
                    log_error "=========================================="
                    log_error "MAX GATE FAILURES REACHED ($max_gate_failures)"
                    log_error "=========================================="
                    log_error "Project cannot pass quality gates after $consecutive_gate_failures attempts"
                    log_error "Manual intervention required"
                fi
            else
                # Reset failure counter on success
                consecutive_gate_failures=0
            fi
        fi

        log_info "Continuing to cycle $((cycle + 1))..."
        # Brief pause between cycles
        sleep 1
    done
    
    # -------------------------------------------------------------------------
    # FINAL SYNTHESIS
    # -------------------------------------------------------------------------
    if [[ "$project_complete" == true ]]; then
        log_header "FINAL SYNTHESIS"
        
        run_agent "luminary" "Produce final synthesis and deliverables manifest"
        run_agent "scribe" "Produce final documentation package"
        run_agent "crocodile" "Final state compaction and archive"
        
        log_success "PANTHEON COMPLETE"
    else
        log_warning "Max cycles reached without completion"
        log_info "Resume with: $0 --resume [cycles]"
    fi
    
    # Output summary
    echo ""
    echo "Project: $PANTHEON_PROJECTS_DIR/"
    echo "Logs: $PANTHEON_LOGS_DIR/"
    echo "State: $PANTHEON_STATE_DIR/"
}

# Run if executed directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
