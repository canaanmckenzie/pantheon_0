#!/bin/bash
# =============================================================================
# QUALITY GATE LIBRARY
# =============================================================================
#
# Comprehensive quality control to prevent half-finished products.
#
# THIS IS THE MISSING PIECE:
# --------------------------
# Previous system allowed "completion" when:
# - Tasks were marked [DONE] by agents (no verification)
# - Code compiled (but might have stubs)
# - Tests "passed" (but might not run or have weak coverage)
#
# THIS LIBRARY ADDS:
# ------------------
# 1. STUB DETECTION - Find unimplemented!(), todo!(), panic!("not implemented")
# 2. FEATURE COMPLETENESS - Compare brief requirements to actual functionality
# 3. TEST QUALITY - Ensure tests actually run and cover core paths
# 4. OUTPUT VALIDATION - Verify the tool produces useful output
# 5. REQUIREMENTS TRACKING - Map brief requirements to implementations
#
# =============================================================================

PANTHEON_ROOT="${PANTHEON_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
# Use .pantheon/ structure (fallback if not set)
PANTHEON_STATE_DIR="${PANTHEON_STATE_DIR:-$PANTHEON_ROOT/.pantheon/state}"
PANTHEON_LOGS_DIR="${PANTHEON_LOGS_DIR:-$PANTHEON_ROOT/.pantheon/logs}"
PANTHEON_SPAWN_DIR="${PANTHEON_SPAWN_DIR:-$PANTHEON_ROOT/.pantheon/spawn}"
PANTHEON_ARTIFACTS_DIR="${PANTHEON_ARTIFACTS_DIR:-$PANTHEON_ROOT/.pantheon/artifacts}"
PANTHEON_PROJECTS_DIR="${PANTHEON_PROJECTS_DIR:-$PANTHEON_ROOT/projects}"
source "$PANTHEON_ROOT/lib/directories.sh" 2>/dev/null || true

# Use new directory structure with legacy fallback
_get_state_dir() {
    if [[ -d "$PANTHEON_STATE_DIR" ]]; then
        echo "$PANTHEON_STATE_DIR"
    else
        echo "$PANTHEON_ROOT/state"
    fi
}

_get_logs_dir() {
    if [[ -d "$PANTHEON_LOGS_DIR" ]]; then
        echo "$PANTHEON_LOGS_DIR"
    else
        echo "$PANTHEON_ROOT/logs"
    fi
}

# =============================================================================
# STUB/INCOMPLETE CODE DETECTION
# =============================================================================

