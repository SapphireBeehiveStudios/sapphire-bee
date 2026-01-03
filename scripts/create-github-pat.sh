#!/bin/bash
# create-github-pat.sh - Creates a fine-grained GitHub PAT with required permissions
#
# Usage:
#   ./scripts/create-github-pat.sh owner/repo
#   ./scripts/create-github-pat.sh myorg/myrepo
#
# This script uses `gh` CLI to create a fine-grained PAT with minimal permissions
# needed for Claude to work on the repository.

set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

usage() {
    cat << EOF
Usage: $0 <owner/repo>

Creates a fine-grained GitHub Personal Access Token with permissions for:
  - Contents (read/write) - clone, commit, push
  - Issues (read/write) - create, close, comment on issues
  - Pull requests (read/write) - create, merge PRs
  - Metadata (read) - required for all operations

Examples:
  $0 myusername/my-godot-game
  $0 myorg/private-project

Prerequisites:
  - gh CLI installed and authenticated (gh auth login)
EOF
    exit 1
}

# Check arguments
if [[ $# -lt 1 ]]; then
    usage
fi

REPO="$1"

# Validate repo format
if [[ ! "$REPO" =~ ^[a-zA-Z0-9._-]+/[a-zA-Z0-9._-]+$ ]]; then
    echo -e "${RED}ERROR: Invalid repository format: $REPO${NC}" >&2
    echo "Expected format: owner/repo" >&2
    exit 1
fi

REPO_NAME="${REPO#*/}"

# Check if gh is installed
if ! command -v gh &> /dev/null; then
    echo -e "${RED}ERROR: gh CLI not found${NC}" >&2
    echo "Install with: brew install gh" >&2
    exit 1
fi

# Check if gh is authenticated
if ! gh auth status &> /dev/null; then
    echo -e "${RED}ERROR: gh CLI not authenticated${NC}" >&2
    echo "Run: gh auth login" >&2
    exit 1
fi

# Check if repo exists and user has access
echo -e "${BLUE}Checking repository access...${NC}"
if ! gh repo view "$REPO" &> /dev/null; then
    echo -e "${RED}ERROR: Cannot access repository: $REPO${NC}" >&2
    echo "Make sure the repository exists and you have access." >&2
    exit 1
fi

# Get repo ID for fine-grained token
REPO_ID=$(gh api "repos/${REPO}" --jq '.id')
echo -e "${GREEN}✓${NC} Repository found: $REPO (ID: $REPO_ID)"

# Token name with timestamp
TOKEN_NAME="claude-agent-${REPO_NAME}-$(date +%Y%m%d)"
EXPIRY_DAYS=90

echo ""
echo -e "${BLUE}Creating fine-grained PAT...${NC}"
echo "  Name: $TOKEN_NAME"
echo "  Repo: $REPO"
echo "  Expires: $EXPIRY_DAYS days"
echo ""

# Fine-grained PATs can only be created via web UI currently
# (GitHub API doesn't support creating fine-grained PATs programmatically)
# So we guide the user through the web UI with exact instructions

echo -e "${YELLOW}NOTE: Fine-grained PATs must be created via GitHub web UI.${NC}"
echo ""
echo -e "${GREEN}Opening GitHub token creation page...${NC}"
echo ""

# Generate URL for creating fine-grained PAT
# Unfortunately, GitHub doesn't support pre-filling permissions in the URL
# So we provide clear instructions

TOKEN_URL="https://github.com/settings/personal-access-tokens/new"

echo "============================================"
echo -e "${GREEN}CREATE YOUR GITHUB PAT${NC}"
echo "============================================"
echo ""
echo "1. Opening: $TOKEN_URL"
echo ""
echo "2. Fill in these settings:"
echo ""
echo -e "   ${BLUE}Token name:${NC} $TOKEN_NAME"
echo -e "   ${BLUE}Expiration:${NC} 90 days (recommended)"
echo -e "   ${BLUE}Repository access:${NC} Only select repositories → $REPO"
echo ""
echo "3. Under 'Permissions', set:"
echo ""
echo -e "   ${GREEN}Repository permissions:${NC}"
echo "   ├─ Contents:       Read and write"
echo "   ├─ Issues:         Read and write"
echo "   ├─ Metadata:       Read (auto-selected)"
echo "   └─ Pull requests:  Read and write"
echo ""
echo "4. Click 'Generate token' and copy it"
echo ""
echo "5. Add to your .env file:"
echo -e "   ${YELLOW}echo 'GITHUB_PAT=github_pat_...' >> .env${NC}"
echo ""
echo "============================================"
echo ""

# Try to open the URL
if command -v open &> /dev/null; then
    open "$TOKEN_URL"
elif command -v xdg-open &> /dev/null; then
    xdg-open "$TOKEN_URL"
else
    echo "Open this URL in your browser:"
    echo "$TOKEN_URL"
fi

echo -e "${GREEN}After creating the token, test with:${NC}"
echo "  ./scripts/doctor.sh"
echo ""

