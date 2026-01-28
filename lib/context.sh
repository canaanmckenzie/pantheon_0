#!/bin/bash
# =============================================================================
# CONTEXT BUILDER LIBRARY
# =============================================================================
#
# WHAT THIS DOES:
# ---------------
# Instead of dumping ALL state to EVERY agent, we build tailored context
# packages. Each agent gets only the information relevant to their role.
#
# WHY THIS MATTERS:
# -----------------
# The original system injected ~2000+ tokens of context to every agent:
#   - Full task board (even if agent doesn't manage tasks)
#   - Full artifact registry (even if agent doesn't create artifacts)
#   - Full message queue (even if no messages for this agent)
#   - Previous 100 lines of response (often redundant)
#
# By tailoring context, we can reduce input tokens by 40-60%.
#
# THE PHILOSOPHY:
# ---------------
# Each agent has:
#   1. ALWAYS NEEDED: Their role prompt, project brief, current phase
#   2. ROLE-SPECIFIC: Data relevant to their function
#   3. OPTIONAL: Additional context only when relevant
#
# Example reductions:
#   - Crocodile needs full state (for compaction) but not code artifacts
#   - Scribe needs artifact list but not full task board details
#   - Weaver needs task board but not decision history
#
# =============================================================================

# Ensure PANTHEON_ROOT is set
PANTHEON_ROOT="${PANTHEON_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
# Use .pantheon/ structure (fallback if not set)
PANTHEON_STATE_DIR="${PANTHEON_STATE_DIR:-$PANTHEON_ROOT/.pantheon/state}"
PANTHEON_LOGS_DIR="${PANTHEON_LOGS_DIR:-$PANTHEON_ROOT/.pantheon/logs}"
PANTHEON_SPAWN_DIR="${PANTHEON_SPAWN_DIR:-$PANTHEON_ROOT/.pantheon/spawn}"
PANTHEON_ARTIFACTS_DIR="${PANTHEON_ARTIFACTS_DIR:-$PANTHEON_ROOT/.pantheon/artifacts}"
PANTHEON_PROJECTS_DIR="${PANTHEON_PROJECTS_DIR:-$PANTHEON_ROOT/projects}"

# =============================================================================
# STATE SUMMARIZATION
# =============================================================================
#
# Instead of passing raw JSON, we create human-readable summaries.
# This is more token-efficient AND easier for the model to parse.
#
# =============================================================================

summarize_task_board() {
    local task_file="$PANTHEON_STATE_DIR/task_board.json"
    local detail_level=${1:-"summary"}  # "summary", "full", "minimal"
    
    if [[ ! -f "$task_file" ]]; then
        echo "No tasks yet."
        return
    fi
    
    local total=$(jq 'length' "$task_file" 2>/dev/null || echo 0)
    local pending=$(jq '[.[] | select(.status=="pending")] | length' "$task_file" 2>/dev/null || echo 0)
    local in_progress=$(jq '[.[] | select(.status=="in_progress")] | length' "$task_file" 2>/dev/null || echo 0)
    local complete=$(jq '[.[] | select(.status=="complete")] | length' "$task_file" 2>/dev/null || echo 0)
    
    case "$detail_level" in
        minimal)
            echo "Tasks: $pending pending, $in_progress active, $complete done"
            ;;
        summary)
            echo "## Task Summary"
            echo "- Total: $total"
            echo "- Pending: $pending"
            echo "- In Progress: $in_progress"  
            echo "- Complete: $complete"
            echo ""
            
            # Show only pending/in-progress tasks (not completed)
            if [[ $pending -gt 0 || $in_progress -gt 0 ]]; then
                echo "### Active Tasks"
                jq -r '.[] | select(.status=="pending" or .status=="in_progress") | "- [\(.status)] \(.description | .[0:80])"' "$task_file" 2>/dev/null
            fi
            ;;
        full)
            # Only for agents that need full detail (Architect, Luminary)
            echo "## Full Task Board"
            cat "$task_file"
            ;;
    esac
}