# Find unimplemented code patterns
detect_stubs() {
    local project_dir=$(get_project_dir)
    local stub_log="$PANTHEON_LOGS_DIR/stub_detection.log"
    local stubs_found=0
    local critical_stubs=0

    echo "## Stub/Incomplete Code Detection" | tee "$stub_log"
    echo "Project: $project_dir" | tee -a "$stub_log"
    echo "Timestamp: $(date -Iseconds)" | tee -a "$stub_log"
    echo "" | tee -a "$stub_log"

    if [[ -z "$project_dir" ]] || [[ ! -d "$project_dir" ]]; then
        echo "**ERROR**: No project directory found" | tee -a "$stub_log"
        return 1
    fi

    # Rust stub patterns (these are CRITICAL - code will panic at runtime)
    local rust_patterns=(
        "unimplemented!()"
        "todo!()"
        'panic!.*"not.*implement'
        'panic!.*"stub'
        'panic!.*"TODO'
        'unreachable!.*"should.*implement'
    )

    # Python stub patterns
    local python_patterns=(
        "raise NotImplementedError"
        "pass  # TODO"
        "pass  # stub"
        '\.\.\.  # placeholder'
    )

    # General patterns (comments indicating incomplete work)
    local general_patterns=(
        "FIXME.*critical"
        "TODO.*implement"
        "HACK.*temporary"
        "XXX.*broken"
    )

    echo "### Rust Stub Detection" | tee -a "$stub_log"

    # Check Rust source files
    for pattern in "${rust_patterns[@]}"; do
        local matches=$(grep -rn --include="*.rs" -E "$pattern" "$project_dir/src" 2>/dev/null || true)
        if [[ -n "$matches" ]]; then
            echo "" | tee -a "$stub_log"
            echo "**FOUND**: Pattern '$pattern'" | tee -a "$stub_log"
            echo "$matches" | tee -a "$stub_log"
            ((stubs_found++))

            # Critical stubs that will cause runtime panics
            if [[ "$pattern" == "unimplemented!()" ]] || [[ "$pattern" == "todo!()" ]]; then
                ((critical_stubs++))
            fi
        fi
    done

    echo "" | tee -a "$stub_log"
    echo "### Python Stub Detection" | tee -a "$stub_log"

    # Check Python source files
    for pattern in "${python_patterns[@]}"; do
        local matches=$(grep -rn --include="*.py" -E "$pattern" "$project_dir" 2>/dev/null || true)
        if [[ -n "$matches" ]]; then
            echo "" | tee -a "$stub_log"
            echo "**FOUND**: Pattern '$pattern'" | tee -a "$stub_log"
            echo "$matches" | tee -a "$stub_log"
            ((stubs_found++))
        fi
    done

    echo "" | tee -a "$stub_log"
    echo "### Summary" | tee -a "$stub_log"
    echo "Total stubs found: $stubs_found" | tee -a "$stub_log"
    echo "Critical stubs (will panic): $critical_stubs" | tee -a "$stub_log"

    # Store results for other components
    cat > "$PANTHEON_STATE_DIR/stub_detection.json" << EOF
{
    "timestamp": "$(date -Iseconds)",
    "stubs_found": $stubs_found,
    "critical_stubs": $critical_stubs,
    "project": "$(detect_project_name)",
    "passed": $(if [[ $critical_stubs -eq 0 ]]; then echo "true"; else echo "false"; fi)
}
EOF

    if [[ $critical_stubs -gt 0 ]]; then
        echo "" | tee -a "$stub_log"
        echo "**QUALITY CHECK FAILED**: $critical_stubs critical stubs will cause runtime panics" | tee -a "$stub_log"
        return 1
    fi

    echo "" | tee -a "$stub_log"
    echo "**QUALITY CHECK PASSED**: No critical stubs found" | tee -a "$stub_log"
    return 0
}

# =============================================================================
# FEATURE COMPLETENESS VALIDATION
# =============================================================================

# Extract requirements from project brief
extract_requirements() {
    local brief_file="$PANTHEON_STATE_DIR/project_brief.md"
    local requirements=()

    if [[ ! -f "$brief_file" ]]; then
        echo "[]"
        return
    fi

    # Extract "must have", "should", "needs to" phrases
    local reqs=$(grep -oiE "(must|should|needs? to|required to|has to|will) [^.!?]{10,100}" "$brief_file" 2>/dev/null | head -20)

    # Also look for bullet points that look like requirements
    local bullets=$(grep -E "^[*-] .*" "$brief_file" 2>/dev/null | head -20)

    echo "$reqs"
    echo "$bullets"
}

