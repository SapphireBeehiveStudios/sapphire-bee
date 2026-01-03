#!/bin/bash
# setup-claude-auth.sh - Configure Claude authentication for the sandbox
#
# Usage:
#   ./scripts/setup-claude-auth.sh [login|logout|status]
#
# This script helps you authenticate Claude Code with your Claude Max subscription
# instead of using an API key. Credentials are stored on your host machine and
# mounted into containers automatically.
#
# Prerequisites:
#   - Claude Code CLI installed on host (npm install -g @anthropic-ai/claude-code)
#   - Claude Max subscription

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

log_hint() {
    echo -e "${BLUE}[HINT]${NC} $1"
}

# Common Claude config locations
CLAUDE_CONFIG_PATHS=(
    "$HOME/.claude"
    "$HOME/.config/claude"
    "$HOME/.config/claude-code"
)

find_claude_config() {
    for path in "${CLAUDE_CONFIG_PATHS[@]}"; do
        if [[ -d "$path" ]]; then
            echo "$path"
            return 0
        fi
    done
    # Default to most likely location
    echo "$HOME/.claude"
    return 1
}

check_claude_installed() {
    if ! command -v claude &> /dev/null; then
        log_error "Claude Code CLI not found on your host machine."
        echo ""
        echo "Install it with:"
        echo "  npm install -g @anthropic-ai/claude-code"
        echo ""
        echo "Then run this script again."
        exit 1
    fi
}

check_api_key_conflict() {
    if [[ -n "${ANTHROPIC_API_KEY:-}" ]]; then
        log_warn "ANTHROPIC_API_KEY is set in your environment!"
        echo ""
        echo "Claude Code prioritizes API keys over subscription auth."
        echo "To use your Claude Max subscription, you should either:"
        echo ""
        echo "  1. Unset the variable for this session:"
        echo "     unset ANTHROPIC_API_KEY"
        echo ""
        echo "  2. Remove it from your shell config (~/.zshrc, ~/.bashrc)"
        echo ""
        echo "  3. Or continue using API key authentication (no changes needed)"
        echo ""
        return 1
    fi
    return 0
}

