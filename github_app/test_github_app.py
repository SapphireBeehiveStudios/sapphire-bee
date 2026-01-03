#!/usr/bin/env python3
"""
GitHub App Credential Validation Script

Tests that GitHub App credentials are correctly configured and can
generate installation tokens for the GitHub MCP server.

Usage:
    # Using environment variables
    export GITHUB_APP_ID=123456
    export GITHUB_APP_PRIVATE_KEY_PATH=./secrets/github-app-private-key.pem
    export GITHUB_APP_INSTALLATION_ID=12345678
    python -m github_app.test_github_app

    # Or with explicit arguments
    python -m github_app.test_github_app \
        --app-id 123456 \
        --private-key ./secrets/github-app-private-key.pem \
        --installation-id 12345678

Exit codes:
    0 - All tests passed
    1 - Credential validation failed
    2 - Token generation failed
    3 - API access failed
"""

import argparse
import os
import sys
from pathlib import Path

# Add parent directory to path for module import
sys.path.insert(0, str(Path(__file__).parent.parent))

from github_app.token_generator import GitHubAppTokenGenerator
from github_app.mcp_config import MCPConfigGenerator


def print_header(text: str) -> None:
    """Print a section header."""
    print(f"\n{'='*60}")
    print(f"  {text}")
    print(f"{'='*60}\n")


def print_success(text: str) -> None:
    """Print a success message."""
    print(f"  ✅ {text}")


def print_error(text: str) -> None:
    """Print an error message."""
    print(f"  ❌ {text}")


def print_info(text: str) -> None:
    """Print an info message."""
    print(f"  ℹ️  {text}")


def validate_credentials(generator: GitHubAppTokenGenerator) -> bool:
    """
    Step 1: Validate that the GitHub App credentials are correct.
    
    This tests the JWT generation and app authentication.
    """
    print_header("Step 1: Validating GitHub App Credentials")
    
    try:
        app_info = generator.validate_credentials()
        print_success(f"App authenticated successfully!")
        print_info(f"App Name: {app_info.get('name', 'Unknown')}")
        print_info(f"App ID: {app_info.get('id', 'Unknown')}")
        print_info(f"Owner: {app_info.get('owner', {}).get('login', 'Unknown')}")
        
        # Show permissions
        permissions = app_info.get("permissions", {})
        if permissions:
            print_info("Configured permissions:")
            for perm, level in permissions.items():
                print(f"      - {perm}: {level}")
        
        return True
        
    except FileNotFoundError as e:
        print_error(f"Private key file not found: {e}")
        return False
    except ValueError as e:
        print_error(f"Invalid private key: {e}")
        return False
    except Exception as e:
        print_error(f"Failed to validate credentials: {e}")
        return False


def generate_token(
    generator: GitHubAppTokenGenerator,
    repositories: list[str] | None = None
) -> dict | None:
    """
    Step 2: Generate an installation token.
    
    This tests the full token generation flow.
    """
    print_header("Step 2: Generating Installation Token")
    
    try:
        if repositories:
            print_info(f"Scoping token to repositories: {repositories}")
            result = generator.generate_installation_token(repositories=repositories)
        else:
            print_info("Generating token for all accessible repositories")
            result = generator.generate_installation_token()
        
        print_success("Installation token generated successfully!")
        print_info(f"Token prefix: {result['token'][:20]}...")
        print_info(f"Expires at: {result['expires_at']}")
        
        # Calculate expiry
        seconds_remaining = generator.get_token_expiry_seconds(result["expires_at"])
        minutes = seconds_remaining // 60
        print_info(f"Valid for: {minutes} minutes")
        
        # Show granted permissions
        if result.get("permissions"):
            print_info("Granted permissions:")
            for perm, level in result["permissions"].items():
                print(f"      - {perm}: {level}")
        
        # Show scoped repositories
        if result.get("repositories"):
            print_info(f"Scoped to {len(result['repositories'])} repositories:")
            for repo in result["repositories"][:5]:  # Show first 5
                print(f"      - {repo}")
            if len(result["repositories"]) > 5:
                print(f"      ... and {len(result['repositories']) - 5} more")
        
        return result
        
    except Exception as e:
        print_error(f"Failed to generate token: {e}")
        return None


def test_api_access(token: str) -> bool:
    """
    Step 3: Test that the token works with the GitHub API.
    
    Makes a simple API call to verify the token is valid.
    """
    print_header("Step 3: Testing GitHub API Access")
    
    import requests
    
    try:
        # Test by listing accessible repositories
        response = requests.get(
            "https://api.github.com/installation/repositories",
            headers={
                "Accept": "application/vnd.github+json",
                "Authorization": f"Bearer {token}",
                "X-GitHub-Api-Version": "2022-11-28",
            },
            timeout=30
        )
        
        if response.status_code != 200:
            print_error(f"API request failed with status {response.status_code}")
            print_error(f"Response: {response.text[:200]}")
            return False
        
        data = response.json()
        repos = data.get("repositories", [])
        total = data.get("total_count", len(repos))
        
        print_success(f"API access working! Found {total} accessible repositories.")
        
        if repos:
            print_info("Accessible repositories:")
            for repo in repos[:10]:  # Show first 10
                private = "🔒" if repo.get("private") else "📂"
                print(f"      {private} {repo['full_name']}")
            if total > 10:
                print(f"      ... and {total - 10} more")
        
        return True
        
    except Exception as e:
        print_error(f"API test failed: {e}")
        return False


