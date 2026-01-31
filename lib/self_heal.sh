#!/bin/bash
# =============================================================================
# SELF-HEALING LIBRARY
# =============================================================================
#
# Mechanisms for Aletheia (and the system) to detect and fix issues
# autonomously without burning tokens on broken cycles.
#
# =============================================================================

PANTHEON_ROOT="${PANTHEON_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
PANTHEON_STATE_DIR="${PANTHEON_STATE_DIR:-$PANTHEON_ROOT/.pantheon/state}"
PANTHEON_LOGS_DIR="${PANTHEON_LOGS_DIR:-$PANTHEON_ROOT/.pantheon/logs}"

source "$PANTHEON_ROOT/lib/directories.sh" 2>/dev/null || true
source "$PANTHEON_ROOT/lib/logging.sh" 2>/dev/null || true

# =============================================================================
# COMPILATION GATE
# =============================================================================
# Check if the project compiles BEFORE running expensive agent cycles.
# Returns 0 if OK, 1 if errors exist (with errors written to file)
# =============================================================================

check_compilation() {
    local project_dir=$(get_project_dir 2>/dev/null)
    local build_system=$(detect_build_system 2>/dev/null)
    local error_file="$PANTHEON_STATE_DIR/compilation_errors.txt"

    [[ -z "$project_dir" || ! -d "$project_dir" ]] && return 0

    local output=""
    local status=0

    case "$build_system" in
        rust)
            if [[ -f "$project_dir/Cargo.toml" ]]; then
                output=$(cd "$project_dir" && cargo check 2>&1)
                echo "$output" | grep -q "^error\[E" && status=1
            fi
            ;;
        python)
            if [[ -f "$project_dir/setup.py" ]] || [[ -f "$project_dir/pyproject.toml" ]]; then
                # Use python3 explicitly since 'python' may not exist
                local python_cmd="python3"
                command -v python3 >/dev/null 2>&1 || python_cmd="python"
                output=$(cd "$project_dir" && $python_cmd -m py_compile $(find . -name "*.py" -type f 2>/dev/null) 2>&1)
                [[ -n "$output" ]] && status=1
            fi
            ;;
        node)
            if [[ -f "$project_dir/package.json" ]]; then
                output=$(cd "$project_dir" && npm run build 2>&1 || true)
                echo "$output" | grep -qi "error" && status=1
            fi
            ;;
        c|cpp)
            if [[ -f "$project_dir/Makefile" ]]; then
                output=$(cd "$project_dir" && make -n 2>&1)
                echo "$output" | grep -qi "error" && status=1
            fi
            ;;
        go)
            if [[ -f "$project_dir/go.mod" ]]; then
                output=$(cd "$project_dir" && go build ./... 2>&1)
                [[ $? -ne 0 ]] && status=1
            fi
            ;;
    esac

    if [[ $status -ne 0 ]]; then
        echo "$output" > "$error_file"
        # Extract just the error lines for quick reference
        echo "$output" | grep -E "^error|Error:|error:" | head -20 > "${error_file}.summary"
        return 1
    fi

    rm -f "$error_file" "${error_file}.summary" 2>/dev/null
    return 0
}

# =============================================================================
# AGENT HEALTH TRACKING
# =============================================================================
# Track agent performance to detect patterns of failure
# =============================================================================

