#!/bin/bash
# =============================================================================
# VERIFICATION LIBRARY
# =============================================================================
#
# THE MISSING PIECE: Actual execution verification before marking complete.
#
# WHAT THIS DOES:
# ---------------
# 1. Compiles/builds the project
# 2. Runs tests
# 3. Executes basic smoke tests
# 4. Verifies the binary/output actually works
# 5. Only allows [COMPLETE] if verification passes
#
# WHY THIS MATTERS:
# -----------------
# The original system marked work "complete" based solely on agent claims.
# Agents said [DONE], so tasks were marked done. No actual verification.
#
# This library adds a verification gate that ACTUALLY RUNS THE CODE.
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
# BUILD VERIFICATION
# =============================================================================

# Detect project type and build system
detect_build_system() {
    local project_dir=$(get_project_dir)

    if [[ -z "$project_dir" ]] || [[ ! -d "$project_dir" ]]; then
        echo "unknown"
        return
    fi

    if [[ -f "$project_dir/Cargo.toml" ]]; then
        echo "rust"
    elif [[ -f "$project_dir/package.json" ]]; then
        echo "node"
    elif [[ -f "$project_dir/pyproject.toml" ]] || [[ -f "$project_dir/setup.py" ]]; then
        echo "python"
    elif [[ -f "$project_dir/go.mod" ]]; then
        echo "go"
    elif [[ -f "$project_dir/Makefile" ]]; then
        echo "make"
    else
        echo "unknown"
    fi
}