summarize_artifacts() {
    local artifact_file="$PANTHEON_STATE_DIR/artifacts.json"
    local detail_level=${1:-"summary"}
    
    if [[ ! -f "$artifact_file" ]]; then
        echo "No artifacts yet."
        return
    fi
    
    local count=$(jq 'length' "$artifact_file" 2>/dev/null || echo 0)
    
    case "$detail_level" in
        minimal)
            echo "Artifacts: $count files created"
            ;;
        summary)
            echo "## Artifacts ($count files)"
            # Group by type/directory
            jq -r '.[].path' "$artifact_file" 2>/dev/null | sort | while read path; do
                echo "- $path"
            done | tail -20  # Limit to recent 20
            ;;
        full)
            cat "$artifact_file"
            ;;
    esac
}

summarize_messages() {
    local agent_name=$1
    local msg_file="$PANTHEON_STATE_DIR/message_queue.json"
    
    if [[ ! -f "$msg_file" ]]; then
        echo "No messages."
        return
    fi
    
    # Get only undelivered messages for this agent
    local messages=$(jq --arg to "$agent_name" \
        '[.[] | select(.to == $to and .delivered == false)]' "$msg_file" 2>/dev/null)
    
    local count=$(echo "$messages" | jq 'length' 2>/dev/null || echo 0)
    
    if [[ "$count" == "0" ]]; then
        echo "No pending messages."
    else
        echo "## Messages for You ($count)"
        echo "$messages" | jq -r '.[] | "[\(.priority)] From \(.from): \(.content | .[0:100])"' 2>/dev/null
    fi
}

summarize_spawns() {
    local registry="$PANTHEON_STATE_DIR/spawn_registry.json"
    local queue="$PANTHEON_STATE_DIR/spawn_queue.json"
    
    local completed=$(jq 'length' "$registry" 2>/dev/null || echo 0)
    local queued=$(jq 'length' "$queue" 2>/dev/null || echo 0)
    
    echo "## Spawn Status"
    echo "- Completed workers: $completed"
    echo "- Queued spawns: $queued"
    
    if [[ $queued -gt 0 ]]; then
        echo ""
        echo "### Pending Spawns"
        jq -r '.[] | "- \(.specialization): \(.task | .[0:60])..."' "$queue" 2>/dev/null
    fi
}

get_project_summary() {
    local state_file="$PANTHEON_STATE_DIR/project_state.md"
    
    if [[ -f "$state_file" ]]; then
        # Extract just the key sections, not the full file
        head -50 "$state_file"
    else
        echo "Project not initialized."
    fi
}

get_cycle_info() {
    local cycle=$(cat "$PANTHEON_STATE_DIR/cycle_count" 2>/dev/null || echo 0)
    local max_cycles=${PANTHEON_MAX_CYCLES:-10}
    echo "Cycle $cycle of $max_cycles"
}

# =============================================================================
# AGENT-SPECIFIC CONTEXT BUILDERS
# =============================================================================
#
# Each agent gets a tailored context package. The philosophy:
#
# LUMINARY: Needs overview of everything (strategic decisions)
#   - Full project state
#   - Task summary with priorities
#   - Agent status
#   - Blockers/issues
#
# ARCHITECT: Needs structural information
#   - Project brief
#   - Full task board (for decomposition)
#   - Artifact structure
#   - Dependencies
#
# WEAVER: Needs coordination data
#   - Task board (what needs parallel work)
#   - Spawn status
#   - Integration points
#   - Minimal code context
#
# DJINN: Needs implementation context
#   - Current task to implement
#   - Relevant artifacts
#   - Interface definitions
#   - Minimal state
#
# DOCTOR: Needs testing context
#   - Artifacts to test
#   - Existing test files
#   - Bug reports
#   - Code coverage info
#
# SCRIBE: Needs documentation context
#   - Completed work
#   - Decision log
#   - Artifact list
#   - Changelog
#
# CROCODILE: Needs state management context
#   - Full state files (for compaction)
#   - Metrics
#   - Archive status
#
# =============================================================================

