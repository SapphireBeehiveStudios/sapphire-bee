#!/bin/bash
# clone-repo.sh - Clones a GitHub repository using PAT authentication
#
# Usage:
#   /opt/scripts/clone-repo.sh owner/repo [target-directory]
#   /opt/scripts/clone-repo.sh https://github.com/owner/repo.git [target-directory]
#
# Examples:
#   /opt/scripts/clone-repo.sh SapphireBeehive/godot-agent
#   /opt/scripts/clone-repo.sh myorg/myrepo /project/my-repo

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source the git PAT setup script
if [[ -f "${SCRIPT_DIR}/setup-git-pat.sh" ]]; then
    # shellcheck source=/dev/null
    source "${SCRIPT_DIR}/setup-git-pat.sh"
fi

# Parse arguments
if [[ $# -lt 1 ]]; then
    echo "Usage: $0 <owner/repo> [target-directory]" >&2
    echo "   or: $0 <full-github-url> [target-directory]" >&2
    exit 1
fi

REPO_SPEC="$1"
TARGET_DIR="${2:-}"

# Determine repository URL
if [[ "$REPO_SPEC" =~ ^https?:// ]]; then
    # Full URL provided
    REPO_URL="$REPO_SPEC"
    # Extract repo name from URL for default target directory
    if [[ -z "$TARGET_DIR" ]]; then
        REPO_NAME=$(basename "$REPO_SPEC" .git)
        TARGET_DIR="/project/${REPO_NAME}"
    fi
elif [[ "$REPO_SPEC" =~ ^[^/]+/[^/]+$ ]]; then
    # owner/repo format
    REPO_URL="https://github.com/${REPO_SPEC}.git"
    if [[ -z "$TARGET_DIR" ]]; then
        REPO_NAME=$(basename "$REPO_SPEC")
        TARGET_DIR="/project/${REPO_NAME}"
    fi
else
    echo "ERROR: Invalid repository specification: $REPO_SPEC" >&2
    echo "Expected format: owner/repo or https://github.com/owner/repo.git" >&2
    exit 1
fi

# Check if target directory already exists
if [[ -d "$TARGET_DIR" ]]; then
    echo "ERROR: Target directory already exists: $TARGET_DIR" >&2
    exit 1
fi

# Check if GITHUB_PAT is set (warn but don't fail for public repos)
if [[ -z "${GITHUB_PAT:-}" ]]; then
    echo "WARNING: GITHUB_PAT not set. This will only work for public repositories." >&2
fi

# Clone the repository
echo "Cloning repository: $REPO_URL"
echo "Target directory: $TARGET_DIR"

if git clone "$REPO_URL" "$TARGET_DIR"; then
    echo "Successfully cloned repository to: $TARGET_DIR"
    echo ""
    echo "To work in this repository:"
    echo "  cd $TARGET_DIR"
else
    echo "ERROR: Failed to clone repository" >&2
    exit 1
fi