def test_mcp_config(token: str) -> bool:
    """
    Step 4: Test MCP configuration generation.
    
    Creates a test MCP config to verify the format is correct.
    """
    print_header("Step 4: Testing MCP Configuration Generation")
    
    try:
        generator = MCPConfigGenerator()
        config = generator.generate_config(token)
        
        # Validate config structure
        if "mcpServers" not in config:
            print_error("Config missing 'mcpServers' key")
            return False
        
        if "github" not in config["mcpServers"]:
            print_error("Config missing 'github' server")
            return False
        
        github_config = config["mcpServers"]["github"]
        
        if "command" not in github_config:
            print_error("GitHub server config missing 'command'")
            return False
        
        if "env" not in github_config or "GITHUB_PERSONAL_ACCESS_TOKEN" not in github_config["env"]:
            print_error("GitHub server config missing token environment variable")
            return False
        
        print_success("MCP configuration generated successfully!")
        print_info(f"Command: {github_config['command']}")
        print_info(f"Args: {github_config.get('args', [])}")
        print_info("Token: [REDACTED]")
        
        # Show JSON structure (with redacted token)
        import json
        display_config = {
            "mcpServers": {
                "github": {
                    "command": github_config["command"],
                    "args": github_config.get("args", []),
                    "env": {"GITHUB_PERSONAL_ACCESS_TOKEN": "[REDACTED]"}
                }
            }
        }
        print_info("Config structure:")
        for line in json.dumps(display_config, indent=2).split("\n"):
            print(f"      {line}")
        
        return True
        
    except Exception as e:
        print_error(f"MCP config generation failed: {e}")
        return False


def main():
    """Run all validation tests."""
    parser = argparse.ArgumentParser(
        description="Validate GitHub App credentials for MCP integration"
    )
    parser.add_argument(
        "--app-id",
        default=os.environ.get("GITHUB_APP_ID"),
        help="GitHub App ID (or set GITHUB_APP_ID env var)"
    )
    parser.add_argument(
        "--private-key",
        default=os.environ.get("GITHUB_APP_PRIVATE_KEY_PATH"),
        help="Path to private key PEM file (or set GITHUB_APP_PRIVATE_KEY_PATH)"
    )
    parser.add_argument(
        "--installation-id",
        default=os.environ.get("GITHUB_APP_INSTALLATION_ID"),
        help="Installation ID (or set GITHUB_APP_INSTALLATION_ID env var)"
    )
    parser.add_argument(
        "--repositories",
        nargs="*",
        help="Optional: scope token to specific repository names"
    )
    parser.add_argument(
        "--verbose",
        "-v",
        action="store_true",
        help="Show verbose output"
    )
    
    args = parser.parse_args()
    
    # Validate required arguments
    missing = []
    if not args.app_id:
        missing.append("--app-id or GITHUB_APP_ID")
    if not args.private_key:
        missing.append("--private-key or GITHUB_APP_PRIVATE_KEY_PATH")
    if not args.installation_id:
        missing.append("--installation-id or GITHUB_APP_INSTALLATION_ID")
    
    if missing:
        print("Error: Missing required configuration:")
        for m in missing:
            print(f"  - {m}")
        print("\nSee --help for usage.")
        sys.exit(1)
    
    print("\n" + "="*60)
    print("  GitHub App Credential Validation")
    print("="*60)
    print(f"\n  App ID:          {args.app_id}")
    print(f"  Private Key:     {args.private_key}")
    print(f"  Installation ID: {args.installation_id}")
    if args.repositories:
        print(f"  Repositories:    {args.repositories}")
    
    # Create generator
    try:
        generator = GitHubAppTokenGenerator(
            app_id=args.app_id,
            private_key_path=args.private_key,
            installation_id=args.installation_id
        )
    except Exception as e:
        print(f"\n❌ Failed to initialize: {e}")
        sys.exit(1)
    
    # Run tests
    results = []
    
    # Test 1: Validate credentials
    if not validate_credentials(generator):
        sys.exit(1)
    results.append(True)
    
    # Test 2: Generate token
    token_result = generate_token(generator, repositories=args.repositories)
    if not token_result:
        sys.exit(2)
    results.append(True)
    
    # Test 3: Test API access
    if not test_api_access(token_result["token"]):
        sys.exit(3)
    results.append(True)
    
    # Test 4: Test MCP config
    if not test_mcp_config(token_result["token"]):
        sys.exit(4)
    results.append(True)
    
    # Summary
    print_header("Summary")
    print_success("All tests passed!")
    print()
    print("  Your GitHub App is correctly configured for MCP integration.")
    print("  The agent can now use installation tokens for GitHub access.")
    print()
    print("  Next steps:")
    print("    1. Add credentials to .env file")
    print("    2. Start the agent with: make up-agent PROJECT=/path")
    print("    3. The entrypoint will auto-generate MCP config")
    print()
    
    return 0


if __name__ == "__main__":
    sys.exit(main())

