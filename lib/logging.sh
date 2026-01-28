#!/bin/bash
# =============================================================================
# LOGGING UTILITIES
# =============================================================================
#
# Comprehensive logging with token efficiency tracking.
#
# =============================================================================

PANTHEON_ROOT="${PANTHEON_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
# Use .pantheon/ structure
PANTHEON_LOGS_DIR="${PANTHEON_LOGS_DIR:-$PANTHEON_ROOT/.pantheon/logs}"
LOG_DIR="$PANTHEON_LOGS_DIR"
MASTER_LOG="$LOG_DIR/pantheon.log"

# Source colors if available
[[ -f "$PANTHEON_ROOT/lib/colors.sh" ]] && source "$PANTHEON_ROOT/lib/colors.sh"

ensure_log_dir() {
    mkdir -p "$LOG_DIR"
}

timestamp() {
    date '+%Y-%m-%d %H:%M:%S'
}

log_raw() {
    local level=$1
    local message=$2
    ensure_log_dir
    echo "[$(timestamp)] [$level] $message" >> "$MASTER_LOG"
}

# =============================================================================
# STANDARD LOGGING
# =============================================================================

log_header() {
    local message=$1
    echo ""
    echo -e "${BOLD}================================================================${NC}"
    echo -e "${BOLD}  $message${NC}"
    echo -e "${BOLD}================================================================${NC}"
    log_raw "HEADER" "$message"
}

log_info() {
    local message=$1
    echo -e "${DIM}[INFO]${NC} $message"
    log_raw "INFO" "$message"
}

log_success() {
    local message=$1
    echo -e "${GREEN}[OK]${NC} $message"
    log_raw "SUCCESS" "$message"
}

log_warning() {
    local message=$1
    echo -e "${YELLOW}[WARN]${NC} $message"
    log_raw "WARNING" "$message"
}

log_error() {
    local message=$1
    echo -e "${RED}[ERROR]${NC} $message"
    log_raw "ERROR" "$message"
}

# =============================================================================
# AGENT-SPECIFIC LOGGING
# =============================================================================

log_agent() {
    local agent=$1
    local message=$2
    local color=$(get_agent_color "$agent")
    local agent_upper=$(echo "$agent" | tr '[:lower:]' '[:upper:]')
    
    echo -e "${color}[${agent_upper}]${NC} $message"
    log_raw "$agent_upper" "$message"
    
    # Agent-specific log
    ensure_log_dir
    echo "[$(timestamp)] $message" >> "$LOG_DIR/${agent}.log"
}

log_agent_skip() {
    local agent=$1
    local reason=$2
    local color=$(get_agent_color "$agent")
    local agent_upper=$(echo "$agent" | tr '[:lower:]' '[:upper:]')
    
    echo -e "${DIM}[${agent_upper}]${NC} ${DIM}SKIPPED: $reason${NC}"
    log_raw "SKIP" "$agent: $reason"
}

log_spawn() {
    local parent=$1
    local specialization=$2
    local task=$3
    echo -e "${MAGENTA}[SPAWN]${NC} ${parent} -> ${specialization}: ${task:0:50}..."
    log_raw "SPAWN" "$parent -> $specialization: $task"
}

# =============================================================================
# MODEL/COST LOGGING
# =============================================================================

log_model_selection() {
    local agent=$1
    local model=$2
    local complexity=$3
    local model_color=$(get_model_color "$model")
    
    # Extract model name for display
    local model_short
    if [[ "$model" == *"haiku"* ]]; then
        model_short="haiku"
    elif [[ "$model" == *"sonnet"* ]]; then
        model_short="sonnet"
    elif [[ "$model" == *"opus"* ]]; then
        model_short="opus"
    else
        model_short="$model"
    fi
    
    echo -e "${DIM}  Model: ${model_color}${model_short}${NC} (complexity: $complexity)${NC}"
    log_raw "MODEL" "$agent: $model_short ($complexity)"
}

# =============================================================================
# EFFICIENCY METRICS
# =============================================================================

log_cycle_metrics() {
    local cycle=$1
    local agents_run=$2
    local agents_skipped=$3
    local spawns=$4
    local duration=$5
    
    local efficiency
    if [[ $agents_run -gt 0 ]]; then
        efficiency=$((100 - (agents_skipped * 100 / (agents_run + agents_skipped))))
    else
        efficiency=0
    fi
    
    echo ""
    echo -e "${DIM}Cycle $cycle: $agents_run agents run, $agents_skipped skipped, $spawns spawns, ${duration}s${NC}"
    log_raw "METRICS" "cycle=$cycle agents_run=$agents_run skipped=$agents_skipped spawns=$spawns duration=$duration efficiency=$efficiency%"
}

log_rate_limit() {
    local agent=$1
    echo -e "${RED}[RATE LIMIT]${NC} Hit rate limit during $agent execution"
    log_raw "RATE_LIMIT" "$agent"
    
    # Also log to dedicated rate limit file for easy tracking
    ensure_log_dir
    echo "[$(timestamp)] $agent" >> "$LOG_DIR/rate_limits.log"
}

# =============================================================================
# TOKEN CHURN MONITORING
# =============================================================================

log_token_churn() {
    local severity=$1  # INFO, WARNING, CRITICAL, WASTE
    local source=$2    # agent name, orchestrator, context, etc.
    local description=$3
    
    ensure_log_dir
    echo "[$(timestamp)] [$severity] [$source] $description" >> "$LOG_DIR/token_churn.log"
    
    if [[ "$severity" == "CRITICAL" || "$severity" == "WASTE" ]]; then
        echo -e "${RED}[TOKEN CHURN]${NC} $source: $description"
    fi
}
