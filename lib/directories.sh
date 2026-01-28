#!/bin/bash
# =============================================================================
# DIRECTORY MANAGEMENT LIBRARY - RIGID STRUCTURE
# =============================================================================
#
# Enforces a STRICT, REPEATABLE directory structure for Pantheon.
#
# DESIGN PRINCIPLE:
# -----------------
# Pantheon's internal machinery is COMPLETELY SEPARATE from project output.
# The project being built is self-contained and can be extracted cleanly.
#
# THE RIGID STRUCTURE:
# --------------------
# $PANTHEON_ROOT/
# │
# ├── .pantheon/                 # PANTHEON SYSTEM (hidden, internal)
# │   ├── state/                 # All state files
# │   │   ├── task_board.json
# │   │   ├── message_queue.json
# │   │   ├── artifacts.json
# │   │   ├── agent_status.json
# │   │   ├── verification_results.json
# │   │   ├── quality_gate.json
# │   │   ├── project_brief.md
# │   │   ├── project_state.md
# │   │   └── checkpoints/
# │   ├── logs/                  # All logs
# │   │   ├── build_verification.log
# │   │   ├── test_verification.log
# │   │   ├── smoke_verification.log
# │   │   ├── quality_gate.log
# │   │   └── agent_*.log
# │   ├── spawn/                 # Spawn work directories
# │   │   ├── archive/
# │   │   └── cache/
# │   └── artifacts/             # Cycle reports, internal artifacts
# │       ├── CYCLE_*_REPORT.md
# │       └── scribe_handoffs/
# │
# ├── agents/                    # Agent prompts (version controlled)
# │   ├── luminary.md
# │   ├── architect.md
# │   ├── weaver.md
# │   ├── djinn.md
# │   ├── doctor.md
# │   ├── scribe.md
# │   └── crocodile.md
# │
# ├── lib/                       # Library scripts (version controlled)
# │   ├── state.sh
# │   ├── messaging.sh
# │   ├── spawner.sh
# │   ├── models.sh
# │   ├── context.sh
# │   ├── conditional.sh
# │   ├── directories.sh
# │   ├── verify.sh
# │   ├── quality.sh
# │   ├── colors.sh
# │   └── logging.sh
# │
# ├── projects/                  # PROJECT OUTPUT (clean, extractable)
# │   └── $PROJECT_NAME/         # The actual project being built
# │       ├── src/               # Source code
# │       ├── tests/             # Test files
# │       ├── docs/              # Documentation
# │       └── Cargo.toml         # (or package.json, etc.)
# │
# ├── orchestrator.sh            # Main orchestrator (version controlled)
# ├── pantheon.sh                # CLI entry point (version controlled)
# └── pantheon.conf              # Configuration (user-editable)
#
# KEY PRINCIPLES:
# ---------------
# 1. .pantheon/ contains ALL runtime state/logs - can be deleted to reset
# 2. projects/ contains ONLY the project output - can be extracted cleanly
# 3. agents/ and lib/ are version controlled Pantheon code
# 4. NO project files in .pantheon/, NO state files in projects/
#
# =============================================================================

# Robust path resolution - works when sourced or executed directly
if [[ -z "$PANTHEON_ROOT" ]]; then
    # Try to find the root from this script's location
    if [[ -f "${BASH_SOURCE[0]}" ]]; then
        PANTHEON_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
    elif [[ -f "$0" ]] && [[ "$0" != *"bash"* ]]; then
        PANTHEON_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
    else
        # Fallback to current directory if we can find pantheon markers
        if [[ -f "./orchestrator.sh" ]] || [[ -d "./agents" ]]; then
            PANTHEON_ROOT="$(pwd)"
        else
            echo "ERROR: Cannot determine PANTHEON_ROOT. Set it explicitly." >&2
            PANTHEON_ROOT="/tmp"  # Safe fallback
        fi
    fi
fi
export PANTHEON_ROOT

# =============================================================================
# RIGID DIRECTORY DEFINITIONS
# =============================================================================