# Validate core features actually work
validate_feature_completeness() {
    local project_dir=$(get_project_dir)
    local project_name=$(detect_project_name)
    local completeness_log="$PANTHEON_LOGS_DIR/feature_completeness.log"
    local failures=0

    echo "## Feature Completeness Validation" | tee "$completeness_log"
    echo "Project: $project_name" | tee -a "$completeness_log"
    echo "Timestamp: $(date -Iseconds)" | tee -a "$completeness_log"
    echo "" | tee -a "$completeness_log"

    # Build system detection
    local build_system=$(detect_build_system)

    case "$project_name" in
        rscan)
            # rscan is a port scanner - it MUST be able to:
            # 1. Parse command line arguments
            # 2. Connect to TCP ports
            # 3. Report open/closed ports
            # 4. Handle multiple targets

            echo "### rscan Core Feature Validation" | tee -a "$completeness_log"

            local binary="$project_dir/target/release/$project_name"
            [[ ! -x "$binary" ]] && binary="$project_dir/target/debug/$project_name"

            if [[ ! -x "$binary" ]]; then
                echo "**FAILED**: Binary not found" | tee -a "$completeness_log"
                ((failures++))
            else
                # Test 1: Can it scan a known-open port on localhost?
                echo "" | tee -a "$completeness_log"
                echo "Test 1: Scan localhost port (using 127.0.0.1)" | tee -a "$completeness_log"

                local output=$(timeout 15 "$binary" 127.0.0.1 -p 22,80,443 2>&1)
                echo "$output" | tee -a "$completeness_log"

                # Critical failures
                if echo "$output" | grep -qi "not yet implemented\|not implemented\|unimplemented"; then
                    echo "  **CRITICAL FAILURE**: Core feature not implemented" | tee -a "$completeness_log"
                    ((failures++))
                fi

                if echo "$output" | grep -qi "panic\|thread.*panicked"; then
                    echo "  **CRITICAL FAILURE**: Runtime panic detected" | tee -a "$completeness_log"
                    ((failures++))
                fi

                # Must actually scan something
                if echo "$output" | grep -q "0 host(s) scanned"; then
                    echo "  **FAILURE**: Scanner couldn't scan any hosts" | tee -a "$completeness_log"
                    ((failures++))
                fi

                # Must produce port results
                if ! echo "$output" | grep -qiE "(open|closed|filtered|scanning|scanned)"; then
                    echo "  **FAILURE**: No scan results in output" | tee -a "$completeness_log"
                    ((failures++))
                fi

                # Test 2: Can it handle port ranges?
                echo "" | tee -a "$completeness_log"
                echo "Test 2: Port range parsing" | tee -a "$completeness_log"

                output=$(timeout 5 "$binary" 127.0.0.1 -p 1-100 --help 2>&1 || true)
                if echo "$output" | grep -qi "invalid.*range\|parse.*error"; then
                    echo "  **FAILURE**: Can't parse port ranges" | tee -a "$completeness_log"
                    ((failures++))
                else
                    echo "  PASSED" | tee -a "$completeness_log"
                fi

                # Test 3: JSON output works
                echo "" | tee -a "$completeness_log"
                echo "Test 3: JSON output format" | tee -a "$completeness_log"

                output=$(timeout 10 "$binary" 127.0.0.1 -p 80 -o json 2>&1)
                if echo "$output" | grep -qi "not.*implement\|unimplemented"; then
                    echo "  **FAILURE**: JSON output not implemented" | tee -a "$completeness_log"
                    ((failures++))
                else
                    echo "  PASSED" | tee -a "$completeness_log"
                fi
            fi
            ;;

        *)
            echo "No project-specific validation for '$project_name'" | tee -a "$completeness_log"
            echo "Running generic validation..." | tee -a "$completeness_log"

            # Generic: Just check for runtime panics on --help
            case "$build_system" in
                rust)
                    local binary="$project_dir/target/release/$project_name"
                    [[ ! -x "$binary" ]] && binary="$project_dir/target/debug/$project_name"

                    if [[ -x "$binary" ]]; then
                        local output=$("$binary" --help 2>&1 || true)
                        if echo "$output" | grep -qi "panic\|thread.*panicked"; then
                            echo "**FAILURE**: Runtime panic on --help" | tee -a "$completeness_log"
                            ((failures++))
                        fi
                    fi
                    ;;
            esac
            ;;
    esac

    echo "" | tee -a "$completeness_log"
    echo "### Summary" | tee -a "$completeness_log"
    echo "Failures: $failures" | tee -a "$completeness_log"

    # Store results
    cat > "$PANTHEON_STATE_DIR/feature_completeness.json" << EOF
{
    "timestamp": "$(date -Iseconds)",
    "failures": $failures,
    "project": "$project_name",
    "passed": $(if [[ $failures -eq 0 ]]; then echo "true"; else echo "false"; fi)
}
EOF

    if [[ $failures -gt 0 ]]; then
        echo "" | tee -a "$completeness_log"
        echo "**FEATURE VALIDATION FAILED**: $failures core features not working" | tee -a "$completeness_log"
        return 1
    fi

    echo "**FEATURE VALIDATION PASSED**" | tee -a "$completeness_log"
    return 0
}

