#!/bin/bash
# Terminal colors and formatting

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

# Agent colors
declare -A AGENT_COLORS=(
    ["crocodile"]="$GREEN"
    ["scribe"]="$CYAN"
    ["architect"]="$BLUE"
    ["weaver"]="$MAGENTA"
    ["doctor"]="$RED"
    ["luminary"]="$YELLOW"
    ["djinn"]="$WHITE"
)

get_agent_color() {
    local agent=$1
    echo "${AGENT_COLORS[$agent]:-$NC}"
}
