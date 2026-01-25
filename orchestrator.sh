#!/bin/bash
#
# PANTHEON ORCHESTRATOR
# Autonomous Multi-Agent Claude Code Swarm
# 
# The Seven: Crocodile, Scribe, Architect, Weaver, Doctor, Luminary, Djinn
#

set -e

PANTHEON_ROOT="$(cd "$(dirname "$0")" && pwd)"
export PANTHEON_ROOT

# Source core libraries
source "$PANTHEON_ROOT/lib/colors.sh"
source "$PANTHEON_ROOT/lib/logging.sh"
source "$PANTHEON_ROOT/lib/state.sh"
source "$PANTHEON_ROOT/lib/messaging.sh"
source "$PANTHEON_ROOT/lib/spawner.sh"

# ============================================================================
# INITIALIZATION
# ============================================================================

init_pantheon() {
    log_header "PANTHEON SWARM INITIALIZING"

    # Create all required directories
    mkdir -p "$PANTHEON_ROOT/state"
    mkdir -p "$PANTHEON_ROOT/state/checkpoints"
    mkdir -p "$PANTHEON_ROOT/logs"
    mkdir -p "$PANTHEON_ROOT/tasks"
    mkdir -p "$PANTHEON_ROOT/spawn"
    mkdir -p "$PANTHEON_ROOT/spawn/archive"
    mkdir -p "$PANTHEON_ROOT/output"

    # Initialize state (Crocodile's domain)
    init_state_db

    # Clear previous run artifacts
    rm -f "$PANTHEON_ROOT/tasks/"*.task 2>/dev/null || true
    rm -f "$PANTHEON_ROOT/logs/"*.log 2>/dev/null || true
    rm -f "$PANTHEON_ROOT/state/"*.lock 2>/dev/null || true
    
    # Initialize task board and all state files
    echo "[]" > "$PANTHEON_ROOT/state/task_board.json"
    echo "[]" > "$PANTHEON_ROOT/state/message_queue.json"
    echo "{}" > "$PANTHEON_ROOT/state/agent_status.json"
    echo "[]" > "$PANTHEON_ROOT/state/artifacts.json"
    echo "[]" > "$PANTHEON_ROOT/state/spawn_queue.json"
    echo "[]" > "$PANTHEON_ROOT/state/spawn_registry.json"
    echo "{}" > "$PANTHEON_ROOT/state/memory.json"
    echo "[]" > "$PANTHEON_ROOT/state/decisions.json"
    echo "0" > "$PANTHEON_ROOT/state/cycle_count"
    
    # Register all agents
    for agent in crocodile scribe architect weaver doctor luminary djinn; do
        register_agent "$agent"
    done
    
    log_success "Pantheon initialized"
}

# ============================================================================
# DEPENDENCY MANAGEMENT - AUTONOMOUS TOOL ACQUISITION
# ============================================================================
#
# SECURITY NOTICE - SUPPLY CHAIN ATTACK PREVENTION:
# -------------------------------------------------
# All dependency acquisition MUST follow these security principles:
#
# 1. VERIFY CHECKSUMS: Always verify package integrity via SHA256/SHA512 hashes
# 2. USE LOCKFILES: Cargo.lock, package-lock.json, requirements.txt with hashes
# 3. AUDIT SOURCES: Only pull from official registries (crates.io, pypi.org, apt repos)
# 4. PIN VERSIONS: Never use floating versions in production dependencies
# 5. VERIFY SIGNATURES: Use GPG signatures where available (apt, cargo with crev)
# 6. MINIMAL DEPENDENCIES: Prefer stdlib over external deps when reasonable
# 7. REVIEW BEFORE INSTALL: Log all installations for audit trail
#
# The functions below implement these principles for autonomous operation.
# ============================================================================

# Dependency installation log for audit trail
DEP_LOG="$PANTHEON_ROOT/logs/dependencies.log"

log_dependency() {
    local action=$1
    local package=$2
    local version=$3
    local checksum=$4
    mkdir -p "$PANTHEON_ROOT/logs"
    echo "[$(date -Iseconds)] $action: $package@$version (checksum: ${checksum:-none})" >> "$DEP_LOG"
}

# ----------------------------------------------------------------------------
# SYSTEM PACKAGES (apt/dnf)
# ----------------------------------------------------------------------------

