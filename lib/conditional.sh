#!/bin/bash
# =============================================================================
# CONDITIONAL EXECUTION LIBRARY
# =============================================================================
#
# WHAT THIS DOES:
# ---------------
# Determines whether an agent should run this cycle based on whether
# there's actually work for them to do.
#
# WHY THIS MATTERS:
# -----------------
# The original system runs ALL 7 agents EVERY cycle, regardless of whether
# they have work. This wastes tokens on:
#   - Architect running when no tasks need decomposition
#   - Doctor running when no new code exists to test
#   - Scribe running when nothing has changed
#
# By skipping agents with no work, we can reduce cycles by 30-50%.
#
# THE PHILOSOPHY:
# ---------------
# Each agent has "trigger conditions" - situations that require their attention.
# If none of their triggers are active, they skip this cycle.
#
# ALWAYS RUN agents:
#   - Luminary: Always assesses state (they decide completion)
#   - Crocodile: Always runs cleanup at end of cycle
#
# CONDITIONAL agents:
#   - Architect: Only if undecomposed tasks or structural issues
#   - Weaver: Only if parallelizable work exists
#   - Djinn: Only if implementation tasks pending
#   - Doctor: Only if untested artifacts exist
#   - Scribe: Only if undocumented work or decisions
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

# Source logging if available
[[ -f "$PANTHEON_ROOT/lib/logging.sh" ]] && source "$PANTHEON_ROOT/lib/logging.sh"

# =============================================================================
# TRIGGER DETECTION FUNCTIONS
# =============================================================================
#
# Each function returns 0 (true) if the agent should run, 1 (false) if skip.
#
# =============================================================================

# ---------------------------------------------------------------------------
# LUMINARY - Always runs (strategic oversight)
# ---------------------------------------------------------------------------
should_run_luminary() {
    # Luminary always runs - they're the strategic leader
    return 0
}

# ---------------------------------------------------------------------------
# ARCHITECT - Runs when structural work needed
# ---------------------------------------------------------------------------
should_run_architect() {
    local task_file="$PANTHEON_STATE_DIR/task_board.json"
    local cycle=$(cat "$PANTHEON_STATE_DIR/cycle_count" 2>/dev/null || echo 1)
    
    # Always run on first 2 cycles (initial design phase)
    if [[ $cycle -le 2 ]]; then
        return 0
    fi
    
    # Check for undecomposed tasks (tasks marked needing breakdown)
    local undecomposed=$(jq '[.[] | select(.needs_decomposition == true)] | length' \
        "$task_file" 2>/dev/null || echo 0)
    if [[ $undecomposed -gt 0 ]]; then
        return 0
    fi
    
    # Check for "architecture" or "design" tasks
    local arch_tasks=$(jq '[.[] | select(.status=="pending") | select(.description | test("architect|design|structure|interface"; "i"))] | length' \
        "$task_file" 2>/dev/null || echo 0)
    if [[ $arch_tasks -gt 0 ]]; then
        return 0
    fi
    
    # Check for messages addressed to architect
    local messages=$(jq --arg to "architect" \
        '[.[] | select(.to == $to and .delivered == false)] | length' \
        "$PANTHEON_STATE_DIR/message_queue.json" 2>/dev/null || echo 0)
    if [[ $messages -gt 0 ]]; then
        return 0
    fi
    
    # Check for blockers that might need architectural review
    local blockers=$(jq '[.[] | select(.type == "blocker")] | length' \
        "$PANTHEON_STATE_DIR/message_queue.json" 2>/dev/null || echo 0)
    if [[ $blockers -gt 0 ]]; then
        return 0
    fi
    
    # No triggers - skip this cycle
    return 1
}

