#!/bin/bash
# =============================================================================
# MODEL SELECTION LIBRARY
# =============================================================================
#
# WHAT THIS DOES:
# ---------------
# This is the single most important optimization in the entire system.
# Instead of using the same expensive model for everything, we route
# each task to the cheapest model that can handle it competently.
#
# WHY THIS MATTERS:
# -----------------
# Claude Haiku is ~10-20x cheaper than Sonnet in terms of rate limits.
# Most orchestration tasks (coordination, documentation, state management)
# don't need Sonnet's reasoning power. By using Haiku for these, we can
# run 10-20x more operations before hitting rate limits.
#
# THE TIERING PHILOSOPHY:
# -----------------------
# Tier 1 (Opus/Sonnet): Complex reasoning, novel problem-solving, architecture
# Tier 2 (Sonnet):      Code generation, debugging, technical analysis
# Tier 3 (Haiku):       Coordination, formatting, documentation, state ops
#
# We default to Haiku (cheapest) and only upgrade when the task demands it.
#
# CONFIGURATION:
# --------------
# Override defaults via environment variables:
#   PANTHEON_MODEL_TIER1="claude-sonnet-4-20250514"   # Strategic work
#   PANTHEON_MODEL_TIER2="claude-sonnet-4-20250514"   # Technical work  
#   PANTHEON_MODEL_TIER3="claude-haiku-4-20250514"    # Routine work
#
# =============================================================================

# Model tier definitions (override via environment)
# Use aliases: sonnet, opus, haiku (or full model names)
MODEL_TIER0="${PANTHEON_MODEL_TIER0:-opus}"     # Critical - complex diagnostics (Doctor)
MODEL_TIER1="${PANTHEON_MODEL_TIER1:-sonnet}"   # Strategic - vision and planning
MODEL_TIER2="${PANTHEON_MODEL_TIER2:-sonnet}"   # Technical - implementation
MODEL_TIER3="${PANTHEON_MODEL_TIER3:-haiku}"    # Routine - coordination, docs

# =============================================================================
# AGENT MODEL SELECTION
# =============================================================================
#
# Each agent has a "baseline" model based on their typical workload.
# However, we can dynamically upgrade based on the specific task.
#
# Agent Baseline Assignments:
#
#   LUMINARY (Tier 1 - Sonnet)
#   - Why: Makes strategic decisions, synthesizes complex information
#   - Downgrade conditions: None - always needs full reasoning
#
#   ARCHITECT (Tier 2 - Sonnet)
#   - Why: System design requires understanding complex relationships
#   - Downgrade conditions: Simple task decomposition only
#
#   DJINN (Tier 2 - Sonnet)
#   - Why: Writes production code, needs to understand context
#   - Downgrade conditions: Boilerplate/template generation
#
#   DOCTOR (Tier 2 - Sonnet)
#   - Why: Debugging requires reasoning about code behavior
#   - Downgrade conditions: Running existing tests only
#
#   WEAVER (Tier 3 - Haiku)
#   - Why: Coordination is mostly about routing and scheduling
#   - Upgrade conditions: Complex integration requiring reasoning
#
#   SCRIBE (Tier 3 - Haiku)
#   - Why: Documentation is largely templated/structured
#   - Upgrade conditions: Writing novel technical explanations
#
#   CROCODILE (Tier 3 - Haiku)
#   - Why: State management is mechanical JSON operations
#   - Upgrade conditions: None - always routine
#
# =============================================================================

get_model_for_agent() {
    local agent=$1
    local task_complexity=${2:-"normal"}  # "simple", "normal", "complex"
    
    case "$agent" in
        # -----------------------------------------------------------------
        # TIER 1: Always needs strong reasoning
        # -----------------------------------------------------------------
        luminary)
            # Luminary makes strategic decisions - never downgrade
            echo "$MODEL_TIER1"
            ;;
        
        # -----------------------------------------------------------------
        # TIER 2: Technical work, can sometimes downgrade
        # -----------------------------------------------------------------
        architect)
            case "$task_complexity" in
                simple)  echo "$MODEL_TIER3" ;;  # Simple task listing
                *)       echo "$MODEL_TIER2" ;;  # Design work needs reasoning
            esac
            ;;
        
        djinn)
            case "$task_complexity" in
                simple)  echo "$MODEL_TIER3" ;;  # Boilerplate generation
                *)       echo "$MODEL_TIER2" ;;  # Real implementation
            esac
            ;;
        
        doctor)
            # Doctor gets Opus for complex diagnostics - they were timing out on Sonnet
            case "$task_complexity" in
                simple)  echo "$MODEL_TIER3" ;;  # Just running simple tests
                normal)  echo "$MODEL_TIER2" ;;  # Standard test suites
                complex) echo "$MODEL_TIER0" ;;  # Complex debugging - use Opus
                *)       echo "$MODEL_TIER0" ;;  # Default to Opus for thorough analysis
            esac
            ;;

        aletheia)
            # Aletheia ALWAYS runs on Opus - she is the final arbiter of truth
            # Full spawn privileges, no budget limits, maximum reasoning capability
            echo "$MODEL_TIER0"
            ;;

        # -----------------------------------------------------------------
        # TIER 3: Coordination/routine work, can sometimes upgrade
        # -----------------------------------------------------------------
        weaver)
            case "$task_complexity" in
                complex) echo "$MODEL_TIER2" ;;  # Complex integration
                *)       echo "$MODEL_TIER3" ;;  # Normal coordination
            esac
            ;;
        
        scribe)
            case "$task_complexity" in
                complex) echo "$MODEL_TIER2" ;;  # Novel technical writing
                *)       echo "$MODEL_TIER3" ;;  # Standard documentation
            esac
            ;;
        
        crocodile)
            # Crocodile does mechanical state ops - always use cheapest
            echo "$MODEL_TIER3"
            ;;
        
        # -----------------------------------------------------------------
        # SPAWNED WORKERS: Default to Haiku, upgrade for specific types
        # -----------------------------------------------------------------
        spawn:algorithm|spawn:security|spawn:refactor)
            # These need reasoning
            echo "$MODEL_TIER2"
            ;;
        
        spawn:*)
            # Most spawns are focused tasks Haiku can handle
            echo "$MODEL_TIER3"
            ;;
        
        # -----------------------------------------------------------------
        # DEFAULT: Unknown agent, use middle tier to be safe
        # -----------------------------------------------------------------
        *)
            echo "$MODEL_TIER2"
            ;;
    esac
}

