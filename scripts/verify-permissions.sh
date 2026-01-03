#!/bin/bash
# verify-permissions.sh - Verify Claude Code permissions configuration
#
# This script checks if Claude Code permissions are correctly configured
# and tests if auto-approve is working (in interactive mode).
#
# Usage:
#   ./scripts/verify-permissions.sh
#   CLAUDE_DEBUG=1 ./scripts/verify-permissions.sh  # Enable debug output

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

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

log_debug() {
    if [[ "${CLAUDE_DEBUG:-}" == "1" ]]; then
        echo -e "${CYAN}[DEBUG]${NC} $1"
    fi
}

# Check if agent container is running
if ! docker ps --format '{{.Names}}' 2>/dev/null | grep -q '^agent$'; then
    log_error "Agent container is not running."
    echo ""
    echo "Start it with:"
    echo "  make up-agent PROJECT=/path/to/your/project"
    exit 1
fi

log_info "Verifying Claude Code permissions configuration..."
echo ""

# Test 1: Check if settings file exists
log_info "Test 1: Checking if settings file exists..."
SETTINGS_FILE="/home/claude/.claude/settings.json"
if docker exec agent test -f "${SETTINGS_FILE}" 2>/dev/null; then
    log_info "  ✅ Settings file exists: ${SETTINGS_FILE}"
else
    log_error "  ❌ Settings file not found: ${SETTINGS_FILE}"
    exit 1
fi

# Test 2: Verify settings file contents
log_info "Test 2: Verifying settings file contents..."
SETTINGS_CONTENT=$(docker exec agent cat "${SETTINGS_FILE}" 2>/dev/null || echo "")

if [[ -z "${SETTINGS_CONTENT}" ]]; then
    log_error "  ❌ Settings file is empty"
    exit 1
fi

log_debug "Settings file contents:"
log_debug "${SETTINGS_CONTENT}"

# Check for bypassPermissionsMode
if echo "${SETTINGS_CONTENT}" | grep -q '"bypassPermissionsMode".*true'; then
    log_info "  ✅ bypassPermissionsMode is set to true"
else
    log_warn "  ⚠️  bypassPermissionsMode not found or not set to true"
fi

# Check for allow patterns
if echo "${SETTINGS_CONTENT}" | grep -q '"allow"'; then
    log_info "  ✅ allow patterns configured"
    log_debug "  Allow patterns: $(echo "${SETTINGS_CONTENT}" | grep -A 5 '"allow"' || echo 'N/A')"
else
    log_warn "  ⚠️  No allow patterns found"
fi

# Test 3: Check if terms are accepted
log_info "Test 3: Checking if terms are accepted..."
TERMS_FILE="/home/claude/.claude/.terms-accepted"
if docker exec agent test -f "${TERMS_FILE}" 2>/dev/null; then
    log_info "  ✅ Terms accepted file exists"
else
    log_warn "  ⚠️  Terms accepted file not found (may cause interactive prompts)"
fi

# Test 4: Test TTY availability
log_info "Test 4: Checking TTY availability..."
if docker exec agent sh -c 'test -t 0 && echo "TTY" || echo "NO TTY"' 2>/dev/null | grep -q "TTY"; then
    TTY_STATUS="Interactive mode (TTY available)"
    log_info "  ✅ Running in interactive mode"
else
    TTY_STATUS="Non-interactive mode (no TTY)"
    log_warn "  ⚠️  Running in non-interactive mode"
    log_warn "     Note: Write/Edit tools may request permission even with bypassPermissionsMode: true"
    log_warn "     This is expected behavior in non-interactive mode (see CLAUDE.md)"
fi

# Test 5: Test file write (if in interactive mode)
log_info "Test 5: Testing file write operation..."
TEST_FILE="/project/.claude-permissions-test.txt"
TEST_CONTENT="permissions test $(date +%s)"

# Clean up any existing test file
docker exec agent rm -f "${TEST_FILE}" 2>/dev/null || true

# Check if we're in interactive mode
if docker exec agent sh -c 'test -t 0' 2>/dev/null; then
    log_info "  Attempting to create test file via Claude (interactive mode)..."
    log_warn "  This will show if permission prompts appear"
    
    # Try to create file via Claude
    # Note: This may still prompt for permission even with bypassPermissionsMode
    if docker exec -it agent claude "Create a file at ${TEST_FILE} with content '${TEST_CONTENT}'" >/dev/null 2>&1; then
        if docker exec agent test -f "${TEST_FILE}" 2>/dev/null; then
            ACTUAL_CONTENT=$(docker exec agent cat "${TEST_FILE}" 2>/dev/null || echo "")
            if [[ "${ACTUAL_CONTENT}" == *"${TEST_CONTENT}"* ]]; then
                log_info "  ✅ File write succeeded (no permission prompt)"
                docker exec agent rm -f "${TEST_FILE}" 2>/dev/null || true
            else
                log_warn "  ⚠️  File created but content doesn't match"
            fi
        else
            log_warn "  ⚠️  Claude claimed to create file but it doesn't exist"
            log_warn "     This may indicate permission was denied"
        fi
    else
        log_warn "  ⚠️  Claude command failed (may have prompted for permission)"
    fi
else
    log_info "  Skipping interactive test (no TTY available)"
    log_info "  In non-interactive mode, Claude uses Bash tool for file operations"
fi

# Summary
echo ""
log_info "Verification Summary:"
echo "  Mode: ${TTY_STATUS}"
echo "  Settings file: ${SETTINGS_FILE}"
echo "  bypassPermissionsMode: $(echo "${SETTINGS_CONTENT}" | grep -q '"bypassPermissionsMode".*true' && echo 'true' || echo 'not found')"
echo ""
log_info "For more information, see:"
echo "  - notes/OPEN_ISSUES.md (Issue #1)"
echo "  - CLAUDE.md (lines 117-119 for non-interactive mode behavior)"
echo ""