# System directories (internal Pantheon machinery)
PANTHEON_SYSTEM_DIR="$PANTHEON_ROOT/.pantheon"
PANTHEON_STATE_DIR="$PANTHEON_SYSTEM_DIR/state"
PANTHEON_LOGS_DIR="$PANTHEON_SYSTEM_DIR/logs"
PANTHEON_SPAWN_DIR="$PANTHEON_SYSTEM_DIR/spawn"
PANTHEON_ARTIFACTS_DIR="$PANTHEON_SYSTEM_DIR/artifacts"

# Project output directory (clean, extractable)
PANTHEON_PROJECTS_DIR="$PANTHEON_ROOT/projects"

# Export for use by other scripts
export PANTHEON_SYSTEM_DIR PANTHEON_STATE_DIR PANTHEON_LOGS_DIR
export PANTHEON_SPAWN_DIR PANTHEON_ARTIFACTS_DIR PANTHEON_PROJECTS_DIR

# Legacy compatibility (transition period)
# These point to new locations but keep old variable names working
export PANTHEON_LEGACY_MODE="${PANTHEON_LEGACY_MODE:-true}"

# =============================================================================
# PROJECT DETECTION
# =============================================================================

# Detect project name from brief or existing directories
detect_project_name() {
    # Check new location first
    local brief_file="$PANTHEON_STATE_DIR/project_brief.md"
    # Legacy fallback
    [[ ! -f "$brief_file" ]] && brief_file="$PANTHEON_STATE_DIR/project_brief.md"

    local project_name=""

    # Check stored project name
    local name_file="$PANTHEON_STATE_DIR/project_name"
    [[ ! -f "$name_file" ]] && name_file="$PANTHEON_STATE_DIR/project_name"
    if [[ -f "$name_file" ]]; then
        project_name=$(cat "$name_file" 2>/dev/null | tr -d '[:space:]')
        [[ -n "$project_name" ]] && echo "$project_name" && return
    fi

    # Try to extract from brief (look for "Build X" or project name patterns)
    if [[ -f "$brief_file" ]]; then
        # Look for patterns like "Build rscan" or "Create tamagotchi"
        project_name=$(grep -oP '(?i)(?:build|create|implement)\s+(\w+)' "$brief_file" | head -1 | awk '{print $NF}' | tr '[:upper:]' '[:lower:]')
    fi

    # If not found in brief, look for existing project directories
    if [[ -z "$project_name" ]]; then
        # Check new projects/ location first
        for dir in "$PANTHEON_PROJECTS_DIR"/*/; do
            [[ -d "$dir" ]] || continue
            local dirname=$(basename "$dir")
            # Check if it looks like a project
            if [[ -d "$dir/src" ]] || [[ -f "$dir/Cargo.toml" ]] || [[ -f "$dir/package.json" ]] || [[ -f "$dir/pyproject.toml" ]]; then
                project_name="$dirname"
                break
            fi
        done

        # Legacy: check root directory (for backward compatibility)
        if [[ -z "$project_name" ]]; then
            for dir in "$PANTHEON_ROOT"/*/; do
                local dirname=$(basename "$dir")
                # Skip ALL Pantheon system directories
                case "$dirname" in
                    .pantheon|state|logs|spawn|output|artifacts|agents|tasks|docs|archive|examples|lib|projects)
                        continue
                        ;;
                    *)
                        # Check if it looks like a project
                        if [[ -d "$dir/src" ]] || [[ -f "$dir/Cargo.toml" ]] || [[ -f "$dir/package.json" ]] || [[ -f "$dir/pyproject.toml" ]]; then
                            project_name="$dirname"
                            break
                        fi
                        ;;
                esac
            done
        fi
    fi

    echo "$project_name"
}

# Get the canonical project directory
get_project_dir() {
    local project_name=$(detect_project_name)
    if [[ -z "$project_name" ]]; then
        echo ""
        return
    fi

    # Check new location first
    if [[ -d "$PANTHEON_PROJECTS_DIR/$project_name" ]]; then
        echo "$PANTHEON_PROJECTS_DIR/$project_name"
        return
    fi

    # Legacy: check root directory
    if [[ -d "$PANTHEON_ROOT/$project_name" ]]; then
        echo "$PANTHEON_ROOT/$project_name"
        return
    fi

    # Return expected location (may not exist yet)
    echo "$PANTHEON_PROJECTS_DIR/$project_name"
}

