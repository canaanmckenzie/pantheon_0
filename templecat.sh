#!/bin/bash
# =============================================================================
# TEMPLECAT - Pantheon Guardian Daemon
# =============================================================================
#
# Templecat watches over the Pantheon. When problems arise, Templecat
# invokes Aletheia (Claude/Opus) to diagnose and fix them.
#
# USAGE:
#   ./templecat.sh <project_brief>    Start Pantheon under Templecat's watch
#   ./templecat.sh --monitor          Watch an existing Pantheon run
#   ./templecat.sh --status           Show status
#   ./templecat.sh --stop             Stop Templecat
#
# =============================================================================

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TEMPLECAT_PID="$SCRIPT_DIR/.pantheon/templecat.pid"
TEMPLECAT_LOG="$SCRIPT_DIR/.pantheon/logs/templecat.log"
STATE_DIR="$SCRIPT_DIR/.pantheon/state"
LOGS_DIR="$SCRIPT_DIR/.pantheon/logs"
ALETHEIA_PROMPT="$SCRIPT_DIR/agents/aletheia.md"

# Configuration
CHECK_INTERVAL="${TEMPLECAT_INTERVAL:-30}"
STALL_THRESHOLD="${TEMPLECAT_STALL:-600}"
MAX_RESTARTS="${TEMPLECAT_MAX_RESTARTS:-10}"
CYCLES_PER_RESTART="${TEMPLECAT_CYCLES:-3}"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
NC='\033[0m'
BOLD='\033[1m'

# =============================================================================
# LOGGING
# =============================================================================

log() {
    local level="$1"
    shift
    local msg="$*"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[$timestamp] [$level] $msg" >> "$TEMPLECAT_LOG"

    case "$level" in
        INFO)     echo -e "${CYAN}[TEMPLECAT]${NC} $msg" ;;
        OK)       echo -e "${GREEN}[TEMPLECAT]${NC} $msg" ;;
        WARN)     echo -e "${YELLOW}[TEMPLECAT]${NC} $msg" ;;
        ERROR)    echo -e "${RED}[TEMPLECAT]${NC} $msg" ;;
        ALETHEIA) echo -e "${MAGENTA}[ALETHEIA]${NC} ${BOLD}$msg${NC}" ;;
        *)        echo -e "[TEMPLECAT] $msg" ;;
    esac
}

# =============================================================================
# STATE QUERIES
# =============================================================================

get_cycle_count() {
    cat "$STATE_DIR/cycle_count" 2>/dev/null || echo "0"
}

get_last_log_time() {
    stat -c %Y "$LOGS_DIR/pantheon.log" 2>/dev/null || echo "0"
}

get_last_log_line() {
    tail -1 "$LOGS_DIR/pantheon.log" 2>/dev/null || echo ""
}

is_pantheon_running() {
    pgrep -f "orchestrator.sh" > /dev/null 2>&1
}

is_claude_active() {
    # Check if any Claude process is actively running (for the orchestrator)
    pgrep -f "claude.*--print.*--model" > /dev/null 2>&1
}

get_current_agent() {
    # Get which agent is currently running from state
    if [[ -f "$STATE_DIR/current_agent.json" ]]; then
        jq -r '.agent // ""' "$STATE_DIR/current_agent.json" 2>/dev/null
    fi
}

get_agent_runtime() {
    # Get how long current agent has been running
    if [[ -f "$STATE_DIR/current_agent.json" ]]; then
        local started=$(jq -r '.started // 0' "$STATE_DIR/current_agent.json" 2>/dev/null)
        local now=$(date +%s)
        echo $((now - started))
    else
        echo 0
    fi
}

is_project_complete() {
    local gate_file="$STATE_DIR/gate_results.json"
    if [[ -f "$gate_file" ]]; then
        local passed=$(jq -r '.gate_passed // false' "$gate_file" 2>/dev/null)
        [[ "$passed" == "true" ]] && return 0
    fi
    return 1
}

