# Sandboxed Godot Agent Context

You are running inside a **sandboxed Docker container** with restricted network access and security hardening. This file provides essential context about your environment and capabilities.

## Environment Overview

```
┌─────────────────────────────────────────────────────────────┐
│  SANDBOXED CONTAINER                                        │
│                                                             │
│  You are here: /project (mounted from host)                 │
│                                                             │
│  ✅ Available:                                              │
│    - GitHub MCP tools (primary GitHub access)               │
│    - Godot 4.x (headless)                                   │
│    - Git CLI (for local operations)                         │
│    - Node.js, Python 3, common tools                        │
│                                                             │
│  🔒 Restricted:                                             │
│    - Network: Only allowlisted domains via proxy            │
│    - Filesystem: Only /project is writable                  │
│    - No sudo/root access                                    │
│    - Read-only root filesystem                              │
└─────────────────────────────────────────────────────────────┘
```

## GitHub Access via MCP Tools

**Use MCP tools as your primary way to interact with GitHub.** The GitHub MCP server is pre-configured with authentication.

### Available MCP Tools

| Tool | Purpose |
|------|---------|
| `get_file_contents` | Read files from any accessible repository |
| `search_code` | Search code across repositories |
| `search_repositories` | Find repositories |
| `list_commits` | View commit history |
| `get_issue` / `list_issues` | Read issues |
| `create_issue` | Create new issues |
| `create_pull_request` | Create PRs |
| `get_pull_request` / `list_pull_requests` | Read PRs |
| `create_or_update_file` | Write files to repositories |
| `push_files` | Push multiple files |
| `create_branch` | Create new branches |
| `fork_repository` | Fork a repository |

### Example MCP Usage

```
# Read a file from a repo
Use get_file_contents to read owner/repo/path/to/file.gd

# Search for code
Use search_code to find "func _ready" in owner/repo

# Create an issue
Use create_issue in owner/repo with title and body

# Create a pull request
Use create_pull_request from feature-branch to main
```

### When to Use Git CLI Instead

Use `git` commands for **local operations** in `/project`:

```bash
# Check local status
git status
git diff

# Stage and commit locally
git add .
git commit -m "feat: add feature"

# View local history
git log --oneline
```

**For remote operations (push, pull, clone), prefer MCP tools** when possible as they provide better error handling and don't require manual credential management.

## Network Access

You can **only** reach these domains (via proxy):

| Domain | Purpose |
|--------|---------|
| github.com | Git operations |
| api.github.com | GitHub API (MCP tools use this) |
| raw.githubusercontent.com | Raw file content |
| codeload.github.com | Archive downloads |
| docs.godotengine.org | Godot documentation |
| api.anthropic.com | Claude API |

**All other domains are blocked.**

## Git Workflow (When Using Git CLI)

### Branch Protection (Enforced)

- ⛔ **Direct pushes to `main` or `master` are BLOCKED**
- ✅ Always create a feature branch first
- ✅ Push feature branches and create PRs via MCP tools

### Local Git Operations

```bash
# Create a feature branch
git checkout -b claude/my-feature

# Make changes, commit locally
git add .
git commit -m "feat: add new feature"

# Check what you've done
git status
git log --oneline -5
```

### Creating PRs

Use the MCP `create_pull_request` tool rather than `gh pr create`:

```
Use create_pull_request:
  - repo: owner/repo
  - title: "Add new feature"  
  - body: "Description of changes"
  - head: claude/my-feature
  - base: main
```

## Godot

Godot is available in headless mode:

```bash
# Check version
godot --headless --version

# Validate project
godot --headless --validate-project

# Run a script
godot --headless -s res://scripts/test.gd

# Export (if export presets configured)
godot --headless --export-release "Linux" build/game
```

**Note:** No display server is available. GUI operations will fail.

## Filesystem

| Path | Access | Purpose |
|------|--------|---------|
| `/project` | Read/Write | Your working directory (mounted from host) |
| `/home/claude` | Read/Write | Home directory (tmpfs, not persisted) |
| `/tmp` | Read/Write | Temporary files (tmpfs) |
| Everything else | Read-only | System files |

### Important Notes

- Changes to `/project` persist on the host
- Changes to `/home/claude` and `/tmp` are lost when container stops
- Cannot create files outside these locations

## Security Boundaries

### You CAN:
- Read/write files in `/project`
- Use MCP tools to interact with GitHub
- Run Godot commands
- Use git for local repository operations
- Run Node.js and Python scripts

### You CANNOT:
- Access the internet freely
- Modify system files
- Install system packages
- Access host filesystem outside `/project`
- Run privileged operations

## Best Practices

### 1. Use MCP Tools for GitHub
Prefer MCP tools over CLI commands for GitHub operations:
- More reliable authentication
- Better error messages
- No credential management needed

### 2. Commit Often
Changes in `/project` persist, but make commits to ensure work is saved:
```bash
git add -A && git commit -m "wip: checkpoint"
```

### 3. Use Feature Branches
Always work on a branch, never directly on main:
```bash
git checkout -b claude/my-change
```

### 4. Validate Before Finishing
```bash
godot --headless --validate-project
git status
git diff
```

### 5. Create PRs for Review
Use MCP tools to create a PR for human review before merging.

## Session Information

- **Container**: claude-godot-agent
- **Working Directory**: /project
- **User**: claude (uid 1000)
- **Shell**: /bin/bash

## Getting Help

- Godot docs: https://docs.godotengine.org (accessible)
- Run `godot --help` for CLI options
- Check `/project/CLAUDE.md` for project-specific instructions
