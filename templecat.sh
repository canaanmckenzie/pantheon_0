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
STALL_THRESHOLD="${TEMPLECAT_STALL:-300}"
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
# INVOKE ALETHEIA
# =============================================================================
# Templecat calls upon Aletheia when intervention is needed.
# Aletheia is Claude/Opus with full tool access and autonomy.
# =============================================================================

invoke_aletheia() {
    local issue="$1"
    local diag_file=$(build_diagnostics)

    log ALETHEIA "Templecat invokes Aletheia: $issue"

    # Build context for Aletheia
    local aletheia_context="# ALETHEIA - You Have Been Summoned

**Templecat** has detected a problem and is invoking you to resolve it.

## THE ISSUE
$issue

## DIAGNOSTICS FROM TEMPLECAT
$(cat "$diag_file")

## YOUR DIRECTIVE
Templecat is the guardian daemon watching over the Pantheon. It has detected this issue and called upon you - Aletheia - to diagnose and fix it.

You have FULL AUTONOMY and FULL TOOL ACCESS.

1. Analyze the diagnostics above
2. Identify the root cause
3. FIX THE PROBLEM DIRECTLY
4. Verify your fix works (run \`cargo check\` or equivalent)

Do not just explain what to do. DO IT.

## PATHS
- Working directory: $SCRIPT_DIR
- Project: $SCRIPT_DIR/projects/
- State: $STATE_DIR
- Logs: $LOGS_DIR

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
    local brief="$1"
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
                log OK "PROJECT COMPLETE"
                log OK "=========================================="
                log ALETHEIA "Aletheia approves: All gates passed, compilation verified"
                break
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
                log WARN "Rate limited - waiting 60s..."
                sleep 60
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
            # Check for stalls
            local current_cycle=$(get_cycle_count)
            local log_time=$(get_last_log_time)
            local now=$(date +%s)
            local idle_time=$((now - log_time))

            if [[ $idle_time -gt $STALL_THRESHOLD ]]; then
                if [[ "$stall_detected" == "false" ]]; then
                    log WARN "Stall detected (${idle_time}s idle)"
                    stall_detected=true

                    kill_pantheon
                    local compile_status=$(get_compilation_status)
                    if [[ "$compile_status" == "FAILED" ]]; then
                        invoke_aletheia "Pantheon stalled due to compilation errors"
                    else
                        invoke_aletheia "Pantheon stalled - no obvious cause"
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
        log OK "Templecat sleeps"
    else
        log WARN "Templecat not running"
    fi
}

start_templecat() {
    local brief="$1"

    mkdir -p "$STATE_DIR" "$LOGS_DIR"

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