get_compilation_status() {
    local project_dir=$(ls -d "$SCRIPT_DIR/projects"/*/ 2>/dev/null | head -1)
    [[ -z "$project_dir" ]] && echo "NO_PROJECT" && return

    if [[ -f "$project_dir/Cargo.toml" ]]; then
        local output=$(cd "$project_dir" && cargo check 2>&1)
        if echo "$output" | grep -q "^error\[E"; then
            echo "FAILED"
            echo "$output" | grep "^error\[E" | head -10 > "$STATE_DIR/compilation_errors.txt"
        else
            echo "OK"
            rm -f "$STATE_DIR/compilation_errors.txt"
        fi
    elif [[ -f "$project_dir/package.json" ]]; then
        if (cd "$project_dir" && npm run build > /dev/null 2>&1); then
            echo "OK"
        else
            echo "FAILED"
        fi
    elif [[ -f "$project_dir/go.mod" ]]; then
        if (cd "$project_dir" && go build ./... > /dev/null 2>&1); then
            echo "OK"
        else
            echo "FAILED"
        fi
    else
        echo "UNKNOWN"
    fi
}

get_pending_tasks() {
    jq '[.[] | select(.status=="pending")] | length' "$STATE_DIR/task_board.json" 2>/dev/null || echo "0"
}

get_failed_gates() {
    local gate_file="$STATE_DIR/gate_results.json"
    if [[ -f "$gate_file" ]]; then
        jq -r '.reasons // ""' "$gate_file" 2>/dev/null | tr '|' '\n' | grep -v "^$"
    fi
}

# =============================================================================
# DIAGNOSTICS
# =============================================================================

build_diagnostics() {
    local diag_file="$STATE_DIR/templecat_diagnostics.md"

    cat > "$diag_file" << EOF
# DIAGNOSTICS FROM TEMPLECAT - $(date -Iseconds)

## Pantheon Status
- Running: $(is_pantheon_running && echo "YES" || echo "NO")
- Cycle: $(get_cycle_count)
- Last activity: $(date -d @$(get_last_log_time) '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo "Unknown")

## Compilation
Status: $(get_compilation_status)

## Tasks
- Pending: $(get_pending_tasks)

## Gate Status
$(if is_project_complete; then echo "**ALL GATES PASSED**"; else echo "Gates not yet passed"; get_failed_gates; fi)

## Recent Pantheon Log
\`\`\`
$(tail -30 "$LOGS_DIR/pantheon.log" 2>/dev/null || echo "No log available")
\`\`\`

## Compilation Errors
\`\`\`
$(cat "$STATE_DIR/compilation_errors.txt" 2>/dev/null || echo "None")
\`\`\`
EOF

    echo "$diag_file"
}

# =============================================================================
# PANTHEON CONTROL
# =============================================================================

kill_pantheon() {
    log WARN "Stopping Pantheon..."
    pkill -f "orchestrator.sh" 2>/dev/null || true
    pkill -f "pantheon.sh" 2>/dev/null || true
    sleep 2
}

start_pantheon() {
    local brief="$1"
    local cycles="${2:-$CYCLES_PER_RESTART}"

    if [[ -n "$brief" && ! -f "$STATE_DIR/project_state.md" ]]; then
        log INFO "Starting fresh Pantheon run..."
        nohup "$SCRIPT_DIR/pantheon.sh" run "$brief" --cycles "$cycles" --no-aletheia \
            >> "$LOGS_DIR/pantheon_stdout.log" 2>&1 &
    else
        log INFO "Resuming Pantheon for $cycles cycles..."
        nohup "$SCRIPT_DIR/pantheon.sh" resume "$cycles" --no-aletheia \
            >> "$LOGS_DIR/pantheon_stdout.log" 2>&1 &
    fi

    sleep 3
    if is_pantheon_running; then
        log OK "Pantheon started"
        return 0
    else
        log ERROR "Failed to start Pantheon"
        return 1
    fi
}

inject_priority() {
    local message="$1"
    local priority_file="$STATE_DIR/priority_directive.md"

    log INFO "Injecting priority directive..."

    cat > "$priority_file" << EOF
# PRIORITY DIRECTIVE
**From**: Aletheia (via Templecat)
**Time**: $(date -Iseconds)

$message
EOF

    local msg_queue="$STATE_DIR/message_queue.json"
    if [[ -f "$msg_queue" ]]; then
        local new_msg=$(jq --arg msg "$message" --arg time "$(date -Iseconds)" \
            '. + [{from: "aletheia", to: "luminary", content: $msg, priority: "urgent", timestamp: $time}]' \
            "$msg_queue" 2>/dev/null)
        [[ -n "$new_msg" ]] && echo "$new_msg" > "$msg_queue"
    fi
}

# =============================================================================
# SPAWN HELPER DJINN
# =============================================================================
# When an agent is struggling (running too long), spawn a helper Djinn
# to tackle part of the workload. Results merge back via the task board.
# =============================================================================

spawn_helper_djinn() {
    local struggling_agent="$1"
    local helper_log="$LOGS_DIR/helper_djinn_$(date +%Y%m%d_%H%M%S).log"

    log INFO "Spawning helper Djinn for struggling $struggling_agent"

    # Get pending high-priority tasks
    local pending_tasks=$(jq -r '[.[] | select(.status=="pending") | select(.priority=="high")] | .[0:2] | .[].description' \
        "$STATE_DIR/task_board.json" 2>/dev/null | head -2)

    if [[ -z "$pending_tasks" ]]; then
        log INFO "No high-priority tasks to delegate"
        return 0
    fi

    local helper_prompt="# HELPER DJINN - Emergency Spawn

You are a helper Djinn spawned by Templecat because agent $struggling_agent is taking too long.

## YOUR MISSION
Pick ONE of these high-priority tasks and complete it QUICKLY:

$pending_tasks

## RULES
1. Complete the task fully - write working code
2. Mark it done with [DONE]task description[/DONE]
3. Register artifacts with [ARTIFACT:path]
4. Be fast and focused

## PATHS
- Project: $SCRIPT_DIR/projects/
- State: $STATE_DIR

GO!"

    # Spawn helper in background (limited timeout for focused work)
    timeout 300 claude --print --model sonnet \
        --dangerously-skip-permissions \
        -p "$helper_prompt" > "$helper_log" 2>&1 &

    local helper_pid=$!
    log INFO "Helper Djinn spawned (PID: $helper_pid, log: $helper_log)"

    # Don't wait - let it run in parallel
    echo "$helper_pid" >> "$STATE_DIR/helper_pids.txt"
}

# =============================================================================
# INVOKE ALETHEIA
# =============================================================================
# Templecat calls upon Aletheia when intervention is needed.
# Aletheia is Claude/Opus with full tool access and autonomy.
# =============================================================================

invoke_aletheia() {
    local issue="$1"
    local diag_file=$(build_diagnostics)

    log ALETHEIA "Templecat invokes Aletheia: $issue"

    # Get current agent info for context
    local current_agent=$(get_current_agent)
    local agent_runtime=$(get_agent_runtime)

    # Build context for Aletheia
    local aletheia_context="# ALETHEIA - You Have Been Summoned

**Templecat** has detected a problem and is invoking you to resolve it.

## THE ISSUE
$issue

## CURRENT STATE
- Cycle: $(get_cycle_count)
- Agent that was running: ${current_agent:-unknown}
- Agent runtime: ${agent_runtime}s

## DIAGNOSTICS FROM TEMPLECAT
$(cat "$diag_file")

## YOUR DIRECTIVE
Templecat is the guardian daemon watching over the Pantheon. It has detected this issue and called upon you - Aletheia - to diagnose and fix it.

You have FULL AUTONOMY and FULL TOOL ACCESS.

1. Analyze the diagnostics above
2. Identify the root cause
3. FIX THE PROBLEM DIRECTLY
4. Verify your fix works (run tests or equivalent)
5. If the fix is done, Pantheon will auto-resume from where it left off

Do not just explain what to do. DO IT.

## IMPORTANT: Progress Preservation
The system now tracks which agents completed. When you're done fixing:
- Pantheon will resume from the agent that was stuck
- Completed agents won't re-run
- No work is lost

## PATHS
- Working directory: $SCRIPT_DIR
- Project: $SCRIPT_DIR/projects/
- State: $STATE_DIR
- Logs: $LOGS_DIR
- Current agent state: $STATE_DIR/current_agent.json
- Cycle progress: $STATE_DIR/cycle_progress.json

Templecat is waiting. Fix this and return control."

    # Load Aletheia's system prompt
    local system_prompt=""
    if [[ -f "$ALETHEIA_PROMPT" ]]; then
        system_prompt=$(cat "$ALETHEIA_PROMPT")
    else
        system_prompt="You are Aletheia, guardian of truth in the Pantheon. You verify, diagnose, and fix. You have full tool access. Be decisive."
    fi

    local session_log="$LOGS_DIR/aletheia_$(date +%Y%m%d_%H%M%S).log"
    log ALETHEIA "Session: $session_log"

    # Invoke Aletheia (Claude/Opus with full permissions)
    timeout 600 claude --print --model opus \
        --dangerously-skip-permissions \
        --system-prompt "$system_prompt" \
        -p "$aletheia_context" > "$session_log" 2>&1 || true

    log ALETHEIA "Session complete"

    # Check result
    sleep 2
    local status=$(get_compilation_status)
    if [[ "$status" == "OK" ]]; then
        log OK "Aletheia resolved the issue"
        return 0
    elif [[ "$status" == "FAILED" ]]; then
        log WARN "Issue persists after Aletheia intervention"
        return 1
    else
        log INFO "Will verify on next cycle"
        return 0
    fi
}

# =============================================================================
# MAIN LOOP
# =============================================================================

watch_loop() {
    local brief="${1:-}"
    local restart_count=0
    local last_cycle=0
    local stall_detected=false

    log INFO "=========================================="
    log INFO "TEMPLECAT AWAKENS"
    log INFO "=========================================="
    log INFO "Watching over the Pantheon..."
    log INFO "Check interval: ${CHECK_INTERVAL}s"
    log INFO "Stall threshold: ${STALL_THRESHOLD}s"

    # Start Pantheon if not running
    if ! is_pantheon_running; then
        if ! start_pantheon "$brief"; then
            log ERROR "Cannot start Pantheon"
            return 1
        fi
        ((restart_count++))
    fi

    while true; do
        sleep "$CHECK_INTERVAL"

        # Stop signal
        if [[ -f "$SCRIPT_DIR/.pantheon/templecat_stop" ]]; then
            log INFO "Stop signal received"
            rm -f "$SCRIPT_DIR/.pantheon/templecat_stop"
            break
        fi

        # Check completion
        if is_project_complete; then
            local compile_status=$(get_compilation_status)
            if [[ "$compile_status" == "OK" ]]; then
                log OK "=========================================="
                log OK "PROJECT GATES PASSED - INVOKING FINAL VALIDATION"
                log OK "=========================================="

                # Invoke Aletheia for FINAL comprehensive validation
                # This ensures the project truly functions as intended
                local brief_content=""
                if [[ -f "$STATE_DIR/brief.md" ]]; then
                    brief_content=$(cat "$STATE_DIR/brief.md")
                fi

                invoke_aletheia "FINAL VALIDATION: All cycles complete and gates passed.

## Your Task: COMPREHENSIVE PROJECT VALIDATION

Review the project against its specification (brief.md) and verify it truly functions as intended.

### Validation Checklist:
1. **Build/Compilation**: Verify all code compiles without errors
2. **Test Suite**: Run ALL tests and verify they pass
3. **Integration Check**: Ensure components work together
4. **Functionality Review**: Verify each major feature works as designed
5. **Code Quality**: Check for stubs, TODOs, or incomplete implementations
6. **Production Readiness**: Assess if this is truly production-grade
7. **Spec Compliance**: Does the project meet the specification in the brief?

### Project Specification (from brief.md):
$brief_content

### YOUR POWERS:

**If project PASSES validation:**
- Create file: .pantheon/state/aletheia_approved
- Report SUCCESS - the project is complete

**If project NEEDS MORE WORK:**
- Create priority directive: .pantheon/state/priority_directive.md
- Include specific issues that need fixing
- Then restart with more cycles:
  \`\`\`bash
  ./pantheon.sh resume 3  # Add 3 more cycles
  \`\`\`
- DO NOT approve incomplete work - add cycles until it's RIGHT

### Remember:
The project must be AS GOOD OR BETTER than what the spec describes.
If it's not there yet, YOU have the power to add more cycles.
Only approve when it truly meets production-grade standards."

                # Check if Aletheia approved or requested more cycles
                if [[ -f "$STATE_DIR/aletheia_approved" ]]; then
                    log OK "=========================================="
                    log OK "PROJECT COMPLETE - ALETHEIA VERIFIED"
                    log OK "=========================================="
                    rm -f "$STATE_DIR/aletheia_approved"
                    break
                elif is_pantheon_running; then
                    # Aletheia restarted cycles - continue monitoring
                    log INFO "Aletheia requested more cycles - continuing..."
                fi
            else
                log WARN "Gates passed but compilation fails"
                invoke_aletheia "Gates report passed but compilation is failing - investigate"
            fi
        fi

        # Check if Pantheon running
        if ! is_pantheon_running; then
            log WARN "Pantheon stopped"

            local last_line=$(get_last_log_line)

            if echo "$last_line" | grep -q "PANTHEON COMPLETE"; then
                log INFO "Pantheon finished - checking gates..."
                continue
            elif echo "$last_line" | grep -q "Rate limit"; then
                # Rate limit detected - invoke Aletheia for project review
                log WARN "Rate limit detected - invoking Aletheia for project state review"

                # Create rate limit flag for tracking
                touch "$STATE_DIR/rate_limit.flag"

                # Check if this is a repeated rate limit (within 5 minutes)
                local flag_time=$(stat -c %Y "$STATE_DIR/rate_limit.flag" 2>/dev/null || echo "0")
                local now_ts=$(date +%s)
                local rate_limit_count=0

                if [[ -f "$STATE_DIR/rate_limit_count" ]]; then
                    rate_limit_count=$(cat "$STATE_DIR/rate_limit_count")
                fi
                ((rate_limit_count++))
                echo "$rate_limit_count" > "$STATE_DIR/rate_limit_count"

                if [[ $rate_limit_count -ge 3 ]]; then
                    # Too many rate limits - invoke Aletheia and pause
                    log ERROR "Multiple rate limits detected ($rate_limit_count) - invoking Aletheia"
                    invoke_aletheia "TOKEN EXHAUSTION: Rate limit hit $rate_limit_count times. Review project state, ensure ready for resume when limits reset."

                    # Wait longer - 10 minutes between attempts after multiple failures
                    log WARN "Waiting 600s before next attempt..."
                    sleep 600

                    # Reset counter after long wait
                    echo "0" > "$STATE_DIR/rate_limit_count"
                else
                    # First few rate limits - shorter wait
                    log WARN "Rate limited (attempt $rate_limit_count) - waiting 120s..."
                    sleep 120
                fi

                # Continue loop instead of falling through to restart
                continue
            fi

            if [[ $restart_count -lt $MAX_RESTARTS ]]; then
                local compile_status=$(get_compilation_status)
                if [[ "$compile_status" == "FAILED" ]]; then
                    invoke_aletheia "Compilation errors blocking progress"
                fi

                local failed_gates=$(get_failed_gates)
                if [[ -n "$failed_gates" ]]; then
                    inject_priority "Fix these failed gates before declaring complete:\n$failed_gates"
                fi

                start_pantheon "" "$CYCLES_PER_RESTART"
                ((restart_count++))
                stall_detected=false
                log INFO "Restart $restart_count / $MAX_RESTARTS"
            else
                log ERROR "Max restarts reached"
                invoke_aletheia "Pantheon has restarted $MAX_RESTARTS times without completion - assess situation"
                break
            fi
        else
            # =================================================================
            # SMART STALL DETECTION
            # =================================================================
            # Don't just check log time - check if Claude is actually working
            # A "stall" is when:
            #   - Log hasn't been updated AND Claude isn't running
            #   - OR an agent has been running excessively long (> 900s)
            # =================================================================
            local current_cycle=$(get_cycle_count)
            local log_time=$(get_last_log_time)
            local now=$(date +%s)
            local idle_time=$((now - log_time))
            local current_agent=$(get_current_agent)
            local agent_runtime=$(get_agent_runtime)
            local claude_active=$(is_claude_active && echo "yes" || echo "no")

            # If Claude is actively running, it's not a stall
            if [[ "$claude_active" == "yes" ]]; then
                stall_detected=false

                # But if agent running too long (>900s), consider spawning help
                if [[ $agent_runtime -gt 900 && -n "$current_agent" ]]; then
                    log WARN "Agent $current_agent running long (${agent_runtime}s) - spawning helper"
                    spawn_helper_djinn "$current_agent"
                fi

                if [[ $current_cycle -ne $last_cycle ]]; then
                    log INFO "Cycle $current_cycle in progress"
                    last_cycle=$current_cycle
                fi
            elif [[ $idle_time -gt $STALL_THRESHOLD ]]; then
                # Log is stale AND Claude isn't running = real stall
                if [[ "$stall_detected" == "false" ]]; then
                    log WARN "Stall detected (${idle_time}s idle, no Claude process)"
                    stall_detected=true

                    local compile_status=$(get_compilation_status)
                    if [[ "$compile_status" == "FAILED" ]]; then
                        log INFO "Invoking Aletheia for compilation errors"
                        invoke_aletheia "Pantheon stalled due to compilation errors"
                    elif [[ -n "$current_agent" ]]; then
                        log INFO "Agent $current_agent was stuck - invoking Aletheia"
                        invoke_aletheia "Agent $current_agent stalled without completion - diagnose and resume"
                    else
                        log INFO "Invoking Aletheia for unknown stall"
                        invoke_aletheia "Pantheon stalled - no obvious cause"
                    fi

                    # After Aletheia, resume from where we left off
                    if ! is_pantheon_running; then
                        start_pantheon "" "$CYCLES_PER_RESTART"
                        ((restart_count++))
                        stall_detected=false
                        log INFO "Restart $restart_count / $MAX_RESTARTS"
                    fi
                fi
            else
                stall_detected=false
                if [[ $current_cycle -ne $last_cycle ]]; then
                    log INFO "Cycle $current_cycle in progress"
                    last_cycle=$current_cycle
                fi
            fi
        fi
    done

    log INFO "Templecat rests"
}

# =============================================================================
# COMMANDS
# =============================================================================

show_status() {
    echo -e "${CYAN}=========================================="
    echo -e "  TEMPLECAT STATUS"
    echo -e "==========================================${NC}"

    if [[ -f "$TEMPLECAT_PID" ]]; then
        local pid=$(cat "$TEMPLECAT_PID")
        if kill -0 "$pid" 2>/dev/null; then
            echo -e "Templecat: ${GREEN}WATCHING${NC} (PID: $pid)"
        else
            echo -e "Templecat: ${YELLOW}STALE${NC}"
        fi
    else
        echo -e "Templecat: ${RED}SLEEPING${NC}"
    fi

    echo ""
    echo "Pantheon: $(is_pantheon_running && echo -e "${GREEN}RUNNING${NC}" || echo -e "${RED}STOPPED${NC}")"
    echo "Cycle: $(get_cycle_count)"
    echo "Compilation: $(get_compilation_status)"
    echo "Complete: $(is_project_complete && echo -e "${GREEN}YES${NC}" || echo "NO")"
}

stop_templecat() {
    if [[ -f "$TEMPLECAT_PID" ]]; then
        local pid=$(cat "$TEMPLECAT_PID")
        log INFO "Templecat going to sleep (PID: $pid)..."
        touch "$SCRIPT_DIR/.pantheon/templecat_stop"
        sleep 2
        kill "$pid" 2>/dev/null || true
        rm -f "$TEMPLECAT_PID"
        # Clean up stop signal so it doesn't affect next start
        rm -f "$SCRIPT_DIR/.pantheon/templecat_stop"
        log OK "Templecat sleeps"
    else
        log WARN "Templecat not running"
        # Clean up any stale stop file
        rm -f "$SCRIPT_DIR/.pantheon/templecat_stop"
    fi
}

start_templecat() {
    local brief="$1"

    mkdir -p "$STATE_DIR" "$LOGS_DIR"

    # Clean up stale stop signal from previous runs
    rm -f "$SCRIPT_DIR/.pantheon/templecat_stop"

    if [[ -f "$TEMPLECAT_PID" ]]; then
        local pid=$(cat "$TEMPLECAT_PID")
        if kill -0 "$pid" 2>/dev/null; then
            log WARN "Templecat already watching (PID: $pid)"
            return 1
        fi
    fi

    log INFO "Templecat awakens..."
    nohup "$0" --daemon "$brief" >> "$TEMPLECAT_LOG" 2>&1 &
    local pid=$!
    echo "$pid" > "$TEMPLECAT_PID"

    sleep 2
    if kill -0 "$pid" 2>/dev/null; then
        log OK "Templecat watching (PID: $pid)"
        log INFO "Log: $TEMPLECAT_LOG"
        log INFO "Stop: $0 --stop"
    else
        log ERROR "Templecat failed to start"
        rm -f "$TEMPLECAT_PID"
        return 1
    fi
}

# =============================================================================
# MAIN
# =============================================================================

case "${1:-}" in
    --daemon)
        shift
        watch_loop "$@"
        ;;
    --stop)
        stop_templecat
        ;;
    --status)
        show_status
        ;;
    --monitor)
        start_templecat ""
        ;;
    --help|-h)
        cat << 'EOF'
TEMPLECAT - Pantheon Guardian

Templecat watches over the Pantheon. When problems arise, Templecat
invokes Aletheia (Claude/Opus) to diagnose and fix them.

USAGE:
  ./templecat.sh <brief>      Start Pantheon under Templecat's watch
  ./templecat.sh --monitor    Watch an existing run
  ./templecat.sh --status     Show status
  ./templecat.sh --stop       Put Templecat to sleep

HOW IT WORKS:
  1. Templecat starts/monitors Pantheon
  2. Checks every 30s for problems
  3. Detects: stalls, crashes, compilation errors, failed gates
  4. When issues found: INVOKES ALETHEIA
  5. Aletheia (Claude/Opus) diagnoses and fixes directly
  6. Templecat restarts Pantheon with context
  7. Repeats until genuinely complete

ALETHEIA:
  When Templecat detects a problem, it invokes Aletheia:
  - Claude/Opus with full permissions (--dangerously-skip-permissions)
  - Given diagnostics and the specific issue
  - Has full tool access to read, write, execute
  - Expected to FIX the problem, not just analyze

EOF
        ;;
    "")
        echo "Usage: $0 <brief> | --monitor | --status | --stop | --help"
        exit 1
        ;;
    *)
        start_templecat "$1"
        ;;
esac