# =============================================================================
# TEST QUALITY VALIDATION
# =============================================================================

# Check that tests actually compile and run
validate_test_quality() {
    local project_dir=$(get_project_dir)
    local build_system=$(detect_build_system)
    local test_quality_log="$PANTHEON_LOGS_DIR/test_quality.log"
    local failures=0

    echo "## Test Quality Validation" | tee "$test_quality_log"
    echo "Project: $project_dir" | tee -a "$test_quality_log"
    echo "" | tee -a "$test_quality_log"

    case "$build_system" in
        rust)
            echo "### Checking test compilation" | tee -a "$test_quality_log"

            # Try to compile tests without running them
            local compile_output=$(cd "$project_dir" && cargo test --no-run 2>&1)
            local compile_exit=$?

            echo "$compile_output" | tail -50 | tee -a "$test_quality_log"

            if [[ $compile_exit -ne 0 ]]; then
                echo "" | tee -a "$test_quality_log"
                echo "**FAILED**: Tests don't compile" | tee -a "$test_quality_log"

                # Count compilation errors
                local error_count=$(echo "$compile_output" | grep -c "^error\[E" || echo 0)
                echo "Compilation errors: $error_count" | tee -a "$test_quality_log"
                ((failures++))
            else
                echo "" | tee -a "$test_quality_log"
                echo "**PASSED**: Tests compile successfully" | tee -a "$test_quality_log"
            fi

            # Check for test count (at least some tests should exist)
            echo "" | tee -a "$test_quality_log"
            echo "### Checking test count" | tee -a "$test_quality_log"

            local test_count=$(grep -r "#\[test\]" "$project_dir/tests" "$project_dir/src" 2>/dev/null | wc -l)
            echo "Test functions found: $test_count" | tee -a "$test_quality_log"

            if [[ $test_count -lt 3 ]]; then
                echo "**WARNING**: Very few tests ($test_count)" | tee -a "$test_quality_log"
            fi
            ;;

        python)
            echo "### Checking pytest discovery" | tee -a "$test_quality_log"

            local test_output=$(cd "$project_dir" && pytest --collect-only 2>&1)
            local test_exit=$?

            echo "$test_output" | tee -a "$test_quality_log"

            if echo "$test_output" | grep -q "no tests ran\|collected 0 items"; then
                echo "**WARNING**: No tests discovered" | tee -a "$test_quality_log"
            fi
            ;;

        node)
            echo "### Checking npm test" | tee -a "$test_quality_log"

            if [[ -f "$project_dir/package.json" ]]; then
                local has_test=$(jq -r '.scripts.test // "none"' "$project_dir/package.json")
                if [[ "$has_test" == "none" ]] || [[ "$has_test" == *"no test"* ]]; then
                    echo "**WARNING**: No test script defined" | tee -a "$test_quality_log"
                fi
            fi
            ;;
    esac

    # Store results
    cat > "$PANTHEON_STATE_DIR/test_quality.json" << EOF
{
    "timestamp": "$(date -Iseconds)",
    "tests_compile": $(if [[ $failures -eq 0 ]]; then echo "true"; else echo "false"; fi),
    "failures": $failures,
    "project": "$(detect_project_name)"
}
EOF

    return $failures
}

# =============================================================================
# COMPREHENSIVE QUALITY GATE
# =============================================================================