# ---------------------------------------------------------------------------
# WEAVER - Runs when coordination/parallel work needed
# ---------------------------------------------------------------------------
should_run_weaver() {
    local task_file="$PANTHEON_STATE_DIR/task_board.json"
    local spawn_queue="$PANTHEON_STATE_DIR/spawn_queue.json"
    
    # Check for multiple pending tasks (opportunity for parallelism)
    local pending=$(jq '[.[] | select(.status=="pending")] | length' \
        "$task_file" 2>/dev/null || echo 0)
    if [[ $pending -ge 2 ]]; then
        return 0
    fi
    
    # Check for integration tasks
    local integration_tasks=$(jq '[.[] | select(.status=="pending") | select(.description | test("integrat|connect|combine|merge"; "i"))] | length' \
        "$task_file" 2>/dev/null || echo 0)
    if [[ $integration_tasks -gt 0 ]]; then
        return 0
    fi
    
    # Check if there are pending spawns to manage
    local queued_spawns=$(jq 'length' "$spawn_queue" 2>/dev/null || echo 0)
    if [[ $queued_spawns -gt 0 ]]; then
        return 0
    fi
    
    # Check for messages
    local messages=$(jq --arg to "weaver" \
        '[.[] | select(.to == $to and .delivered == false)] | length' \
        "$PANTHEON_STATE_DIR/message_queue.json" 2>/dev/null || echo 0)
    if [[ $messages -gt 0 ]]; then
        return 0
    fi
    
    return 1
}

# ---------------------------------------------------------------------------
# DJINN - Runs when implementation work exists
# ---------------------------------------------------------------------------
should_run_djinn() {
    local task_file="$PANTHEON_STATE_DIR/task_board.json"

    # Check for implementation/feature tasks
    # Note: Use (.type // "") to handle missing type field
    local impl_tasks=$(jq '[.[] | select(.status=="pending" or .status=="in_progress") | select((.type // "") == "implementation" or (.type // "") == "feature" or (.description | test("implement|build|create|write|code"; "i")))] | length' \
        "$task_file" 2>/dev/null || echo 0)
    if [[ $impl_tasks -gt 0 ]]; then
        return 0
    fi
    
    # Check for any pending tasks (Djinn can pick up general work)
    local pending=$(jq '[.[] | select(.status=="pending")] | length' \
        "$task_file" 2>/dev/null || echo 0)
    if [[ $pending -gt 0 ]]; then
        return 0
    fi
    
    # Check for messages requesting implementation
    local messages=$(jq --arg to "djinn" \
        '[.[] | select(.to == $to and .delivered == false)] | length' \
        "$PANTHEON_STATE_DIR/message_queue.json" 2>/dev/null || echo 0)
    if [[ $messages -gt 0 ]]; then
        return 0
    fi
    
    return 1
}

# ---------------------------------------------------------------------------
# DOCTOR - Runs when testing/debugging needed
# ---------------------------------------------------------------------------
should_run_doctor() {
    local artifact_file="$PANTHEON_STATE_DIR/artifacts.json"
    local task_file="$PANTHEON_STATE_DIR/task_board.json"
    
    # Check for untested artifacts
    local untested=$(jq '[.[] | select(.tested != true)] | length' \
        "$artifact_file" 2>/dev/null || echo 0)
    if [[ $untested -gt 0 ]]; then
        return 0
    fi
    
    # Check for test/debug tasks
    local test_tasks=$(jq '[.[] | select(.status=="pending") | select(.description | test("test|debug|diagnose|fix|bug"; "i"))] | length' \
        "$task_file" 2>/dev/null || echo 0)
    if [[ $test_tasks -gt 0 ]]; then
        return 0
    fi
    
    # Check for bug reports in messages
    local bugs=$(jq '[.[] | select(.type == "blocker" or .content | test("bug|error|fail"; "i"))] | length' \
        "$PANTHEON_STATE_DIR/message_queue.json" 2>/dev/null || echo 0)
    if [[ $bugs -gt 0 ]]; then
        return 0
    fi
    
    # Check for messages
    local messages=$(jq --arg to "doctor" \
        '[.[] | select(.to == $to and .delivered == false)] | length' \
        "$PANTHEON_STATE_DIR/message_queue.json" 2>/dev/null || echo 0)
    if [[ $messages -gt 0 ]]; then
        return 0
    fi
    
    return 1
}