build_context_for_luminary() {
    local directive="$1"

    # Source verification library
    source "$PANTHEON_ROOT/lib/directories.sh" 2>/dev/null || true
    source "$PANTHEON_ROOT/lib/verify.sh" 2>/dev/null || true
    local project_name=$(detect_project_name)
    local project_dir=$(get_project_dir)

    cat << CONTEXT
# LUMINARY CONTEXT - Cycle $(get_cycle_info)

## Your Directive
$directive

## Project Information
**Project**: $project_name
**Directory**: $project_dir

## Project Overview
$(get_project_summary)

## Task Status
$(summarize_task_board "summary")

## Agent Activity
$(jq -r 'to_entries[] | "- \(.key): \(if .value.complete == "true" then "COMPLETE" else "ACTIVE" end)"' \
    "$PANTHEON_STATE_DIR/agent_status.json" 2>/dev/null || echo "No agent data")

## VERIFICATION STATUS (CRITICAL FOR COMPLETION)
$(get_verification_status 2>/dev/null || echo "**NOT YET RUN** - Cannot declare [COMPLETE] without passing verification")

## Messages
$(summarize_messages "luminary")

## Spawn Activity
$(summarize_spawns)

## Recent Decisions
$(tail -10 "$PANTHEON_STATE_DIR/decisions.json" 2>/dev/null | jq -r '.[] | "- \(.decision)"' 2>/dev/null || echo "None yet")

## COMPLETION RULES
You may ONLY declare [COMPLETE] when:
1. All critical tasks are marked done
2. **Verification has PASSED** (build, tests, smoke tests)
3. The project actually works (not just claimed to work)

If verification has not passed, direct Doctor to run tests and fix issues.
CONTEXT
}

build_context_for_architect() {
    local directive="$1"
    
    cat << CONTEXT
# ARCHITECT CONTEXT - Cycle $(get_cycle_info)

## Your Directive
$directive

## Project Brief
$(cat "$PANTHEON_STATE_DIR/project_brief.md" 2>/dev/null | head -100)

## Task Board (Full)
$(summarize_task_board "full")

## Artifact Structure
$(summarize_artifacts "summary")

## Messages
$(summarize_messages "architect")

## CRITICAL: Directory Structure
- Project goes in: $PANTHEON_PROJECTS_DIR/\$PROJECT_NAME/
- Source code: $PANTHEON_PROJECTS_DIR/\$PROJECT_NAME/src/
- Tests: $PANTHEON_PROJECTS_DIR/\$PROJECT_NAME/tests/
- Docs: $PANTHEON_PROJECTS_DIR/\$PROJECT_NAME/docs/

DO NOT create files in:
- $PANTHEON_ROOT/ (the Pantheon root - only for system files)
- $PANTHEON_ROOT/.pantheon/ (system internal)

When creating architecture documents, put them in:
- $PANTHEON_PROJECTS_DIR/\$PROJECT_NAME/docs/ARCHITECTURE.md
- NOT at Pantheon root!
CONTEXT
}

build_context_for_weaver() {
    local directive="$1"
    
    cat << CONTEXT
# WEAVER CONTEXT - Cycle $(get_cycle_info)

## Your Directive
$directive

## Tasks Available for Parallel Work
$(summarize_task_board "summary")

## Spawn Status
$(summarize_spawns)

## Current Artifacts
$(summarize_artifacts "minimal")

## Messages
$(summarize_messages "weaver")

## Spawn Budget
Maximum spawns this cycle: ${PANTHEON_MAX_SPAWNS_PER_CYCLE:-3}
CONTEXT
}