# =============================================================================
# DIRECTORY STRUCTURE ENFORCEMENT
# =============================================================================

# Initialize Pantheon system directories (rigid structure)
init_pantheon_directories() {
    echo "## Initializing Pantheon Directory Structure"

    # Create system directories
    mkdir -p "$PANTHEON_STATE_DIR"
    mkdir -p "$PANTHEON_STATE_DIR/checkpoints"
    mkdir -p "$PANTHEON_STATE_DIR/archive"
    mkdir -p "$PANTHEON_LOGS_DIR"
    mkdir -p "$PANTHEON_SPAWN_DIR"
    mkdir -p "$PANTHEON_SPAWN_DIR/archive"
    mkdir -p "$PANTHEON_SPAWN_DIR/cache"
    mkdir -p "$PANTHEON_ARTIFACTS_DIR"
    mkdir -p "$PANTHEON_ARTIFACTS_DIR/scribe_handoffs"

    # Create projects directory
    mkdir -p "$PANTHEON_PROJECTS_DIR"

    echo "System directories created at: $PANTHEON_SYSTEM_DIR"
    echo "Projects directory created at: $PANTHEON_PROJECTS_DIR"
}

# Initialize project directory structure (inside projects/)
init_project_directory() {
    local project_name=$1

    if [[ -z "$project_name" ]]; then
        echo "[WARN] No project name provided" >&2
        return 1
    fi

    # Project goes in projects/ directory
    local project_dir="$PANTHEON_PROJECTS_DIR/$project_name"

    # Create project directory structure
    mkdir -p "$project_dir"
    mkdir -p "$project_dir/src"
    mkdir -p "$project_dir/tests"
    mkdir -p "$project_dir/docs"

    # Store project name in state (ONLY in .pantheon/state/)
    mkdir -p "$PANTHEON_STATE_DIR"
    echo "$project_name" > "$PANTHEON_STATE_DIR/project_name"

    echo "$project_dir"
}