# Build the project
verify_build() {
    local project_dir=$(get_project_dir)
    local build_system=$(detect_build_system)
    local build_log="$PANTHEON_LOGS_DIR/build_verification.log"
    local exit_code=0

    echo "## Build Verification" | tee "$build_log"
    echo "Project: $project_dir" | tee -a "$build_log"
    echo "Build system: $build_system" | tee -a "$build_log"
    echo "" | tee -a "$build_log"

    if [[ -z "$project_dir" ]] || [[ ! -d "$project_dir" ]]; then
        echo "**FAILED**: No project directory found" | tee -a "$build_log"
        return 1
    fi

    case "$build_system" in
        rust)
            echo "Running: cargo build --release" | tee -a "$build_log"
            if (cd "$project_dir" && cargo build --release 2>&1 | tee -a "$build_log"); then
                echo "**BUILD PASSED**" | tee -a "$build_log"
            else
                echo "**BUILD FAILED**" | tee -a "$build_log"
                exit_code=1
            fi
            ;;
        node)
            echo "Running: npm install && npm run build" | tee -a "$build_log"
            if (cd "$project_dir" && npm install 2>&1 && npm run build 2>&1 | tee -a "$build_log"); then
                echo "**BUILD PASSED**" | tee -a "$build_log"
            else
                echo "**BUILD FAILED**" | tee -a "$build_log"
                exit_code=1
            fi
            ;;
        python)
            echo "Running: python -m py_compile on source files" | tee -a "$build_log"
            local py_errors=0
            for pyfile in "$project_dir"/*.py "$project_dir"/src/*.py; do
                [[ -f "$pyfile" ]] || continue
                if ! python -m py_compile "$pyfile" 2>&1 | tee -a "$build_log"; then
                    ((py_errors++))
                fi
            done
            if [[ $py_errors -eq 0 ]]; then
                echo "**BUILD PASSED**" | tee -a "$build_log"
            else
                echo "**BUILD FAILED**: $py_errors files with errors" | tee -a "$build_log"
                exit_code=1
            fi
            ;;
        go)
            echo "Running: go build" | tee -a "$build_log"
            if (cd "$project_dir" && go build ./... 2>&1 | tee -a "$build_log"); then
                echo "**BUILD PASSED**" | tee -a "$build_log"
            else
                echo "**BUILD FAILED**" | tee -a "$build_log"
                exit_code=1
            fi
            ;;
        make)
            echo "Running: make" | tee -a "$build_log"
            if (cd "$project_dir" && make 2>&1 | tee -a "$build_log"); then
                echo "**BUILD PASSED**" | tee -a "$build_log"
            else
                echo "**BUILD FAILED**" | tee -a "$build_log"
                exit_code=1
            fi
            ;;
        *)
            echo "**UNKNOWN BUILD SYSTEM** - cannot verify build" | tee -a "$build_log"
            exit_code=2
            ;;
    esac

    return $exit_code
}

# =============================================================================
# TEST VERIFICATION
# =============================================================================

# Run project tests
verify_tests() {
    local project_dir=$(get_project_dir)
    local build_system=$(detect_build_system)
    local test_log="$PANTHEON_LOGS_DIR/test_verification.log"
    local exit_code=0
    local test_output=""

    echo "## Test Verification" | tee "$test_log"
    echo "Project: $project_dir" | tee -a "$test_log"
    echo "" | tee -a "$test_log"

    if [[ -z "$project_dir" ]] || [[ ! -d "$project_dir" ]]; then
        echo "**FAILED**: No project directory found" | tee -a "$test_log"
        return 1
    fi

    case "$build_system" in
        rust)
            echo "Running: cargo test" | tee -a "$test_log"
            # Capture both output and exit code properly
            test_output=$(cd "$project_dir" && cargo test 2>&1) || exit_code=$?
            echo "$test_output" | tee -a "$test_log"

            # Check for compilation errors (these are fatal)
            if echo "$test_output" | grep -q "error\[E"; then
                echo "**TESTS FAILED**: Compilation errors in test code" | tee -a "$test_log"
                exit_code=1
            # Check for test failures
            elif echo "$test_output" | grep -q "FAILED"; then
                echo "**TESTS FAILED**: Some tests did not pass" | tee -a "$test_log"
                exit_code=1
            # Check exit code
            elif [[ $exit_code -ne 0 ]]; then
                echo "**TESTS FAILED**: cargo test returned exit code $exit_code" | tee -a "$test_log"
            else
                echo "**TESTS PASSED**" | tee -a "$test_log"
            fi
            ;;
        node)
            echo "Running: npm test" | tee -a "$test_log"
            test_output=$(cd "$project_dir" && npm test 2>&1) || exit_code=$?
            echo "$test_output" | tee -a "$test_log"

            if [[ $exit_code -ne 0 ]]; then
                echo "**TESTS FAILED**: npm test returned exit code $exit_code" | tee -a "$test_log"
            else
                echo "**TESTS PASSED**" | tee -a "$test_log"
            fi
            ;;
        python)
            echo "Running: pytest" | tee -a "$test_log"
            test_output=$(cd "$project_dir" && pytest 2>&1) || exit_code=$?
            echo "$test_output" | tee -a "$test_log"

            if [[ $exit_code -ne 0 ]]; then
                echo "**TESTS FAILED**: pytest returned exit code $exit_code" | tee -a "$test_log"
            else
                echo "**TESTS PASSED**" | tee -a "$test_log"
            fi
            ;;
        go)
            echo "Running: go test" | tee -a "$test_log"
            test_output=$(cd "$project_dir" && go test ./... 2>&1) || exit_code=$?
            echo "$test_output" | tee -a "$test_log"

            if [[ $exit_code -ne 0 ]]; then
                echo "**TESTS FAILED**: go test returned exit code $exit_code" | tee -a "$test_log"
            else
                echo "**TESTS PASSED**" | tee -a "$test_log"
            fi
            ;;
        *)
            echo "**UNKNOWN TEST SYSTEM** - cannot verify tests" | tee -a "$test_log"
            exit_code=2
            ;;
    esac

    return $exit_code
}

# =============================================================================
# SMOKE TEST VERIFICATION
# =============================================================================

# Run basic smoke tests on the built artifact
verify_smoke_test() {
    local project_dir=$(get_project_dir)
    local project_name=$(detect_project_name)
    local build_system=$(detect_build_system)
    local smoke_log="$PANTHEON_LOGS_DIR/smoke_verification.log"
    local exit_code=0

    echo "## Smoke Test Verification" | tee "$smoke_log"
    echo "Project: $project_name" | tee -a "$smoke_log"
    echo "" | tee -a "$smoke_log"

    if [[ -z "$project_dir" ]] || [[ ! -d "$project_dir" ]]; then
        echo "**FAILED**: No project directory found" | tee -a "$smoke_log"
        return 1
    fi

    case "$build_system" in
        rust)
            local binary="$project_dir/target/release/$project_name"
            local debug_binary="$project_dir/target/debug/$project_name"

            # Try release first, then debug
            local test_binary=""
            if [[ -x "$binary" ]]; then
                test_binary="$binary"
            elif [[ -x "$debug_binary" ]]; then
                test_binary="$debug_binary"
            fi

            if [[ -z "$test_binary" ]]; then
                echo "**FAILED**: No executable found at $binary or $debug_binary" | tee -a "$smoke_log"
                exit_code=1
            else
                echo "Testing binary: $test_binary" | tee -a "$smoke_log"

                # Test 1: --help should work
                echo "" | tee -a "$smoke_log"
                echo "Test 1: --help" | tee -a "$smoke_log"
                if "$test_binary" --help 2>&1 | tee -a "$smoke_log"; then
                    echo "  PASSED" | tee -a "$smoke_log"
                else
                    echo "  FAILED: --help returned error" | tee -a "$smoke_log"
                    exit_code=1
                fi

                # Test 2: --version should work
                echo "" | tee -a "$smoke_log"
                echo "Test 2: --version" | tee -a "$smoke_log"
                if "$test_binary" --version 2>&1 | tee -a "$smoke_log"; then
                    echo "  PASSED" | tee -a "$smoke_log"
                else
                    echo "  FAILED: --version returned error" | tee -a "$smoke_log"
                    exit_code=1
                fi

                # Test 3: Basic invocation (project-specific)
                # For rscan: try scanning localhost
                if [[ "$project_name" == "rscan" ]]; then
                    echo "" | tee -a "$smoke_log"
                    echo "Test 3: Basic scan (127.0.0.1:80)" | tee -a "$smoke_log"

                    # Use IP address to avoid hostname resolution issues
                    local scan_output=$(timeout 10 "$test_binary" 127.0.0.1 -p 80 2>&1)
                    echo "$scan_output" | tee -a "$smoke_log"

                    # =========================================================
                    # STRICT SMOKE TEST - No half-finished products
                    # =========================================================
                    # A scanner that can't scan is NOT complete.
                    # Any "not implemented" output is an automatic FAILURE.
                    # =========================================================

                    local smoke_failed=false

                    # CRITICAL: Check for any "not implemented" strings (case insensitive)
                    if echo "$scan_output" | grep -qiE "not.*(yet )?implement|unimplemented|todo!|panic!"; then
                        echo "  **CRITICAL FAILURE**: Core feature not implemented" | tee -a "$smoke_log"
                        echo "  Found: $(echo "$scan_output" | grep -iE "not.*(yet )?implement|unimplemented" | head -1)" | tee -a "$smoke_log"
                        smoke_failed=true
                        exit_code=1
                    fi

                    # CRITICAL: Check for panics
                    if echo "$scan_output" | grep -qiE "panic|thread.*panicked|fatal"; then
                        echo "  **CRITICAL FAILURE**: Runtime panic detected" | tee -a "$smoke_log"
                        smoke_failed=true
                        exit_code=1
                    fi

                    # CRITICAL: Check for error messages
                    if echo "$scan_output" | grep -qiE "^error:|Error:"; then
                        echo "  **FAILURE**: Scan returned errors" | tee -a "$smoke_log"
                        echo "  Found: $(echo "$scan_output" | grep -iE "^error:|Error:" | head -1)" | tee -a "$smoke_log"
                        smoke_failed=true
                        exit_code=1
                    fi

                    # CRITICAL: Must actually scan something (not 0 hosts)
                    if echo "$scan_output" | grep -q "0 host(s) scanned"; then
                        echo "  **FAILURE**: Scanner couldn't scan any hosts" | tee -a "$smoke_log"
                        smoke_failed=true
                        exit_code=1
                    fi

                    # Verify positive results exist
                    if ! $smoke_failed; then
                        # Must show scan activity
                        if echo "$scan_output" | grep -qE "([0-9]+ host|open|closed|filtered|scann)"; then
                            echo "  PASSED: Scan completed with results" | tee -a "$smoke_log"
                        else
                            echo "  **FAILURE**: No scan results in output" | tee -a "$smoke_log"
                            exit_code=1
                        fi
                    fi
                fi
            fi
            ;;
        node)
            local main_script=""
            if [[ -f "$project_dir/package.json" ]]; then
                main_script=$(jq -r '.main // "index.js"' "$project_dir/package.json")
            fi

            if [[ -f "$project_dir/$main_script" ]]; then
                echo "Testing: node $main_script --help" | tee -a "$smoke_log"
                if (cd "$project_dir" && node "$main_script" --help 2>&1 | tee -a "$smoke_log"); then
                    echo "**SMOKE TEST PASSED**" | tee -a "$smoke_log"
                else
                    echo "**SMOKE TEST FAILED**" | tee -a "$smoke_log"
                    exit_code=1
                fi
            else
                echo "**SKIPPED**: No main script found" | tee -a "$smoke_log"
            fi
            ;;
        *)
            echo "**SKIPPED**: No smoke test for $build_system" | tee -a "$smoke_log"
            ;;
    esac

    return $exit_code
}

# =============================================================================
# FULL VERIFICATION PIPELINE
# =============================================================================

# Run all verification steps
run_full_verification() {
    local results_file="$PANTHEON_STATE_DIR/verification_results.json"
    local build_ok=false
    local tests_ok=false
    local smoke_ok=false

    echo "=========================================="
    echo "PANTHEON VERIFICATION PIPELINE"
    echo "=========================================="
    echo ""

    # Step 1: Build
    echo "Step 1/3: Build verification..."
    if verify_build; then
        build_ok=true
    fi
    echo ""

    # Step 2: Tests (only if build passed)
    if $build_ok; then
        echo "Step 2/3: Test verification..."
        if verify_tests; then
            tests_ok=true
        fi
    else
        echo "Step 2/3: SKIPPED (build failed)"
    fi
    echo ""

    # Step 3: Smoke tests (only if tests passed)
    if $tests_ok; then
        echo "Step 3/3: Smoke test verification..."
        if verify_smoke_test; then
            smoke_ok=true
        fi
    else
        echo "Step 3/3: SKIPPED (tests failed)"
    fi
    echo ""

    # Write results
    cat > "$results_file" << EOF
{
    "timestamp": "$(date -Iseconds)",
    "build_passed": $build_ok,
    "tests_passed": $tests_ok,
    "smoke_passed": $smoke_ok,
    "all_passed": $(if $build_ok && $tests_ok && $smoke_ok; then echo "true"; else echo "false"; fi),
    "project": "$(detect_project_name)",
    "project_dir": "$(get_project_dir)"
}
EOF

    echo "=========================================="
    echo "VERIFICATION SUMMARY"
    echo "=========================================="
    echo "Build:  $(if $build_ok; then echo 'PASSED'; else echo 'FAILED'; fi)"
    echo "Tests:  $(if $tests_ok; then echo 'PASSED'; else echo 'FAILED/SKIPPED'; fi)"
    echo "Smoke:  $(if $smoke_ok; then echo 'PASSED'; else echo 'FAILED/SKIPPED'; fi)"
    echo ""

    if $build_ok && $tests_ok && $smoke_ok; then
        echo "**ALL VERIFICATION PASSED** - Project is ready for completion"
        return 0
    else
        echo "**VERIFICATION FAILED** - Project is NOT ready for completion"
        return 1
    fi
}

# =============================================================================
# COMPLETION GATE
# =============================================================================

# Check if project can be marked complete
can_mark_complete() {
    local results_file="$PANTHEON_STATE_DIR/verification_results.json"

    if [[ ! -f "$results_file" ]]; then
        echo "No verification results found. Run verification first."
        return 1
    fi

    local all_passed=$(jq -r '.all_passed' "$results_file" 2>/dev/null)

    if [[ "$all_passed" == "true" ]]; then
        return 0
    else
        echo "Verification failed. Cannot mark project complete."
        echo "Last verification results:"
        jq '.' "$results_file"
        return 1
    fi
}

# Generate verification report for Luminary
get_verification_status() {
    local results_file="$PANTHEON_STATE_DIR/verification_results.json"

    if [[ ! -f "$results_file" ]]; then
        echo "## Verification Status: NOT RUN"
        echo "Verification has not been executed. Run verification before declaring [COMPLETE]."
        return
    fi

    local build=$(jq -r '.build_passed' "$results_file")
    local tests=$(jq -r '.tests_passed' "$results_file")
    local smoke=$(jq -r '.smoke_passed' "$results_file")
    local all=$(jq -r '.all_passed' "$results_file")
    local timestamp=$(jq -r '.timestamp' "$results_file")

    echo "## Verification Status"
    echo "Last run: $timestamp"
    echo ""
    echo "| Check | Status |"
    echo "|-------|--------|"
    echo "| Build | $(if [[ "$build" == "true" ]]; then echo 'PASSED'; else echo '**FAILED**'; fi) |"
    echo "| Tests | $(if [[ "$tests" == "true" ]]; then echo 'PASSED'; else echo '**FAILED**'; fi) |"
    echo "| Smoke | $(if [[ "$smoke" == "true" ]]; then echo 'PASSED'; else echo '**FAILED**'; fi) |"
    echo ""

    if [[ "$all" == "true" ]]; then
        echo "**ALL CHECKS PASSED** - You may declare [COMPLETE]"
    else
        echo "**VERIFICATION FAILED** - Do NOT declare [COMPLETE]"
        echo "Check logs/build_verification.log, logs/test_verification.log, logs/smoke_verification.log for details"
    fi
}
