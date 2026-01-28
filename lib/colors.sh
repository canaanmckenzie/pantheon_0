#!/bin/bash
# =============================================================================
# TERMINAL COLORS AND FORMATTING
# =============================================================================

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
MAGENTA='\033[0;35m'
CYAN='\033[0;36m'
WHITE='\033[0;37m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m' # No Color

# Agent colors (each agent gets a distinct color)
declare -A AGENT_COLORS=(
    ["luminary"]="$YELLOW"
    ["architect"]="$BLUE"
    ["weaver"]="$MAGENTA"
    ["djinn"]="$WHITE"
    ["doctor"]="$RED"
    ["scribe"]="$CYAN"
    ["crocodile"]="$GREEN"
)

# Model tier colors (for logging)
declare -A MODEL_COLORS=(
    ["haiku"]="$GREEN"
    ["sonnet"]="$YELLOW"
    ["opus"]="$RED"
)

get_agent_color() {
    local agent=$1
    echo "${AGENT_COLORS[$agent]:-$NC}"
}

get_model_color() {
    local model=$1
    if [[ "$model" == *"haiku"* ]]; then
        echo "$GREEN"
    elif [[ "$model" == *"sonnet"* ]]; then
        echo "$YELLOW"
    elif [[ "$model" == *"opus"* ]]; then
        echo "$RED"
    else
        echo "$NC"
    fi
}
