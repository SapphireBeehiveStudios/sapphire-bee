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

# ============================================
# SAFETY: Protect main/master branch
# ============================================

# Prevent force pushing (--force, --force-with-lease)
git config --global receive.denyNonFastForwards true

# Prevent deleting branches on remote
git config --global receive.denyDeletes true

# Set default branch for new repos to a feature branch pattern
git config --global init.defaultBranch main

# Create a global pre-push hook to block pushes to main/master
HOOKS_DIR="${HOME}/.git-templates/hooks"
mkdir -p "${HOOKS_DIR}"

cat > "${HOOKS_DIR}/pre-push" << 'HOOK'
#!/bin/bash
# Pre-push hook: Prevent direct pushes to main/master branches

protected_branches=("main" "master")
current_branch=$(git symbolic-ref HEAD 2>/dev/null | sed 's|refs/heads/||')

for branch in "${protected_branches[@]}"; do
    if [[ "$current_branch" == "$branch" ]]; then
        echo "🛑 ERROR: Direct push to '$branch' branch is blocked!"
        echo ""
        echo "To make changes safely:"
        echo "  1. Create a feature branch:  git checkout -b feature/my-changes"
        echo "  2. Make your changes and commit"
        echo "  3. Push the feature branch:  git push -u origin feature/my-changes"
        echo "  4. Create a PR:              gh pr create"
        echo ""
        echo "If you REALLY need to push to $branch (not recommended):"
        echo "  git push --no-verify origin $branch"
        exit 1
    fi
done

exit 0
HOOK

chmod +x "${HOOKS_DIR}/pre-push"

# Configure git to use our template directory for hooks
git config --global init.templateDir "${HOME}/.git-templates"

# Also create an alias for safe workflow
git config --global alias.safe-branch '!git checkout -b'
# shellcheck disable=SC2016 # $1 should expand at runtime, not definition
git config --global alias.start '!f() { git checkout -b "claude/$1"; }; f'

echo "Git configured for GitHub PAT authentication"
echo "⚠️  Safety: Direct pushes to main/master are blocked (use feature branches)"