# =============================================================================
# TASK COMPLEXITY DETECTION
# =============================================================================
#
# We can analyze the task/directive to guess complexity:
# - Simple: Short directives, single operations, boilerplate
# - Normal: Standard work, multiple steps
# - Complex: Novel problems, architectural decisions, debugging
#
# This is heuristic - when in doubt, assume normal.
#
# =============================================================================

detect_task_complexity() {
    local directive="$1"
    local agent="$2"
    
    # Convert to lowercase for matching
    local lower_directive=$(echo "$directive" | tr '[:upper:]' '[:lower:]')
    
    # -----------------------------------------------------------------
    # SIMPLE indicators (use Haiku)
    # -----------------------------------------------------------------
    # These patterns suggest routine/mechanical work
    local simple_patterns=(
        "list "
        "show "
        "format "
        "template"
        "boilerplate"
        "stub"
        "placeholder"
        "run tests"
        "execute tests"
        "check status"
        "update changelog"
        "compact state"
        "archive"
        "cleanup"
    )
    
    for pattern in "${simple_patterns[@]}"; do
        if [[ "$lower_directive" == *"$pattern"* ]]; then
            echo "simple"
            return
        fi
    done
    
    # -----------------------------------------------------------------
    # COMPLEX indicators (use Sonnet)
    # -----------------------------------------------------------------
    # These patterns suggest novel reasoning required
    local complex_patterns=(
        "design"
        "architect"
        "debug"
        "diagnose"
        "analyze"
        "optimize"
        "refactor"
        "security"
        "algorithm"
        "integrate"
        "synthesize"
        "decide"
        "evaluate"
        "complex"
        "critical"
        "production"
    )
    
    for pattern in "${complex_patterns[@]}"; do
        if [[ "$lower_directive" == *"$pattern"* ]]; then
            echo "complex"
            return
        fi
    done
    
    # Default to normal
    echo "normal"
}

# =============================================================================
# MODEL SELECTION WITH LOGGING
# =============================================================================
#
# Wrapper that logs model selection for debugging/optimization.
# Use this instead of calling get_model_for_agent directly.
#
# =============================================================================

select_model() {
    local agent=$1
    local directive="$2"
    
    # Detect complexity from directive
    local complexity=$(detect_task_complexity "$directive" "$agent")
    
    # Get appropriate model
    local model=$(get_model_for_agent "$agent" "$complexity")
    
    # Log selection for analysis
    local log_file="${PANTHEON_LOGS_DIR:-$PANTHEON_ROOT/.pantheon/logs}/model_selection.log"
    mkdir -p "$(dirname "$log_file")"
    echo "[$(date -Iseconds)] agent=$agent complexity=$complexity model=$model" >> "$log_file"
    
    echo "$model"
}

# =============================================================================
# SPAWN MODEL SELECTION
# =============================================================================
#
# Spawned workers need special handling because:
# 1. They're the biggest token sink (many spawns per cycle)
# 2. Most spawns are focused, single-purpose tasks
# 3. Haiku can handle most spawn work effectively
#
# We only upgrade spawns for:
# - Algorithm work (needs reasoning about complexity)
# - Security work (needs reasoning about attack vectors)
# - Refactoring (needs understanding of code structure)
# - Debugging (needs reasoning about behavior)
#
# =============================================================================

get_model_for_spawn() {
    local specialization=$1
    local task="$2"
    
    # Check if task itself indicates complexity
    local complexity=$(detect_task_complexity "$task" "spawn")
    
    # Specializations that always need Sonnet
    case "$specialization" in
        algorithm|security|refactor|debug)
            echo "$MODEL_TIER2"
            return
            ;;
    esac
    
    # Otherwise, use complexity detection
    case "$complexity" in
        complex) echo "$MODEL_TIER2" ;;
        *)       echo "$MODEL_TIER3" ;;
    esac
}

# =============================================================================
# COST ESTIMATION (for logging/monitoring)
# =============================================================================
#
# Rough token cost multipliers relative to Haiku:
#   Haiku:  1x (baseline)
#   Sonnet: 5x
#   Opus:   25x
#
# These are approximate and for monitoring purposes only.
#
# =============================================================================

get_model_cost_multiplier() {
    local model=$1
    
    case "$model" in
        *haiku*)  echo "1" ;;
        *sonnet*) echo "5" ;;
        *opus*)   echo "25" ;;
        *)        echo "5" ;;  # Unknown, assume middle
    esac
}

log_estimated_cost() {
    local model=$1
    local agent=$2
    local input_tokens=${3:-1000}  # Rough estimate if not provided
    
    local multiplier=$(get_model_cost_multiplier "$model")
    local cost_units=$((input_tokens * multiplier))
    
    local log_file="${PANTHEON_LOGS_DIR:-$PANTHEON_ROOT/.pantheon/logs}/cost_tracking.log"
    mkdir -p "$(dirname "$log_file")"
    echo "[$(date -Iseconds)] agent=$agent model=$model tokens=$input_tokens cost_units=$cost_units" >> "$log_file"
}