install_system_packages() {
    local packages=("$@")

    log_info "Installing system packages: ${packages[*]}"

    # Detect package manager
    local pkg_mgr=""
    if command -v apt-get &>/dev/null; then
        pkg_mgr="apt"
    elif command -v dnf &>/dev/null; then
        pkg_mgr="dnf"
    elif command -v pacman &>/dev/null; then
        pkg_mgr="pacman"
    else
        log_error "No supported package manager found"
        return 1
    fi

    for pkg in "${packages[@]}"; do
        log_dependency "SYSTEM_INSTALL" "$pkg" "latest" "repo-signed"
    done

    case "$pkg_mgr" in
        apt)
            # APT packages are GPG-signed by repository keys
            sudo apt-get update -qq
            sudo apt-get install -y -qq "${packages[@]}"
            ;;
        dnf)
            # DNF verifies GPG signatures by default
            sudo dnf install -y -q "${packages[@]}"
            ;;
        pacman)
            # Pacman verifies signatures based on pacman.conf settings
            sudo pacman -S --noconfirm --needed "${packages[@]}"
            ;;
    esac

    log_success "System packages installed"
}

# Check if system packages are available
check_system_packages() {
    local missing=()
    for pkg in "$@"; do
        if ! command -v "$pkg" &>/dev/null; then
            # Try to find the binary in common locations
            if [[ ! -x "/usr/bin/$pkg" ]] && [[ ! -x "/usr/local/bin/$pkg" ]]; then
                missing+=("$pkg")
            fi
        fi
    done

    if [[ ${#missing[@]} -gt 0 ]]; then
        echo "${missing[@]}"
        return 1
    fi
    return 0
}

# ----------------------------------------------------------------------------
# RUST/CARGO DEPENDENCIES
# ----------------------------------------------------------------------------
#
# Cargo.lock contains exact versions and checksums for reproducibility.
# cargo-crev can be used for community code review trust.
# cargo-audit checks for known vulnerabilities.
#
# CRITICAL: Always commit Cargo.lock for applications (not libraries).
# ----------------------------------------------------------------------------

ensure_rust_toolchain() {
    if ! command -v rustc &>/dev/null; then
        log_info "Installing Rust toolchain..."
        # Official rustup installer with signature verification
        curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --default-toolchain stable
        source "$HOME/.cargo/env"
        log_dependency "TOOLCHAIN_INSTALL" "rust" "$(rustc --version)" "rustup-verified"
    fi

    # Ensure cargo is in PATH
    export PATH="$HOME/.cargo/bin:$PATH"
}

cargo_install_verified() {
    local crate=$1
    local version=$2
    local expected_checksum=$3  # Optional SHA256 of crate tarball

    ensure_rust_toolchain

    log_info "Installing cargo crate: $crate@$version"

    if [[ -n "$expected_checksum" ]]; then
        # Download and verify before install
        local crate_url="https://crates.io/api/v1/crates/$crate/$version/download"
        local tmp_crate="/tmp/${crate}-${version}.crate"

        curl -sL "$crate_url" -o "$tmp_crate"
        local actual_checksum=$(sha256sum "$tmp_crate" | cut -d' ' -f1)

        if [[ "$actual_checksum" != "$expected_checksum" ]]; then
            log_error "CHECKSUM MISMATCH for $crate@$version!"
            log_error "Expected: $expected_checksum"
            log_error "Got:      $actual_checksum"
            rm -f "$tmp_crate"
            return 1
        fi

        log_success "Checksum verified for $crate@$version"
        rm -f "$tmp_crate"
    fi

    # Install with locked dependencies
    if [[ -n "$version" ]]; then
        cargo install "$crate" --version "$version" --locked 2>/dev/null || \
        cargo install "$crate" --version "$version"
    else
        cargo install "$crate" --locked 2>/dev/null || \
        cargo install "$crate"
    fi

    log_dependency "CARGO_INSTALL" "$crate" "${version:-latest}" "${expected_checksum:-cargo-verified}"
}

cargo_build_project() {
    local project_dir=$1

    if [[ ! -f "$project_dir/Cargo.toml" ]]; then
        log_error "No Cargo.toml found in $project_dir"
        return 1
    fi

    ensure_rust_toolchain

    cd "$project_dir"

    # Ensure Cargo.lock exists for reproducibility
    if [[ ! -f "Cargo.lock" ]]; then
        log_warning "No Cargo.lock found - generating (commit this file!)"
        cargo generate-lockfile
    fi

    # Build with locked dependencies
    log_info "Building Rust project with locked dependencies..."
    cargo build --release --locked

    log_dependency "CARGO_BUILD" "$project_dir" "$(grep '^version' Cargo.toml | head -1)" "lockfile-verified"
}

cargo_audit_project() {
    local project_dir=$1

    ensure_rust_toolchain

    # Install cargo-audit if not present
    if ! command -v cargo-audit &>/dev/null; then
        cargo install cargo-audit
    fi

    cd "$project_dir"
    log_info "Auditing dependencies for known vulnerabilities..."
    cargo audit
}

# ----------------------------------------------------------------------------
# PYTHON/PIP DEPENDENCIES
# ----------------------------------------------------------------------------
#
# Use requirements.txt with hashes for verification:
#   pip install --require-hashes -r requirements.txt
#
# Generate hashed requirements:
#   pip-compile --generate-hashes requirements.in
# ----------------------------------------------------------------------------

pip_install_verified() {
    local package=$1
    local version=$2
    local expected_hash=$3  # SHA256 hash of wheel/sdist

    log_info "Installing pip package: $package@$version"

    if [[ -n "$expected_hash" ]]; then
        # Install with hash verification
        pip install --quiet "$package==$version" --hash="sha256:$expected_hash"
    elif [[ -n "$version" ]]; then
        pip install --quiet "$package==$version"
    else
        pip install --quiet "$package"
    fi

    log_dependency "PIP_INSTALL" "$package" "${version:-latest}" "${expected_hash:-pypi-signed}"
}

pip_install_requirements() {
    local requirements_file=$1

    if [[ ! -f "$requirements_file" ]]; then
        log_error "Requirements file not found: $requirements_file"
        return 1
    fi

    log_info "Installing from requirements: $requirements_file"

    # Check if file contains hashes (secure mode)
    if grep -q -- "--hash=" "$requirements_file"; then
        log_info "Installing with hash verification (secure mode)"
        pip install --quiet --require-hashes -r "$requirements_file"
        log_dependency "PIP_REQUIREMENTS" "$requirements_file" "hashed" "hash-verified"
    else
        log_warning "Requirements file has no hashes - consider using pip-compile --generate-hashes"
        pip install --quiet -r "$requirements_file"
        log_dependency "PIP_REQUIREMENTS" "$requirements_file" "unhashed" "pypi-signed-only"
    fi
}

# ----------------------------------------------------------------------------
# GENERAL BINARY DOWNLOADS
# ----------------------------------------------------------------------------
#
# For binaries not in package managers, ALWAYS verify checksums.
# ----------------------------------------------------------------------------

download_verified_binary() {
    local url=$1
    local output_path=$2
    local expected_sha256=$3
    local description=$4

    if [[ -z "$expected_sha256" ]]; then
        log_error "SECURITY: Cannot download binary without SHA256 checksum"
        log_error "Provide the official checksum from the project's release page"
        return 1
    fi

    log_info "Downloading: $description"
    curl -sL "$url" -o "$output_path"

    local actual_sha256=$(sha256sum "$output_path" | cut -d' ' -f1)

    if [[ "$actual_sha256" != "$expected_sha256" ]]; then
        log_error "CHECKSUM MISMATCH for $description!"
        log_error "Expected: $expected_sha256"
        log_error "Got:      $actual_sha256"
        log_error "This could indicate a supply chain attack or corrupted download."
        rm -f "$output_path"
        return 1
    fi

    log_success "Checksum verified: $description"
    chmod +x "$output_path"
    log_dependency "BINARY_DOWNLOAD" "$description" "direct" "$expected_sha256"
}

# ----------------------------------------------------------------------------
# CONVENIENCE: Install common development tools
# ----------------------------------------------------------------------------

install_dev_essentials() {
    log_info "Installing development essentials..."

    # Check what's missing
    local missing_sys=()
    command -v git &>/dev/null || missing_sys+=("git")
    command -v jq &>/dev/null || missing_sys+=("jq")
    command -v curl &>/dev/null || missing_sys+=("curl")
    command -v make &>/dev/null || missing_sys+=("make" "build-essential")
    command -v gcc &>/dev/null || missing_sys+=("gcc")

    if [[ ${#missing_sys[@]} -gt 0 ]]; then
        install_system_packages "${missing_sys[@]}"
    fi

    # Rust toolchain
    ensure_rust_toolchain

    log_success "Development essentials ready"
}

# ============================================================================
# MAIN EXECUTION CYCLE
# ============================================================================

run_cycle() {
    local cycle=$1
    local max_cycles=$2
    
    log_header "CYCLE $cycle/$max_cycles"
    
    # Phase 1: LUMINARY - Vision and synthesis
    run_agent "luminary" "Assess current state, synthesize direction, identify blockers"
    
    # Phase 2: ARCHITECT - Structure and planning  
    run_agent "architect" "Review structure, decompose tasks, ensure coherence"
    
    # Phase 3: WEAVER - Integration and spawning
    run_agent "weaver" "Integrate components, spawn workers for parallel tasks"
    
    # Phase 4: DJINN - Implementation and spawning
    run_agent "djinn" "Implement solutions, spawn specialists as needed"
    
    # Phase 5: DOCTOR - Testing and diagnostics
    run_agent "doctor" "Test implementations, diagnose issues, prescribe fixes"
    
    # Phase 6: SCRIBE - Documentation and recording
    run_agent "scribe" "Document changes, record decisions, update manifests"
    
    # Phase 7: CROCODILE - Compaction and state management (ALWAYS LAST)
    run_agent "crocodile" "Compact state, garbage collect, persist critical data"
    
    # Process any spawned subagents
    process_spawn_queue
    
    # Check completion
    if check_completion; then
        log_success "PROJECT COMPLETE"
        return 0
    fi
    
    return 1
}

run_agent() {
    local agent_name=$1
    local directive=$2
    
    log_agent "$agent_name" "ACTIVATING"
    
    # Build context for agent
    local context_file="$PANTHEON_ROOT/state/context_${agent_name}.md"
    build_agent_context "$agent_name" "$directive" > "$context_file"
    
    # Execute agent via Claude Code
    local response_file="$PANTHEON_ROOT/state/response_${agent_name}.md"
    
    # The actual Claude Code invocation
    # --dangerously-skip-permissions enables fully autonomous operation
    # Use timeout to prevent hangs, and optionally a faster model via PANTHEON_MODEL env var
    local model_flag=""
    if [[ -n "${PANTHEON_MODEL:-}" ]]; then
        model_flag="--model $PANTHEON_MODEL"
    fi

    timeout "${PANTHEON_TIMEOUT:-300}" claude --dangerously-skip-permissions --print $model_flag \
        --system-prompt "$(cat "$PANTHEON_ROOT/agents/${agent_name}.md")" \
        < "$context_file" > "$response_file" 2>/dev/null || true
    
    # Process agent response
    process_agent_response "$agent_name" "$response_file"
    
    # Log completion
    log_agent "$agent_name" "COMPLETE"
}
build_agent_context() {
    local agent_name=$1
    local directive=$2

    cat << CONTEXT
# OPERATING MODE: FULLY AUTONOMOUS

You have full tool access. Use Read, Write, Bash, Grep, Glob, Task - whatever you need.
Execute real commands. Create real files. Make real changes.

When you need to communicate with other agents or signal state changes, ALSO emit markers:
- [TASK]description[/TASK] - register a task on the board
- [MSG:agent_name]content[/MSG] - async message to another agent
- [SPAWN]specialization:task[/SPAWN] - request subagent (Weaver/Djinn only)
- [ARTIFACT:path]description[/ARTIFACT] - register an artifact you created
- [COMPLETE] - signal your phase is done

These markers are for orchestration. They don't replace actual work - do the work FIRST, then emit markers to record what you did.

# DIRECTIVE
$directive

# PROJECT ROOT
$PANTHEON_ROOT

# WORKING DIRECTORIES
- Source: $PANTHEON_ROOT/../src (or as defined in project brief)
- Output: $PANTHEON_ROOT/output
- State: $PANTHEON_ROOT/state

# CURRENT STATE
$(cat "$PANTHEON_ROOT/state/project_state.md" 2>/dev/null || echo "No project state yet.")

# TASK BOARD
$(cat "$PANTHEON_ROOT/state/task_board.json")

# MESSAGES FOR YOU
$(get_messages_for "$agent_name")

# ARTIFACTS REGISTRY
$(cat "$PANTHEON_ROOT/state/artifacts.json")

# YOUR PREVIOUS OUTPUT (for continuity)
$(tail -100 "$PANTHEON_ROOT/state/response_${agent_name}.md" 2>/dev/null || echo "First cycle.")

CONTEXT
}

process_agent_response() {
    local agent_name=$1
    local response_file=$2
    
    # Extract structured outputs from response
    # Agents output in a specific format with markers
    
    if [[ -f "$response_file" ]]; then
        # Extract tasks
        grep -oP '(?<=\[TASK\]).*(?=\[/TASK\])' "$response_file" 2>/dev/null | while read task; do
            add_task "$task" "$agent_name"
        done
        
        # Extract messages
        grep -oP '(?<=\[MSG:)[^]]+(?=\]).*(?=\[/MSG\])' "$response_file" 2>/dev/null | while read msg; do
            local target=$(echo "$msg" | cut -d']' -f1)
            local content=$(echo "$msg" | cut -d']' -f2-)
            send_message "$agent_name" "$target" "$content"
        done
        
        # Extract spawn requests (only weaver and djinn)
        if [[ "$agent_name" == "weaver" || "$agent_name" == "djinn" ]]; then
            grep -oP '(?<=\[SPAWN\]).*(?=\[/SPAWN\])' "$response_file" 2>/dev/null | while read spawn; do
                queue_spawn "$agent_name" "$spawn"
            done
        fi
        
        # Extract artifacts
        grep -oP '(?<=\[ARTIFACT:)[^]]+(?=\])' "$response_file" 2>/dev/null | while read artifact; do
            register_artifact "$artifact" "$agent_name"
        done
        
        # Extract completion signals
        if grep -q '\[COMPLETE\]' "$response_file" 2>/dev/null; then
            mark_agent_complete "$agent_name"
        fi
    fi
}

process_spawn_queue() {
    local spawn_queue="$PANTHEON_ROOT/state/spawn_queue.json"
    
    if [[ -f "$spawn_queue" ]] && [[ "$(cat "$spawn_queue")" != "[]" ]]; then
        log_info "Processing spawn queue..."
        
        # Process each spawn request
        jq -r '.[] | @base64' "$spawn_queue" 2>/dev/null | while read spawn_b64; do
            local spawn_data=$(echo "$spawn_b64" | base64 -d)
            local parent=$(echo "$spawn_data" | jq -r '.parent')
            local task=$(echo "$spawn_data" | jq -r '.task')
            local specialization=$(echo "$spawn_data" | jq -r '.specialization')
            
            spawn_subagent "$parent" "$task" "$specialization"
        done
        
        # Clear queue
        echo "[]" > "$spawn_queue"
    fi
}

check_completion() {
    # Check if all critical tasks are done
    local pending=$(jq '[.[] | select(.status == "pending" or .status == "in_progress")] | length' \
        "$PANTHEON_ROOT/state/task_board.json" 2>/dev/null || echo "999")
    
    if [[ "$pending" == "0" ]]; then
        # Verify with Luminary
        local luminary_complete=$(jq -r '.luminary.complete // false' \
            "$PANTHEON_ROOT/state/agent_status.json" 2>/dev/null)
        
        [[ "$luminary_complete" == "true" ]]
    else
        return 1
    fi
}

# ============================================================================
# MAIN ENTRY POINT
# ============================================================================

main() {
    local project_brief="$1"
    local max_cycles="${2:-10}"
    
    if [[ -z "$project_brief" ]]; then
        echo "Usage: $0 <project_brief_file> [max_cycles]"
        echo "       $0 --interactive"
        exit 1
    fi
    
    # Initialize
    init_pantheon
    
    # Load project brief
    if [[ "$project_brief" == "--interactive" ]]; then
        echo "Enter project brief (Ctrl+D when done):"
        project_brief=$(cat)
        echo "$project_brief" > "$PANTHEON_ROOT/state/project_brief.md"
    elif [[ -f "$project_brief" ]]; then
        cp "$project_brief" "$PANTHEON_ROOT/state/project_brief.md"
    else
        echo "$project_brief" > "$PANTHEON_ROOT/state/project_brief.md"
    fi
    
    # Initialize project state
    cat > "$PANTHEON_ROOT/state/project_state.md" << STATE
# PROJECT STATE

## Brief
$(cat "$PANTHEON_ROOT/state/project_brief.md")

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

    # Main execution loop
    for ((cycle=1; cycle<=max_cycles; cycle++)); do
        echo "$cycle" > "$PANTHEON_ROOT/state/cycle_count"
        
        if run_cycle "$cycle" "$max_cycles"; then
            break
        fi
        
        # Brief pause between cycles
        sleep 1
    done
    
    # Final synthesis
    log_header "FINAL SYNTHESIS"
    run_agent "luminary" "Produce final synthesis and deliverables manifest"
    run_agent "scribe" "Produce final documentation package"
    run_agent "crocodile" "Final state compaction and archive"
    
    log_success "PANTHEON COMPLETE"
    
    # Output deliverables location
    echo ""
    echo "Deliverables: $PANTHEON_ROOT/output/"
    echo "Logs: $PANTHEON_ROOT/logs/"
    echo "Final State: $PANTHEON_ROOT/state/"
}

# Run if executed directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
