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

# Execute the provided command or default to bash
exec "$@"