show_status() {
    echo ""
    echo "╔══════════════════════════════════════════════════════════════╗"
    echo "║            CLAUDE AUTHENTICATION STATUS                      ║"
    echo "╚══════════════════════════════════════════════════════════════╝"
    echo ""
    
    # Check for API key
    echo "API Key Authentication:"
    if [[ -n "${ANTHROPIC_API_KEY:-}" ]]; then
        if [[ "${ANTHROPIC_API_KEY}" =~ ^sk-ant- ]]; then
            echo -e "  ${GREEN}✓${NC} ANTHROPIC_API_KEY is set (sk-ant-...)"
        else
            echo -e "  ${YELLOW}!${NC} ANTHROPIC_API_KEY is set (unusual format)"
        fi
    else
        echo -e "  ${BLUE}○${NC} ANTHROPIC_API_KEY is not set"
    fi
    echo ""
    
    # Check for Claude Max credentials
    echo "Claude Max Subscription:"
    CLAUDE_CONFIG=$(find_claude_config) || true
    
    if [[ -d "$CLAUDE_CONFIG" ]]; then
        echo -e "  ${GREEN}✓${NC} Config directory found: $CLAUDE_CONFIG"
        
        # List credential files (without showing contents)
        if ls "$CLAUDE_CONFIG"/*.json &> /dev/null 2>&1; then
            echo -e "  ${GREEN}✓${NC} Credential files present"
            log_hint "Your Claude Max credentials will be mounted into containers"
        else
            echo -e "  ${YELLOW}!${NC} Config directory exists but no credential files found"
            log_hint "Run './scripts/setup-claude-auth.sh login' to authenticate"
        fi
    else
        echo -e "  ${BLUE}○${NC} No Claude config directory found"
        log_hint "Run './scripts/setup-claude-auth.sh login' to authenticate with Claude Max"
    fi
    echo ""
    
    # Check .env file
    echo ".env Configuration:"
    if [[ -f "${PROJECT_ROOT}/.env" ]]; then
        if grep -q "ANTHROPIC_API_KEY=" "${PROJECT_ROOT}/.env" 2>/dev/null; then
            echo -e "  ${GREEN}✓${NC} .env file has ANTHROPIC_API_KEY"
        else
            echo -e "  ${BLUE}○${NC} .env file exists but no ANTHROPIC_API_KEY"
        fi
        
        if grep -q "CLAUDE_CONFIG_PATH=" "${PROJECT_ROOT}/.env" 2>/dev/null; then
            echo -e "  ${GREEN}✓${NC} .env file has CLAUDE_CONFIG_PATH"
        else
            echo -e "  ${BLUE}○${NC} CLAUDE_CONFIG_PATH not set (will use default: ~/.claude)"
        fi
    else
        echo -e "  ${YELLOW}!${NC} .env file not found"
        log_hint "Copy .env.example to .env"
    fi
    echo ""
    
    # Summary
    echo "════════════════════════════════════════════════════════════════"
    if [[ -n "${ANTHROPIC_API_KEY:-}" ]]; then
        echo -e "${GREEN}Ready:${NC} Using API key authentication"
    elif [[ -d "$CLAUDE_CONFIG" ]] && ls "$CLAUDE_CONFIG"/*.json &> /dev/null 2>&1; then
        echo -e "${GREEN}Ready:${NC} Using Claude Max subscription"
    else
        echo -e "${YELLOW}Action needed:${NC} Set up authentication"
        echo ""
        echo "Options:"
        echo "  1. Claude Max: ./scripts/setup-claude-auth.sh login"
        echo "  2. API Key:    Add ANTHROPIC_API_KEY to .env file"
    fi
    echo "════════════════════════════════════════════════════════════════"
    echo ""
}

do_login() {
    echo ""
    echo "╔══════════════════════════════════════════════════════════════╗"
    echo "║            CLAUDE MAX SUBSCRIPTION LOGIN                     ║"
    echo "╚══════════════════════════════════════════════════════════════╝"
    echo ""
    
    check_claude_installed
    
    # Warn about API key conflict
    if ! check_api_key_conflict; then
        echo ""
        read -p "Continue anyway? [y/N] " -n 1 -r
        echo ""
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            exit 1
        fi
    fi
    
    log_info "Starting Claude login..."
    echo ""
    echo "A browser window will open for OAuth authentication."
    echo "Log in with your Claude account that has the Max subscription."
    echo ""
    
    # Run claude login
    if claude login; then
        echo ""
        log_info "Login successful!"
        echo ""
        
        # Find where credentials were stored
        CLAUDE_CONFIG=$(find_claude_config) || true
        if [[ -d "$CLAUDE_CONFIG" ]]; then
            log_info "Credentials stored in: $CLAUDE_CONFIG"
            echo ""
            echo "The sandbox will automatically mount these credentials."
            echo "No further configuration needed!"
        fi
        
        echo ""
        log_hint "Verify with: ./scripts/setup-claude-auth.sh status"
    else
        log_error "Login failed. Please try again."
        exit 1
    fi
}

do_logout() {
    echo ""
    check_claude_installed
    
    log_info "Logging out of Claude..."
    if claude logout; then
        log_info "Logout successful."
    else
        log_warn "Logout command completed with warnings."
    fi
}

usage() {
    cat << EOF
Usage: $0 [command]

Commands:
  login   - Authenticate with your Claude Max subscription (opens browser)
  logout  - Clear stored Claude credentials
  status  - Show current authentication status (default)

Examples:
  $0             # Show status
  $0 login       # Start OAuth login flow
  $0 status      # Check what auth method is configured

Environment:
  ANTHROPIC_API_KEY    - If set, Claude uses API key (pay-per-use)
  CLAUDE_CONFIG_PATH   - Override default Claude config location

Notes:
  - Claude Max login requires the Claude CLI on your HOST machine
  - Credentials are stored on host and mounted into containers
  - If ANTHROPIC_API_KEY is set, it takes priority over subscription auth
EOF
}

# Main
case "${1:-status}" in
    login)
        do_login
        ;;
    logout)
        do_logout
        ;;
    status)
        show_status
        ;;
    -h|--help|help)
        usage
        ;;
    *)
        log_error "Unknown command: $1"
        usage
        exit 1
        ;;
esac