# Validate directory structure (rigid enforcement)
validate_directory_structure() {
    local errors=0
    local warnings=0

    echo "## Directory Structure Validation (Rigid Mode)"
    echo "Timestamp: $(date -Iseconds)"
    echo ""

    # -------------------------------------------------------------------------
    # CHECK 1: Projects in wrong locations
    # -------------------------------------------------------------------------
    echo "### Checking for misplaced projects..."

    local wrong_locations=(
        "$PANTHEON_ROOT/artifacts"
        "$PANTHEON_ROOT/output"
        "$PANTHEON_ROOT/state"
        "$PANTHEON_ROOT/.pantheon/artifacts"
        "$PANTHEON_ROOT/.pantheon/state"
    )

    for wrong_loc in "${wrong_locations[@]}"; do
        [[ -d "$wrong_loc" ]] || continue
        for subdir in "$wrong_loc"/*/; do
            [[ -d "$subdir" ]] || continue
            local dirname=$(basename "$subdir")

            # Check if it looks like a misplaced project
            if [[ -f "$subdir/Cargo.toml" ]] || [[ -f "$subdir/package.json" ]] || [[ -d "$subdir/src" ]]; then
                echo "**ERROR**: Project '$dirname' found in wrong location: $wrong_loc"
                echo "  Should be: $PANTHEON_PROJECTS_DIR/$dirname"
                ((errors++))
            fi
        done
    done

    # -------------------------------------------------------------------------
    # CHECK 2: Duplicate project directories
    # -------------------------------------------------------------------------
    echo ""
    echo "### Checking for duplicates..."

    local project_name=$(detect_project_name)
    if [[ -n "$project_name" ]]; then
        local locations=()

        # Check all possible locations
        for loc in \
            "$PANTHEON_PROJECTS_DIR/$project_name" \
            "$PANTHEON_ROOT/$project_name" \
            "$PANTHEON_ARTIFACTS_DIR/$project_name" \
            "$PANTHEON_PROJECTS_DIR/$project_name"; do
            if [[ -d "$loc" ]]; then
                locations+=("$loc")
            fi
        done

        if [[ ${#locations[@]} -gt 1 ]]; then
            echo "**ERROR**: Project '$project_name' exists in MULTIPLE locations:"
            for loc in "${locations[@]}"; do
                echo "  - $loc"
            done
            echo "  Canonical location should be: $PANTHEON_PROJECTS_DIR/$project_name"
            ((errors++))
        fi
    fi

    # -------------------------------------------------------------------------
    # CHECK 3: Required Pantheon system directories
    # -------------------------------------------------------------------------
    echo ""
    echo "### Checking Pantheon system directories..."

    local required_dirs=(
        "$PANTHEON_STATE_DIR"
        "$PANTHEON_LOGS_DIR"
        "$PANTHEON_SPAWN_DIR"
        "$PANTHEON_ARTIFACTS_DIR"
        "$PANTHEON_PROJECTS_DIR"
    )

    for required in "${required_dirs[@]}"; do
        if [[ ! -d "$required" ]]; then
            echo "**WARNING**: Missing system directory: $required"
            ((warnings++))
        fi
    done

    # -------------------------------------------------------------------------
    # CHECK 4: Empty directories within Pantheon (cleanup candidates)
    # -------------------------------------------------------------------------
    echo ""
    echo "### Checking for empty directories within Pantheon..."

    local empty_dirs=()
    while IFS= read -r -d '' dir; do
        # Must be within PANTHEON_ROOT
        [[ "$dir" != "$PANTHEON_ROOT"/* ]] && continue

        # Don't flag required directories as empty
        local is_required=false
        for req in "${required_dirs[@]}"; do
            [[ "$dir" == "$req"* ]] || [[ "$dir" == "$req" ]] && is_required=true && break
        done

        if ! $is_required; then
            # Check if directory is truly empty
            if [[ -z "$(ls -A "$dir" 2>/dev/null)" ]]; then
                empty_dirs+=("$dir")
            fi
        fi
    done < <(find "$PANTHEON_ROOT" -maxdepth 5 -type d -empty \
        -not -path "*/.git/*" \
        -not -path "*/node_modules/*" \
        -not -path "*/target/*" \
        -print0 2>/dev/null)

    if [[ ${#empty_dirs[@]} -gt 0 ]]; then
        echo "**WARNING**: Found ${#empty_dirs[@]} empty directories:"
        for dir in "${empty_dirs[@]:0:10}"; do  # Show max 10
            echo "  - $dir"
        done
        [[ ${#empty_dirs[@]} -gt 10 ]] && echo "  ... and $((${#empty_dirs[@]} - 10)) more"
        ((warnings+=${#empty_dirs[@]}))
    fi

    # -------------------------------------------------------------------------
    # CHECK 5: Extraneous files in root
    # -------------------------------------------------------------------------
    echo ""
    echo "### Checking for extraneous files in root..."

    local allowed_in_root=(
        "orchestrator.sh" "pantheon.sh" "pantheon.conf"
        "README.md" "LICENSE" ".gitignore" ".git"
        "agents" "lib" "projects" ".pantheon"
        # Legacy (will be migrated)
        "state" "logs" "spawn" "output" "artifacts" "tasks"
    )

    for item in "$PANTHEON_ROOT"/*; do
        local basename=$(basename "$item")
        local is_allowed=false

        for allowed in "${allowed_in_root[@]}"; do
            [[ "$basename" == "$allowed" ]] && is_allowed=true && break
        done

        # Check if it's a project (legacy location)
        if ! $is_allowed && [[ -d "$item" ]]; then
            if [[ -f "$item/Cargo.toml" ]] || [[ -f "$item/package.json" ]] || [[ -d "$item/src" ]]; then
                echo "**WARNING**: Project '$basename' in legacy location (root)"
                echo "  Should be moved to: $PANTHEON_PROJECTS_DIR/$basename"
                ((warnings++))
                is_allowed=true  # It's allowed for now (legacy)
            fi
        fi

        if ! $is_allowed; then
            echo "**WARNING**: Unexpected item in root: $basename"
            ((warnings++))
        fi
    done

    echo ""
    echo "=========================================="
    echo "Validation complete: $errors errors, $warnings warnings"
    echo "=========================================="

    return $errors
}

# Fix directory structure (migrate to rigid structure + cleanup)
fix_directory_structure() {
    local fixed=0
    local cleaned=0

    echo "## Fixing Directory Structure"
    echo "Timestamp: $(date -Iseconds)"
    echo ""

    # -------------------------------------------------------------------------
    # STEP 1: Create Pantheon system directories
    # -------------------------------------------------------------------------
    echo "### Step 1: Creating Pantheon system directories..."
    init_pantheon_directories
    ((fixed++))

    # -------------------------------------------------------------------------
    # STEP 2: Migrate legacy state files to .pantheon/
    # -------------------------------------------------------------------------
    echo ""
    echo "### Step 2: Migrating state files..."

    local legacy_state="$PANTHEON_ROOT/state"
    if [[ -d "$legacy_state" ]] && [[ "$legacy_state" != "$PANTHEON_STATE_DIR" ]]; then
        for file in "$legacy_state"/*.json "$legacy_state"/*.md "$legacy_state"/project_name; do
            [[ -f "$file" ]] || continue
            local basename=$(basename "$file")
            if [[ ! -f "$PANTHEON_STATE_DIR/$basename" ]]; then
                echo "  Copying: $basename -> $PANTHEON_STATE_DIR/"
                cp "$file" "$PANTHEON_STATE_DIR/"
                ((fixed++))
            fi
        done
    fi

    # -------------------------------------------------------------------------
    # STEP 3: Move misplaced projects to projects/
    # -------------------------------------------------------------------------
    echo ""
    echo "### Step 3: Moving misplaced projects..."

    local project_name=$(detect_project_name)

    # Check wrong locations
    local wrong_locations=(
        "$PANTHEON_ROOT/artifacts"
        "$PANTHEON_ROOT/output"
    )

    for wrong_loc in "${wrong_locations[@]}"; do
        [[ -d "$wrong_loc" ]] || continue
        for subdir in "$wrong_loc"/*/; do
            [[ -d "$subdir" ]] || continue
            local dirname=$(basename "$subdir")

            # Check if it's a project
            if [[ -f "$subdir/Cargo.toml" ]] || [[ -f "$subdir/package.json" ]] || [[ -d "$subdir/src" ]]; then
                if [[ ! -d "$PANTHEON_PROJECTS_DIR/$dirname" ]]; then
                    echo "  Moving: $subdir -> $PANTHEON_PROJECTS_DIR/$dirname"
                    mv "$subdir" "$PANTHEON_PROJECTS_DIR/$dirname"
                    ((fixed++))
                else
                    echo "  **CONFLICT**: $dirname exists in both $wrong_loc and projects/"
                    echo "  Manual intervention required"
                fi
            fi
        done
    done

    # Move legacy project from root to projects/
    if [[ -n "$project_name" ]] && [[ -d "$PANTHEON_ROOT/$project_name" ]]; then
        if [[ ! -d "$PANTHEON_PROJECTS_DIR/$project_name" ]]; then
            echo "  Moving: $PANTHEON_ROOT/$project_name -> $PANTHEON_PROJECTS_DIR/"
            mv "$PANTHEON_ROOT/$project_name" "$PANTHEON_PROJECTS_DIR/"
            ((fixed++))
        fi
    fi

    # -------------------------------------------------------------------------
    # STEP 4: Clean up empty directories (ONLY within Pantheon)
    # -------------------------------------------------------------------------
    echo ""
    echo "### Step 4: Cleaning up empty directories within Pantheon..."

    # Protected directories that should not be removed even if empty
    local protected_dirs=(
        "$PANTHEON_STATE_DIR"
        "$PANTHEON_LOGS_DIR"
        "$PANTHEON_SPAWN_DIR"
        "$PANTHEON_ARTIFACTS_DIR"
        "$PANTHEON_PROJECTS_DIR"
        "$PANTHEON_ROOT/agents"
        "$PANTHEON_ROOT/lib"
        "$PANTHEON_ROOT/.pantheon"
        "$PANTHEON_ROOT/state"
        "$PANTHEON_ROOT/logs"
        "$PANTHEON_ROOT/spawn"
        "$PANTHEON_ROOT/output"
        "$PANTHEON_ROOT/artifacts"
    )

    # Only search within Pantheon root, max depth to avoid going into system dirs
    # Also exclude .git, node_modules, target directories
    while IFS= read -r -d '' empty_dir; do
        # Must be within PANTHEON_ROOT
        [[ "$empty_dir" != "$PANTHEON_ROOT"/* ]] && continue

        local is_protected=false
        for protected in "${protected_dirs[@]}"; do
            # Check if empty_dir is the protected dir or a parent/child of it
            if [[ "$protected" == "$empty_dir"* ]] || [[ "$empty_dir" == "$protected" ]] || [[ "$empty_dir" == "$protected"/* ]]; then
                is_protected=true
                break
            fi
        done

        if ! $is_protected; then
            # Double-check it's truly empty and within Pantheon
            if [[ -z "$(ls -A "$empty_dir" 2>/dev/null)" ]]; then
                echo "  Removing empty: $empty_dir"
                rmdir "$empty_dir" 2>/dev/null && ((cleaned++))
            fi
        fi
    done < <(find "$PANTHEON_ROOT" -maxdepth 5 -type d -empty \
        -not -path "*/.git/*" \
        -not -path "*/node_modules/*" \
        -not -path "*/target/*" \
        -print0 2>/dev/null)

    # -------------------------------------------------------------------------
    # STEP 5: Clean up legacy empty directories
    # -------------------------------------------------------------------------
    echo ""
    echo "### Step 5: Cleaning legacy directories..."

    local legacy_dirs=("tasks" "docs" "archive" "examples")
    for legacy in "${legacy_dirs[@]}"; do
        if [[ -d "$PANTHEON_ROOT/$legacy" ]]; then
            if [[ -z "$(ls -A "$PANTHEON_ROOT/$legacy" 2>/dev/null)" ]]; then
                echo "  Removing empty legacy: $PANTHEON_ROOT/$legacy"
                rmdir "$PANTHEON_ROOT/$legacy" 2>/dev/null && ((cleaned++))
            fi
        fi
    done

    echo ""
    echo "=========================================="
    echo "Fixed $fixed issues, cleaned $cleaned empty directories"
    echo "=========================================="
    return 0
}

# =============================================================================
# PATH HELPERS
# =============================================================================

# Convert relative path to absolute within project
resolve_project_path() {
    local relative_path=$1
    local project_dir=$(get_project_dir)

    if [[ -z "$project_dir" ]]; then
        echo "$relative_path"
        return
    fi

    # If already absolute, return as-is
    if [[ "$relative_path" == /* ]]; then
        echo "$relative_path"
        return
    fi

    # Make relative to project directory
    echo "$project_dir/$relative_path"
}

# Get paths for context building
get_project_paths() {
    local project_dir=$(get_project_dir)
    local project_name=$(detect_project_name)

    cat << EOF
PROJECT_NAME=$project_name
PROJECT_DIR=$project_dir
SOURCE_DIR=$project_dir/src
TEST_DIR=$project_dir/tests
OUTPUT_DIR=$PANTHEON_ROOT/output
ARTIFACTS_DIR=$PANTHEON_ROOT/artifacts
EOF
}

# =============================================================================
# ARTIFACT LOCATION HELPERS
# =============================================================================

# Determine correct location for a file based on its type
get_canonical_path() {
    local filename=$1
    local file_type=${2:-"source"}  # source, test, doc, output
    local project_dir=$(get_project_dir)

    case "$file_type" in
        source)
            echo "$project_dir/src/$filename"
            ;;
        test)
            echo "$project_dir/tests/$filename"
            ;;
        doc|documentation)
            echo "$project_dir/docs/$filename"
            ;;
        output|deliverable)
            echo "$PANTHEON_PROJECTS_DIR/$filename"
            ;;
        report|artifact)
            echo "$PANTHEON_ARTIFACTS_DIR/$filename"
            ;;
        *)
            echo "$project_dir/$filename"
            ;;
    esac
}