build_context_for_djinn() {
    local directive="$1"

    # Source directory library for dynamic paths
    source "$PANTHEON_ROOT/lib/directories.sh" 2>/dev/null || true
    local project_name=$(detect_project_name)
    local project_dir=$(get_project_dir)

    cat << CONTEXT
# DJINN CONTEXT - Cycle $(get_cycle_info)

## Your Directive
$directive

## Active Tasks for Implementation
$(jq -r '.[] | select(.status=="pending" or .status=="in_progress") | select(.type=="implementation" or .type=="feature" or .type==null) | "- \(.description)"' \
    "$PANTHEON_STATE_DIR/task_board.json" 2>/dev/null || echo "No implementation tasks")

## Existing Artifacts (for context)
$(summarize_artifacts "summary")

## Messages
$(summarize_messages "djinn")

## CRITICAL: Working Directories
**Project Name**: $project_name
**Project Directory**: $project_dir

ALL source code MUST go in: $project_dir/
- Source files: $project_dir/src/
- Tests: $project_dir/tests/
- Docs: $project_dir/docs/
- Config: $project_dir/

DO NOT create files or directories in:
- The Pantheon root directory ($PANTHEON_ROOT/)
- $PANTHEON_ROOT/.pantheon/ (system internal)

The project directory IS inside $PANTHEON_PROJECTS_DIR/$project_name/

## Spawn Budget
Maximum spawns this cycle: ${PANTHEON_MAX_SPAWNS_PER_CYCLE:-3}
CONTEXT
}

build_context_for_doctor() {
    local directive="$1"

    # Source directory library for dynamic paths
    source "$PANTHEON_ROOT/lib/directories.sh" 2>/dev/null || true
    source "$PANTHEON_ROOT/lib/verify.sh" 2>/dev/null || true
    local project_name=$(detect_project_name)
    local project_dir=$(get_project_dir)
    local build_system=$(detect_build_system)

    # Pre-flight: Check compilation status (critical for self-healing)
    local build_output=""
    local build_status="unknown"
    if [[ -n "$project_dir" ]] && [[ -d "$project_dir" ]]; then
        case "$build_system" in
            rust)
                if [[ -f "$project_dir/Cargo.toml" ]]; then
                    build_output=$(cd "$project_dir" && cargo check 2>&1 || true)
                    if echo "$build_output" | grep -q "error\[E"; then
                        build_status="FAILED"
                    elif echo "$build_output" | grep -q "Finished\|Checking"; then
                        build_status="OK"
                    fi
                fi
                ;;
            node)
                if [[ -f "$project_dir/package.json" ]]; then
                    build_output=$(cd "$project_dir" && npm run build 2>&1 || true)
                    if echo "$build_output" | grep -qi "error"; then
                        build_status="FAILED"
                    else
                        build_status="OK"
                    fi
                fi
                ;;
            python)
                build_status="OK"  # Python doesn't have compilation
                ;;
        esac
    fi

    cat << CONTEXT
# DOCTOR CONTEXT - Cycle $(get_cycle_info)

## Your Directive
$directive

## Project Information
**Project**: $project_name
**Directory**: $project_dir
**Build System**: $build_system

## COMPILATION STATUS: $build_status
$(if [[ "$build_status" == "FAILED" ]]; then
    echo "**CRITICAL: Code does not compile. Fix compilation errors BEFORE running tests.**"
    echo ""
    echo "\`\`\`"
    echo "$build_output" | grep -A2 "^error" | head -40
    echo "\`\`\`"
    echo ""
    echo "Send these errors to Djinn: [MSG:djinn]Fix compilation errors in $project_dir[/MSG]"
fi)

## Verification Status
$(get_verification_status 2>/dev/null || echo "Verification not yet run")

## YOUR TESTING TASKS (Mark with [DONE:id] when complete)
$(jq -r '.[] | select(.status=="pending" or .status=="in_progress") | select(.description | test("test|verify|diagnose|debug|coverage"; "i")) | "- ID: \(.id)\n  Task: \(.description | .[0:120])\n  Priority: \(.priority // "normal")\n"' \
    "$PANTHEON_STATE_DIR/task_board.json" 2>/dev/null || echo "No testing tasks")

## Artifacts Requiring Testing
$(jq -r '.[] | select(.tested != true) | "- \(.path) (by \(.creator))"' \
    "$PANTHEON_STATE_DIR/artifacts.json" 2>/dev/null || echo "No untested artifacts")

## Existing Test Files
$(find "$project_dir/tests" -name "*test*" -o -name "test_*" 2>/dev/null | head -20 || echo "No test files found in $project_dir/tests")

## Messages
$(summarize_messages "doctor")