run_quality_gate() {
    local quality_log="$PANTHEON_LOGS_DIR/quality_gate.log"
    local stub_ok=true
    local features_ok=true
    local tests_ok=true

    echo "==========================================" | tee "$quality_log"
    echo "PANTHEON QUALITY GATE" | tee -a "$quality_log"
    echo "==========================================" | tee -a "$quality_log"
    echo "Timestamp: $(date -Iseconds)" | tee -a "$quality_log"
    echo "" | tee -a "$quality_log"

    # Step 1: Stub Detection
    echo "Step 1/3: Stub Detection..." | tee -a "$quality_log"
    if ! detect_stubs >> "$quality_log" 2>&1; then
        stub_ok=false
    fi
    echo "" | tee -a "$quality_log"

    # Step 2: Feature Completeness
    echo "Step 2/3: Feature Completeness..." | tee -a "$quality_log"
    if ! validate_feature_completeness >> "$quality_log" 2>&1; then
        features_ok=false
    fi
    echo "" | tee -a "$quality_log"

    # Step 3: Test Quality
    echo "Step 3/3: Test Quality..." | tee -a "$quality_log"
    if ! validate_test_quality >> "$quality_log" 2>&1; then
        tests_ok=false
    fi
    echo "" | tee -a "$quality_log"

    # Summary
    echo "==========================================" | tee -a "$quality_log"
    echo "QUALITY GATE SUMMARY" | tee -a "$quality_log"
    echo "==========================================" | tee -a "$quality_log"
    echo "Stub Detection:       $(if $stub_ok; then echo 'PASSED'; else echo 'FAILED'; fi)" | tee -a "$quality_log"
    echo "Feature Completeness: $(if $features_ok; then echo 'PASSED'; else echo 'FAILED'; fi)" | tee -a "$quality_log"
    echo "Test Quality:         $(if $tests_ok; then echo 'PASSED'; else echo 'FAILED'; fi)" | tee -a "$quality_log"
    echo "" | tee -a "$quality_log"

    # Store comprehensive results
    cat > "$PANTHEON_STATE_DIR/quality_gate.json" << EOF
{
    "timestamp": "$(date -Iseconds)",
    "stub_detection_passed": $stub_ok,
    "feature_completeness_passed": $features_ok,
    "test_quality_passed": $tests_ok,
    "all_passed": $(if $stub_ok && $features_ok && $tests_ok; then echo "true"; else echo "false"; fi),
    "project": "$(detect_project_name)"
}
EOF

    if $stub_ok && $features_ok && $tests_ok; then
        echo "**QUALITY GATE PASSED** - Project meets quality standards" | tee -a "$quality_log"
        return 0
    else
        echo "**QUALITY GATE FAILED** - Project does not meet quality standards" | tee -a "$quality_log"
        echo "" | tee -a "$quality_log"
        echo "Review logs for details:" | tee -a "$quality_log"
        echo "  - logs/stub_detection.log" | tee -a "$quality_log"
        echo "  - logs/feature_completeness.log" | tee -a "$quality_log"
        echo "  - logs/test_quality.log" | tee -a "$quality_log"
        return 1
    fi
}

# =============================================================================
# REQUIREMENTS TRACKING
# =============================================================================

# Parse brief and create requirements checklist
create_requirements_checklist() {
    local brief_file="$PANTHEON_STATE_DIR/project_brief.md"
    local checklist_file="$PANTHEON_STATE_DIR/requirements_checklist.json"

    if [[ ! -f "$brief_file" ]]; then
        echo "[]" > "$checklist_file"
        return
    fi

    # Extract potential requirements from brief
    local requirements=()
    local id=1

    # Look for specific feature mentions
    while IFS= read -r line; do
        # Clean up the line
        line=$(echo "$line" | sed 's/^[*-] //' | sed 's/^[0-9]\+\. //')

        # Skip empty lines
        [[ -z "$line" ]] && continue

        # Add as requirement
        requirements+=("{\"id\": $id, \"description\": \"$line\", \"verified\": false}")
        ((id++))
    done < <(grep -iE "(must|should|needs? to|feature|support|implement|provide)" "$brief_file" | head -15)

    # Write checklist
    echo "[" > "$checklist_file"
    local first=true
    for req in "${requirements[@]}"; do
        if $first; then
            first=false
        else
            echo "," >> "$checklist_file"
        fi
        echo "  $req" >> "$checklist_file"
    done
    echo "]" >> "$checklist_file"
}
