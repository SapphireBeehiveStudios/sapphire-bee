#!/bin/bash
# setup-git-pat.sh - Configures git to use GitHub PAT for authentication
#
# This script sets up git credential helper to use the GITHUB_PAT environment
# variable for authenticating with GitHub. It should be run inside the container
# when GITHUB_PAT is available.
#
# Usage:
#   source /opt/scripts/setup-git-pat.sh
#   # or
#   . /opt/scripts/setup-git-pat.sh

set -euo pipefail

# Check if GITHUB_PAT is set
if [[ -z "${GITHUB_PAT:-}" ]]; then
    echo "WARNING: GITHUB_PAT not set. Git operations with GitHub will not be authenticated." >&2
    return 0  # Don't fail, just warn
fi

# Create credentials file in tmpfs (home directory is tmpfs)
CREDENTIALS_FILE="${HOME}/.git-credentials"
CREDENTIALS_DIR="$(dirname "${CREDENTIALS_FILE}")"

# Create .git directory if it doesn't exist
mkdir -p "${CREDENTIALS_DIR}"

# Write GitHub credentials
# Format: https://username:token@github.com
# We use a placeholder username since PATs work with any username
echo "https://${GITHUB_PAT}@github.com" > "${CREDENTIALS_FILE}"

# Set restrictive permissions (read-only for owner)
chmod 600 "${CREDENTIALS_FILE}"

# Configure git to use credential helper
git config --global credential.helper "store --file=${CREDENTIALS_FILE}"

# Set default git user if not already configured
if ! git config --global user.name >/dev/null 2>&1; then
    git config --global user.name "Claude Agent"
fi

if ! git config --global user.email >/dev/null 2>&1; then
    git config --global user.email "claude-agent@localhost"
fi

# Optional: Configure git to use HTTPS URLs by default for GitHub
git config --global url."https://github.com/".insteadOf "git@github.com:" || true

echo "Git configured for GitHub PAT authentication"