## CRITICAL: You Must Actually Run Tests
Do NOT just mark tasks [DONE] - actually run the tests:
- For Rust: \`cargo test\` in $project_dir
- For Node: \`npm test\` in $project_dir
- For Python: \`pytest\` in $project_dir

Report actual test output, not just claims of completion.
CONTEXT
}

build_context_for_aletheia() {
    local directive="$1"

    # Source libraries for verification
    source "$PANTHEON_ROOT/lib/directories.sh" 2>/dev/null || true
    source "$PANTHEON_ROOT/lib/verify.sh" 2>/dev/null || true
    local project_name=$(detect_project_name)
    local project_dir=$(get_project_dir)
    local build_system=$(detect_build_system)

    # Check Luminary's completion status
    local luminary_complete=$(jq -r '.luminary.complete // "false"' \
        "$PANTHEON_STATE_DIR/agent_status.json" 2>/dev/null)

    # Run stub detection
    local stub_count=0
    local stub_results=""
    if [[ -d "$project_dir/src" ]]; then
        stub_results=$(grep -rn "unimplemented!()\|todo!()\|panic!.*not.*implement" "$project_dir/src" 2>/dev/null || true)
        stub_count=$(echo "$stub_results" | grep -c . || echo 0)
    fi

    # Get gate results if they exist
    local gate_results=""
    if [[ -f "$PANTHEON_STATE_DIR/gate_results.json" ]]; then
        gate_results=$(cat "$PANTHEON_STATE_DIR/gate_results.json")
    fi

    cat << CONTEXT
# ALETHEIA CONTEXT - Cycle $(get_cycle_info)

## Your Directive
$directive

## THE SENTINEL'S DUTY
You are the guardian of truth. Your job is to:
1. Verify all completion claims
2. Detect stubs and incomplete code
3. Override false completions
4. Keep the cycle running until the project is PERFECT

## Luminary Completion Status: $luminary_complete
$(if [[ "$luminary_complete" == "true" ]]; then
    echo "**WARNING**: Luminary has declared [COMPLETE]. You must verify independently."
    echo "Do NOT trust this claim. Run your own verification."
else
    echo "Luminary has not declared completion. Continue monitoring."
fi)

## Project Information
**Project**: $project_name
**Directory**: $project_dir
**Build System**: $build_system

## STUB DETECTION RESULTS
**Stubs Found**: $stub_count
$(if [[ $stub_count -gt 0 ]]; then
    echo "**CRITICAL**: The following stubs MUST be implemented before completion:"
    echo "\`\`\`"
    echo "$stub_results" | head -20
    echo "\`\`\`"
    echo ""
    echo "[MSG:djinn]STUBS DETECTED - Implement these features: $stub_results[/MSG]"
else
    echo "No stubs detected. Good."
fi)

## GATE RESULTS (Previous Verification)
$(if [[ -n "$gate_results" ]]; then
    echo "$gate_results" | jq -r '"Build: \(.build_passed // "unknown")\nTests: \(.tests_passed // "unknown")\nQuality: \(.quality_passed // "unknown")"' 2>/dev/null || echo "Could not parse gate results"
else
    echo "No gate results yet."
fi)

## VERIFICATION COMMANDS
Run these to verify independently:
\`\`\`bash
# Build verification
cd $project_dir && cargo build 2>&1

# Test verification
cd $project_dir && cargo test 2>&1

# Stub detection
grep -rn "unimplemented!()\|todo!()\|panic!.*not.*implement" $project_dir/src/

# Feature smoke test
cd $project_dir && cargo run -- --help
\`\`\`

## Pending Tasks
$(jq '[.[] | select(.status=="pending")] | length' "$PANTHEON_STATE_DIR/task_board.json" 2>/dev/null || echo 0) tasks still pending

## Messages
$(summarize_messages "aletheia")

## YOUR MANDATE
"As long as there are tokens and we haven't hit the limit, keep running the cycle to get ALL features."
- No half measures. No partials. No "good enough".
- If Luminary declared [COMPLETE] but gates failed, use [OVERRIDE] to force continuation.
- The cycle continues until YOU are satisfied.
CONTEXT
}

build_context_for_scribe() {
    local directive="$1"

    cat << CONTEXT
# SCRIBE CONTEXT - Cycle $(get_cycle_info)

## Your Directive
$directive

## Completed Work This Cycle
$(jq -r '.[] | select(.status=="complete") | "- \(.description | .[0:60])"' \
    "$PANTHEON_STATE_DIR/task_board.json" 2>/dev/null | tail -10 || echo "None completed")

## Artifacts to Document
$(summarize_artifacts "summary")

## Decision Log
$(tail -5 "$PANTHEON_STATE_DIR/decisions.json" 2>/dev/null | jq -r '.[] | "- \(.decision): \(.rationale | .[0:50])..."' 2>/dev/null || echo "No decisions")

## Messages
$(summarize_messages "scribe")

## Current Documentation
$(find "$PANTHEON_ROOT"/../ -name "README.md" -o -name "*.md" 2>/dev/null | grep -v node_modules | head -10 || echo "No docs found")
CONTEXT
}

build_context_for_crocodile() {
    local directive="$1"
    
    cat << CONTEXT
# CROCODILE CONTEXT - Cycle $(get_cycle_info)

## Your Directive
$directive

## State Files Status
$(du -h "$PANTHEON_STATE_DIR/"*.json 2>/dev/null | sort -h || echo "No state files")

## Task Metrics
$(summarize_task_board "minimal")

## Message Queue
$(jq 'length' "$PANTHEON_STATE_DIR/message_queue.json" 2>/dev/null || echo 0) messages
$(jq '[.[] | select(.delivered==true)] | length' "$PANTHEON_STATE_DIR/message_queue.json" 2>/dev/null || echo 0) delivered (clearable)

## Artifact Count
$(jq 'length' "$PANTHEON_STATE_DIR/artifacts.json" 2>/dev/null || echo 0) artifacts

## Spawn Registry
$(jq 'length' "$PANTHEON_STATE_DIR/spawn_registry.json" 2>/dev/null || echo 0) completed spawns

## Checkpoint Status
$(ls -la "$PANTHEON_STATE_DIR/checkpoints/" 2>/dev/null | tail -5 || echo "No checkpoints")

## Messages
$(summarize_messages "crocodile")
CONTEXT
}

# =============================================================================
# MAIN CONTEXT BUILDER
# =============================================================================
#
# Entry point for building agent context. Routes to appropriate builder.
#
# =============================================================================

build_context() {
    local agent_name=$1
    local directive="$2"
    
    case "$agent_name" in
        luminary)   build_context_for_luminary "$directive" ;;
        architect)  build_context_for_architect "$directive" ;;
        weaver)     build_context_for_weaver "$directive" ;;
        djinn)      build_context_for_djinn "$directive" ;;
        doctor)     build_context_for_doctor "$directive" ;;
        aletheia)   build_context_for_aletheia "$directive" ;;
        scribe)     build_context_for_scribe "$directive" ;;
        crocodile)  build_context_for_crocodile "$directive" ;;
        *)          
            # Unknown agent - provide generic context
            cat << CONTEXT
# CONTEXT - Cycle $(get_cycle_info)

## Directive
$directive

## Project State
$(get_project_summary)

## Tasks
$(summarize_task_board "summary")

## Messages
$(summarize_messages "$agent_name")
CONTEXT
            ;;
    esac
}

# =============================================================================
# CONTEXT SIZE MONITORING
# =============================================================================
#
# Track context sizes for optimization feedback.
#
# =============================================================================

log_context_size() {
    local agent=$1
    local context="$2"
    
    # Rough token estimate: ~4 chars per token
    local chars=${#context}
    local tokens=$((chars / 4))
    
    local log_file="$PANTHEON_LOGS_DIR/context_sizes.log"
    mkdir -p "$(dirname "$log_file")"
    echo "[$(date -Iseconds)] agent=$agent chars=$chars est_tokens=$tokens" >> "$log_file"
    
    # Warn if context is getting large
    if [[ $tokens -gt 3000 ]]; then
        echo "[WARNING] Large context for $agent: ~$tokens tokens" >&2
    fi
}