# ---------------------------------------------------------------------------
# SCRIBE - Runs when documentation needed
# ---------------------------------------------------------------------------
should_run_scribe() {
    local artifact_file="$PANTHEON_STATE_DIR/artifacts.json"
    local decisions_file="$PANTHEON_STATE_DIR/decisions.json"
    local task_file="$PANTHEON_STATE_DIR/task_board.json"
    local cycle=$(cat "$PANTHEON_STATE_DIR/cycle_count" 2>/dev/null || echo 1)
    
    # Run every 3rd cycle for regular documentation updates
    if [[ $((cycle % 3)) -eq 0 ]]; then
        return 0
    fi
    
    # Check for undocumented artifacts (heuristic: no .md file with same base name)
    local undocumented=$(jq '[.[] | select(.documented != true) | select(.path | test("\\.(rs|py|go|ts|js)$"))] | length' \
        "$artifact_file" 2>/dev/null || echo 0)
    if [[ $undocumented -gt 3 ]]; then
        return 0
    fi
    
    # Check for recent decisions needing ADRs
    local recent_decisions=$(jq '[.[] | select(.adr_written != true)] | length' \
        "$decisions_file" 2>/dev/null || echo 0)
    if [[ $recent_decisions -gt 2 ]]; then
        return 0
    fi
    
    # Check for documentation tasks
    local doc_tasks=$(jq '[.[] | select(.status=="pending") | select(.description | test("document|readme|changelog|api doc"; "i"))] | length' \
        "$task_file" 2>/dev/null || echo 0)
    if [[ $doc_tasks -gt 0 ]]; then
        return 0
    fi
    
    # Check for messages
    local messages=$(jq --arg to "scribe" \
        '[.[] | select(.to == $to and .delivered == false)] | length' \
        "$PANTHEON_STATE_DIR/message_queue.json" 2>/dev/null || echo 0)
    if [[ $messages -gt 0 ]]; then
        return 0
    fi
    
    return 1
}

# ---------------------------------------------------------------------------
# ALETHEIA - Now runs EXTERNALLY via ./pantheon.sh aletheia
# ---------------------------------------------------------------------------
# NOTE: Aletheia removed from internal agent loop.
# She runs as an external supervisor with full Claude Code access.
# Start her with: ./pantheon.sh aletheia
# ---------------------------------------------------------------------------
should_run_aletheia() {
    # Always returns 1 (skip) since she's external now
    return 1
}

# ---------------------------------------------------------------------------
# CROCODILE - Always runs (state maintenance)
# ---------------------------------------------------------------------------
should_run_crocodile() {
    # Crocodile always runs at end of cycle for state maintenance
    return 0
}

# =============================================================================
# MAIN DISPATCHER
# =============================================================================
#
# Entry point for checking if an agent should run.
# Returns 0 if should run, 1 if should skip.
#
# =============================================================================

should_run_agent() {
    local agent_name=$1
    
    case "$agent_name" in
        luminary)   should_run_luminary ;;
        architect)  should_run_architect ;;
        weaver)     should_run_weaver ;;
        djinn)      should_run_djinn ;;
        doctor)     should_run_doctor ;;
        aletheia)   should_run_aletheia ;;
        scribe)     should_run_scribe ;;
        crocodile)  should_run_crocodile ;;
        *)          return 0 ;;  # Unknown agents always run (safe default)
    esac
}

# =============================================================================
# SKIP LOGGING
# =============================================================================
#
# Log when agents are skipped for monitoring/debugging.
#
# =============================================================================

log_agent_skip() {
    local agent=$1
    local reason=$2
    
    local log_file="$PANTHEON_LOGS_DIR/agent_skips.log"
    mkdir -p "$(dirname "$log_file")"
    echo "[$(date -Iseconds)] SKIP $agent: $reason" >> "$log_file"
}

# =============================================================================
# FORCED EXECUTION
# =============================================================================
#
# Sometimes we want to force an agent to run regardless of triggers.
# Check for force flags in state.
#
# =============================================================================

is_agent_forced() {
    local agent_name=$1
    local force_file="$PANTHEON_STATE_DIR/force_${agent_name}"
    
    if [[ -f "$force_file" ]]; then
        rm -f "$force_file"  # One-time force
        return 0
    fi
    return 1
}

force_agent_next_cycle() {
    local agent_name=$1
    touch "$PANTHEON_STATE_DIR/force_${agent_name}"
}
