#!/bin/bash
# claude-exec.sh - Execute Claude commands in a running agent container
#
# Usage:
#   ./scripts/claude-exec.sh                    # Interactive Claude session
#   ./scripts/claude-exec.sh "your prompt"      # Single prompt, returns when done
#   ./scripts/claude-exec.sh --shell            # Open bash shell in container
#
# Prerequisites:
#   - Agent container must be running (use: make up-agent PROJECT=/path)
#   - Authentication configured in .env file

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

usage() {
    cat << EOF
Usage: $0 [options] [prompt]

Execute Claude commands in the running agent container.

Options:
  --shell, -s     Open a bash shell instead of Claude
  --help, -h      Show this help message

Arguments:
  prompt          Optional prompt to send to Claude (runs non-interactively)
                  If omitted, opens interactive Claude session

Examples:
  $0                              # Interactive Claude session
  $0 "What files are in this project?"   # Single prompt
  $0 "Add a jump mechanic to player.gd"  # Single prompt
  $0 --shell                      # Open bash shell

Prerequisites:
  Start the agent first with: make up-agent PROJECT=/path/to/project
EOF
    exit 0
}

# Parse arguments
OPEN_SHELL=false
PROMPT=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --shell|-s)
            OPEN_SHELL=true
            shift
            ;;
        --help|-h)
            usage
            ;;
        *)
            # Collect remaining args as prompt
            PROMPT="$*"
            break
            ;;
    esac
done

# Check if agent container is running
if ! docker ps --format '{{.Names}}' 2>/dev/null | grep -q '^agent$'; then
    log_error "Agent container is not running."
    echo ""
    echo "Start it with:"
    echo "  make up-agent PROJECT=/path/to/your/project"
    echo ""
    echo "Or for one-off sessions (no persistent container):"
    echo "  make run-direct PROJECT=/path/to/your/project"
    exit 1
fi

# Get container info
CONTAINER_PROJECT=$(docker exec agent pwd 2>/dev/null || echo "/project")
log_info "Agent container is running (workdir: ${CONTAINER_PROJECT})"

if [[ "$OPEN_SHELL" == "true" ]]; then
    # Open bash shell
    log_info "Opening bash shell in agent container..."
    exec docker exec -it agent bash
elif [[ -n "$PROMPT" ]]; then
    # Run single prompt
    echo -e "${CYAN}Prompt:${NC} $PROMPT"
    echo ""
    exec docker exec -it agent claude "$PROMPT"
else
    # Interactive Claude session
    log_info "Starting interactive Claude session..."
    echo -e "${YELLOW}Tip:${NC} Type 'exit' or Ctrl+D to leave Claude"
    echo ""
    exec docker exec -it agent claude
fi