track_agent_health() {
    local agent=$1
    local duration=$2
    local response_file="$PANTHEON_STATE_DIR/response_${agent}.md"
    local health_file="$PANTHEON_STATE_DIR/agent_health.json"

    # Initialize health file if needed
    [[ ! -f "$health_file" ]] && echo '{}' > "$health_file"

    local response_size=$(wc -c < "$response_file" 2>/dev/null || echo 0)
    local timed_out="false"
    [[ $duration -ge 598 ]] && timed_out="true"  # Close to 600s timeout

    local tasks_done
    tasks_done=$(grep -c "\[DONE" "$response_file" 2>/dev/null) || tasks_done=0
    local artifacts
    artifacts=$(grep -c "\[ARTIFACT" "$response_file" 2>/dev/null) || artifacts=0

    # Update health tracking
    local updated=$(jq --arg agent "$agent" \
       --arg size "$response_size" \
       --arg timeout "$timed_out" \
       --arg duration "$duration" \
       --arg tasks "$tasks_done" \
       --arg artifacts "$artifacts" \
       --arg time "$(date -Iseconds)" \
       '.[$agent] = {
           response_size: ($size | tonumber),
           timed_out: ($timeout == "true"),
           duration: ($duration | tonumber),
           tasks_completed: ($tasks | tonumber),
           artifacts_created: ($artifacts | tonumber),
           last_run: $time,
           consecutive_timeouts: (if ($timeout == "true") then ((.[$agent].consecutive_timeouts // 0) + 1) else 0 end),
           consecutive_empty: (if ($size | tonumber) < 100 then ((.[$agent].consecutive_empty // 0) + 1) else 0 end)
       }' "$health_file" 2>/dev/null)

    [[ -n "$updated" ]] && echo "$updated" > "$health_file"
}

get_agent_health() {
    local agent=$1
    local health_file="$PANTHEON_STATE_DIR/agent_health.json"

    [[ ! -f "$health_file" ]] && echo "{}" && return

    jq --arg agent "$agent" '.[$agent] // {}' "$health_file" 2>/dev/null
}

is_agent_unhealthy() {
    local agent=$1
    local health=$(get_agent_health "$agent")

    local timeouts=$(echo "$health" | jq '.consecutive_timeouts // 0')
    local empty=$(echo "$health" | jq '.consecutive_empty // 0')

    # Unhealthy if 2+ consecutive timeouts or 3+ consecutive empty responses
    [[ $timeouts -ge 2 || $empty -ge 3 ]] && return 0
    return 1
}

# =============================================================================
# AUTO-FIXER: Simple Compilation Fixes
# =============================================================================
# Fix common, simple compilation errors automatically
# =============================================================================

autofix_rust_serde_instant() {
    local file="$1"
    [[ ! -f "$file" ]] && return 1

    # Add #[serde(skip)] before Instant fields
    if grep -q "pub.*: Instant" "$file" && ! grep -q '#\[serde(skip)\]' "$file"; then
        sed -i 's/\(pub [a-z_]*: Instant\)/#[serde(skip)]\n    \1/' "$file"
        echo "Fixed: Added #[serde(skip)] to Instant field in $file"
        return 0
    fi
    return 1
}

autofix_rust_missing_derive() {
    local file="$1"
    local trait="$2"
    [[ ! -f "$file" ]] && return 1

    # Add missing derive trait
    if grep -q "#\[derive(" "$file" && ! grep -q "derive.*$trait" "$file"; then
        sed -i "s/#\[derive(\([^)]*\)\)/#[derive(\1, $trait)/" "$file"
        echo "Fixed: Added $trait derive to $file"
        return 0
    fi
    return 1
}

autofix_rust_match_arm() {
    local file="$1"
    local enum_name="$2"
    local variant="$3"
    local value="$4"
    [[ ! -f "$file" ]] && return 1

    # This is complex - better to create a message for Djinn
    echo "MANUAL FIX NEEDED: Add match arm for ${enum_name}::${variant} => $value in $file"
    return 1
}

# Main autofix dispatcher
run_autofixes() {
    local project_dir=$(get_project_dir 2>/dev/null)
    local error_file="$PANTHEON_STATE_DIR/compilation_errors.txt"
    local fixed=0

    [[ ! -f "$error_file" ]] && return 0

    local build_system=$(detect_build_system 2>/dev/null)

    case "$build_system" in
        rust)
            # Fix Instant serialization issues
            while IFS= read -r file; do
                if autofix_rust_serde_instant "$file"; then
                    ((fixed++))
                fi
            done < <(grep -l "Instant" "$project_dir"/src/**/*.rs 2>/dev/null)

            # Fix missing Serialize derives
            if grep -q "Serialize.*not satisfied" "$error_file"; then
                local problem_file=$(grep -oP "(?<=--> )[^:]+(?=:)" "$error_file" | head -1)
                if [[ -n "$problem_file" && -f "$project_dir/$problem_file" ]]; then
                    autofix_rust_missing_derive "$project_dir/$problem_file" "Serialize" && ((fixed++))
                fi
            fi
            ;;
    esac

    if [[ $fixed -gt 0 ]]; then
        echo "Auto-fixed $fixed issues"
        # Re-check compilation
        check_compilation
        return $?
    fi

    return 1
}

# =============================================================================
# PRIORITY DIRECTIVE INJECTION
# =============================================================================
# Inject urgent context for agents when critical issues exist
# =============================================================================

inject_priority_directive() {
    local message="$1"
    local priority_file="$PANTHEON_STATE_DIR/priority_directive.md"

    cat > "$priority_file" << EOF
# PRIORITY DIRECTIVE - ADDRESS FIRST

**This issue is BLOCKING all progress. Fix it BEFORE any other work.**

$message

---
EOF
}

clear_priority_directive() {
    rm -f "$PANTHEON_STATE_DIR/priority_directive.md" 2>/dev/null
}

get_priority_directive() {
    local priority_file="$PANTHEON_STATE_DIR/priority_directive.md"
    [[ -f "$priority_file" ]] && cat "$priority_file"
}

# =============================================================================
# CYCLE HEALTH CHECK
# =============================================================================
# Run before each cycle to ensure system is healthy
# =============================================================================

pre_cycle_health_check() {
    local issues=0
    local report=""

    # Check compilation
    if ! check_compilation; then
        ((issues++))
        report+="COMPILATION FAILED - See $PANTHEON_STATE_DIR/compilation_errors.txt\n"

        # Try auto-fixes
        if run_autofixes; then
            report+="AUTO-FIX APPLIED - Re-checking...\n"
            if check_compilation; then
                report+="COMPILATION NOW PASSES\n"
                ((issues--))
            fi
        fi
    fi

    # Check for unhealthy agents
    for agent in djinn doctor architect; do
        if is_agent_unhealthy "$agent"; then
            ((issues++))
            report+="AGENT UNHEALTHY: $agent (check agent_health.json)\n"
        fi
    done

    # Check state file integrity
    for f in task_board.json agent_status.json message_queue.json; do
        if [[ -f "$PANTHEON_STATE_DIR/$f" ]] && ! jq . "$PANTHEON_STATE_DIR/$f" >/dev/null 2>&1; then
            ((issues++))
            report+="INVALID JSON: $f\n"
        fi
    done

    if [[ $issues -gt 0 ]]; then
        echo -e "$report" > "$PANTHEON_STATE_DIR/health_check_report.txt"

        # Inject priority directive if compilation fails
        if grep -q "COMPILATION FAILED" "$PANTHEON_STATE_DIR/health_check_report.txt"; then
            local errors=$(cat "$PANTHEON_STATE_DIR/compilation_errors.txt.summary" 2>/dev/null | head -10)
            inject_priority_directive "## Compilation Errors (FIX THESE FIRST)

\`\`\`
$errors
\`\`\`

Djinn: Fix these compilation errors before ANY other work.
Do NOT implement new features until the code compiles."
        fi

        return 1
    fi

    clear_priority_directive
    return 0
}

# =============================================================================
# TOKEN EFFICIENCY TRACKING
# =============================================================================

log_token_usage() {
    local agent=$1
    local context_file="$PANTHEON_STATE_DIR/context_${agent}.md"
    local response_file="$PANTHEON_STATE_DIR/response_${agent}.md"
    local token_log="$PANTHEON_LOGS_DIR/token_usage.log"

    local input_chars=$(wc -c < "$context_file" 2>/dev/null || echo 0)
    local output_chars=$(wc -c < "$response_file" 2>/dev/null || echo 0)
    local input_tokens=$((input_chars / 4))
    local output_tokens=$((output_chars / 4))
    local total=$((input_tokens + output_tokens))

    local tasks_done
    tasks_done=$(grep -c "\[DONE" "$response_file" 2>/dev/null) || tasks_done=0

    local efficiency=0
    [[ $total -gt 0 ]] && efficiency=$((tasks_done * 1000 / total))

    echo "[$(date -Iseconds)] agent=$agent input=$input_tokens output=$output_tokens total=$total tasks=$tasks_done efficiency=$efficiency" >> "$token_log"
}

get_token_summary() {
    local token_log="$PANTHEON_LOGS_DIR/token_usage.log"
    [[ ! -f "$token_log" ]] && echo "No token data" && return

    echo "=== Token Usage Summary ==="
    awk -F'[ =]' '
    {
        agent=$4; total=$10; tasks=$12
        agents[agent] += total
        agent_tasks[agent] += tasks
        grand_total += total
    }
    END {
        for (a in agents) {
            eff = agent_tasks[a] > 0 ? (agent_tasks[a] * 1000 / agents[a]) : 0
            printf "%s: %d tokens, %d tasks, efficiency=%d\n", a, agents[a], agent_tasks[a], eff
        }
        print "TOTAL: " grand_total " tokens"
    }' "$token_log"
}
