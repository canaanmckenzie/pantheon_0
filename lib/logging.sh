#!/bin/bash
# Logging utilities for Pantheon

LOG_DIR="$PANTHEON_ROOT/logs"
MASTER_LOG="$LOG_DIR/pantheon.log"

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

log_header() {
    local message=$1
    echo ""
    echo -e "${BOLD}═══════════════════════════════════════════════════════════════${NC}"
    echo -e "${BOLD}  $message${NC}"
    echo -e "${BOLD}═══════════════════════════════════════════════════════════════${NC}"
    log_raw "HEADER" "$message"
}

log_info() {
    local message=$1
    echo -e "${DIM}[INFO]${NC} $message"
    log_raw "INFO" "$message"
}

log_success() {
    local message=$1
    echo -e "${GREEN}[SUCCESS]${NC} $message"
    log_raw "SUCCESS" "$message"
}

log_warning() {
    local message=$1
    echo -e "${YELLOW}[WARNING]${NC} $message"
    log_raw "WARNING" "$message"
}

log_error() {
    local message=$1
    echo -e "${RED}[ERROR]${NC} $message"
    log_raw "ERROR" "$message"
}

log_agent() {
    local agent=$1
    local message=$2
    local color=$(get_agent_color "$agent")
    local agent_upper=$(echo "$agent" | tr '[:lower:]' '[:upper:]')
    
    echo -e "${color}[${agent_upper}]${NC} $message"
    log_raw "$agent_upper" "$message"
    
    # Also log to agent-specific log
    ensure_log_dir
    echo "[$(timestamp)] $message" >> "$LOG_DIR/${agent}.log"
}

log_spawn() {
    local parent=$1
    local child=$2
    local task=$3
    echo -e "${MAGENTA}[SPAWN]${NC} ${parent} → ${child}: $task"
    log_raw "SPAWN" "$parent -> $child: $task"
}
