# Claude Code Context for godot-agent

This repository provides a secure, sandboxed Docker environment for running Claude Code with Godot game development projects.

## Project Purpose

The sandbox isolates Claude Code in a container with:
- **Network allowlisting**: Only GitHub, Godot docs, and Anthropic API are accessible
- **Filesystem isolation**: Only the mounted project directory is writable
- **Security hardening**: Read-only rootfs, dropped capabilities, resource limits

This protects against Claude accidentally (or maliciously) accessing sensitive data or making unwanted network connections.

## Repository Structure

```
godot-agent/
├── compose/                 # Docker Compose configurations
│   ├── compose.base.yml     # Infrastructure: DNS filter + proxy services
│   ├── compose.direct.yml   # Agent with direct project mount
│   ├── compose.staging.yml  # Agent with staging directory mount
│   └── compose.offline.yml  # Agent with no network access
├── configs/
│   ├── coredns/             # DNS allowlist configuration
│   └── nginx/               # TCP proxy configurations
├── image/
│   ├── Dockerfile           # Agent container image
│   └── install/             # Installation scripts for Godot and Claude Code
├── scripts/                 # Operational scripts (run from host)
├── .github/workflows/       # CI/CD pipelines
└── logs/                    # Session logs (gitignored)
```

## Key Commands

All commands are run on the **host machine**, not inside containers:

```bash
# Setup and health check
make doctor                  # Verify environment is configured
make auth                    # Check authentication status
make build                   # Build the agent container image

# Running the sandbox
make up                      # Start infrastructure (DNS + proxies)
make run-direct PROJECT=/path/to/godot/project
make down                    # Stop all services

# Security
make scan PROJECT=/path      # Scan for dangerous patterns in GDScript
```

## Authentication

Two methods are supported (set in `.env` file):

1. **Claude Max OAuth Token** (recommended):
   ```bash
   claude setup-token         # Generate token on host
   # Add to .env: CLAUDE_CODE_OAUTH_TOKEN=sk-ant-...
   ```

2. **API Key** (pay-per-use):
   ```bash
   # Add to .env: ANTHROPIC_API_KEY=sk-ant-...
   ```

## Architecture

```
Host Machine
├── Godot Editor (runs natively)
├── Docker Desktop
│   └── Containers
│       ├── dnsfilter (CoreDNS) - Allowlists specific domains
│       ├── proxy_github       - Forwards to github.com
│       ├── proxy_anthropic    - Forwards to api.anthropic.com
│       └── agent              - Claude Code + Godot headless
│           └── /project       - Mounted from host (RW)
```

The agent container can ONLY reach the internet through the proxy containers, which only connect to specific upstream hosts.

## Security Model

### What's Protected
- Agent cannot access arbitrary network destinations
- Agent cannot read host filesystem outside /project
- Agent runs as non-root with minimal capabilities
- Container is read-only with limited tmpfs for scratch space

### What's NOT Protected
- If Claude writes malicious GDScript, it could run when you open Godot Editor on host
- Container/VM escape exploits (theoretical)
- Prompt injection from malicious project files

### Important: Always Review Changes
```bash
git diff                     # Review Claude's changes before committing
./scripts/scan-dangerous.sh /path/to/project  # Check for dangerous patterns
```

## Conventions

### Commit Messages
Use conventional commits:
```
type(scope): short description

Optional longer explanation.
```
Types: `fix`, `feat`, `docs`, `ci`, `build`, `chore`, `refactor`

### Docker Compose
- Use modern syntax (`deploy.resources.limits.pids` not `pids_limit`)
- Default env vars to empty: `${VAR:-}` to suppress warnings in CI
- Never require `ANTHROPIC_API_KEY` in CI - always default to empty

### Shell Scripts
- Use `set -euo pipefail` at the top
- Use `shellcheck` for linting
- Add `# shellcheck disable=SCXXXX` comments with explanation when needed

## Development Workflows

### Testing CI Locally
```bash
make ci                      # Run full CI workflow with `act`
make ci-validate             # Run just the validation job
```

### Adding a New Allowed Domain
1. Add entry to `configs/coredns/hosts.allowlist`
2. Create new proxy service in `compose/compose.base.yml`
3. Create nginx config in `configs/nginx/proxy_newdomain.conf`
4. Update documentation

### Building for Multiple Architectures
The GitHub Actions workflow builds for both `linux/amd64` and `linux/arm64`. For local multi-arch builds:
```bash
docker buildx build --platform linux/amd64,linux/arm64 -t image:tag ./image
```

## Files to Never Commit
- `.env` (contains secrets)
- `logs/` directory
- Any API keys or tokens

## Common Issues

1. **DNS not working**: Restart with `make down && make up`
2. **Permission denied on scripts**: Run `chmod +x scripts/*.sh`
3. **Docker not running**: Start Docker Desktop first
4. **Auth errors**: Run `make auth` to diagnose

