#!/bin/bash
# entrypoint.sh - Container entrypoint that sets up Claude configuration
#
# This script runs on every container start to:
# 1. Set up Claude Code settings (permissions, etc.)
# 2. Verify settings are correctly installed
# 3. Execute the provided command or default to bash
#
# The home directory is a tmpfs mount, so configuration must be
# recreated on each container start.

set -euo pipefail

# Claude settings directory
CLAUDE_CONFIG_DIR="${HOME}/.claude"
SETTINGS_FILE="${CLAUDE_CONFIG_DIR}/settings.json"

# Set up Claude Code configuration
setup_claude_config() {
    # Create Claude config directory
    mkdir -p "${CLAUDE_CONFIG_DIR}"
    
    # Copy pre-configured settings if they exist
    if [[ -f /etc/claude/settings.json ]]; then
        cp /etc/claude/settings.json "${SETTINGS_FILE}"
        
        # Verify settings file was copied successfully
        if [[ ! -f "${SETTINGS_FILE}" ]]; then
            echo "ERROR: Failed to copy settings file to ${SETTINGS_FILE}" >&2
            exit 1
        fi
        
        # Verify settings file is valid JSON (if jq is available)
        if command -v jq >/dev/null 2>&1; then
            if ! jq empty "${SETTINGS_FILE}" 2>/dev/null; then
                echo "WARNING: Settings file may not be valid JSON" >&2
            fi
        fi
    else
        echo "WARNING: /etc/claude/settings.json not found, Claude permissions may not be configured" >&2
    fi
    
    # Copy sandbox context to home directory as CLAUDE.md
    # This provides sandbox context without conflicting with project CLAUDE.md
    if [[ -f /etc/claude/sandbox-context.md ]]; then
        cp /etc/claude/sandbox-context.md "${CLAUDE_CONFIG_DIR}/CLAUDE.md"
        if [[ "${CLAUDE_DEBUG:-}" == "1" ]]; then
            echo "DEBUG: Sandbox context copied to ${CLAUDE_CONFIG_DIR}/CLAUDE.md" >&2
        fi
    fi
    
    # Mark that we've accepted terms (prevents interactive prompt)
    touch "${CLAUDE_CONFIG_DIR}/.terms-accepted"
    
    # Debug output (only if CLAUDE_DEBUG is set)
    if [[ "${CLAUDE_DEBUG:-}" == "1" ]]; then
        echo "DEBUG: Claude settings configured" >&2
        echo "DEBUG: Settings file: ${SETTINGS_FILE}" >&2
        if [[ -f "${SETTINGS_FILE}" ]]; then
            echo "DEBUG: Settings contents:" >&2
            cat "${SETTINGS_FILE}" >&2
        fi
        echo "DEBUG: Terms accepted: ${CLAUDE_CONFIG_DIR}/.terms-accepted" >&2
    fi
}

# Run setup
setup_claude_config

# Configure GitHub authentication (GitHub App takes priority over PAT)
if [[ -n "${GITHUB_APP_ID:-}" ]] && [[ -n "${GITHUB_APP_INSTALLATION_ID:-}" ]]; then
    # GitHub App authentication (recommended)
    if [[ -f /opt/scripts/setup-github-app.sh ]]; then
        # shellcheck source=/dev/null
        source /opt/scripts/setup-github-app.sh || {
            echo "WARNING: GitHub App setup failed, falling back to PAT if available" >&2
        }
    fi
elif [[ -n "${GITHUB_PAT:-}" ]]; then
    # Personal Access Token authentication (legacy)
    if [[ -f /opt/scripts/setup-git-pat.sh ]]; then
        # shellcheck source=/dev/null
        source /opt/scripts/setup-git-pat.sh || true
    fi
    
    # Configure GitHub CLI (gh) - it uses GH_TOKEN env var for auth
    export GH_TOKEN="${GITHUB_PAT}"
    
    # Set default git protocol to https (required for PAT auth)
    if command -v gh >/dev/null 2>&1; then
        gh config set git_protocol https --host github.com 2>/dev/null || true
    fi
fi

# Set default git protocol to https for GitHub CLI
if command -v gh >/dev/null 2>&1; then
    gh config set git_protocol https --host github.com 2>/dev/null || true
fi

# Verify MCP configuration if GitHub auth was set up
if [[ -n "${GITHUB_TOKEN:-}" ]] || [[ -n "${GH_TOKEN:-}" ]]; then
    if [[ -f /opt/scripts/verify-mcp.sh ]]; then
        echo "" >&2
        if [[ "${GITHUB_DEBUG:-}" == "1" ]]; then
            /opt/scripts/verify-mcp.sh --verbose || {
                echo "WARNING: MCP verification failed, some GitHub features may not work" >&2
            }
        else
            /opt/scripts/verify-mcp.sh || {
                echo "WARNING: MCP verification failed, some GitHub features may not work" >&2
                echo "  Run with GITHUB_DEBUG=1 for details" >&2
            }
        fi
        echo "" >&2
    fi
fi

# Execute the provided command or default to bash
exec "$@"

