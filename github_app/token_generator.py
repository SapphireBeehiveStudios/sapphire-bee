"""
GitHub App Token Generator

Generates short-lived installation access tokens for GitHub App authentication.
These tokens can be used with the GitHub MCP server to provide secure, scoped
access to GitHub repositories.

Token Lifecycle:
- JWT tokens (for app authentication): Valid for 10 minutes
- Installation tokens: Valid for 1 hour
- Recommended refresh: At 50 minutes to avoid expiration

Example:
    generator = GitHubAppTokenGenerator(
        app_id="123456",
        private_key_path="./secrets/github-app-private-key.pem",
        installation_id="12345678"
    )
    
    # Get installation token for all accessible repos
    result = generator.generate_installation_token()
    token = result["token"]
    expires_at = result["expires_at"]
    
    # Or scope to specific repositories
    result = generator.generate_installation_token(
        repositories=["my-godot-game", "game-assets"]
    )
"""

import time
import json
from datetime import datetime, timezone
from pathlib import Path
from typing import Optional

import jwt
import requests


class GitHubAppTokenGenerator:
    """
    Generates GitHub App installation tokens for MCP server authentication.
    
    GitHub Apps use a two-step authentication process:
    1. Generate a JWT signed with the app's private key
    2. Exchange the JWT for an installation access token
    
    The installation token can then be used for GitHub API calls, including
    by the GitHub MCP server (via GITHUB_PERSONAL_ACCESS_TOKEN env var).
    
    Attributes:
        app_id: GitHub App ID (visible in app settings)
        private_key_path: Path to the PEM-encoded private key file
        installation_id: Installation ID (from the app's installation URL)
        api_base_url: GitHub API base URL (default: https://api.github.com)
    """
    
    # JWT expiration time (GitHub allows up to 10 minutes)
    JWT_EXPIRATION_SECONDS = 600  # 10 minutes
    
    # GitHub API endpoints
    INSTALLATION_TOKEN_ENDPOINT = "/app/installations/{installation_id}/access_tokens"
    
    def __init__(
        self,
        app_id: str,
        private_key_path: str,
        installation_id: str,
        api_base_url: str = "https://api.github.com"
    ):
        """
        Initialize the token generator.
        
        Args:
            app_id: The GitHub App's ID
            private_key_path: Path to the private key PEM file
            installation_id: The installation ID for the target org/user
            api_base_url: GitHub API base URL (for GitHub Enterprise)
        
        Raises:
            FileNotFoundError: If private key file doesn't exist
            ValueError: If private key is invalid
        """
        self.app_id = str(app_id)
        self.installation_id = str(installation_id)
        self.api_base_url = api_base_url.rstrip("/")
        
        # Load and validate private key
        key_path = Path(private_key_path)
        if not key_path.exists():
            raise FileNotFoundError(
                f"Private key not found: {private_key_path}\n"
                "Download it from your GitHub App settings page."
            )
        
        self._private_key = key_path.read_text()
        
        # Validate key format
        if "-----BEGIN RSA PRIVATE KEY-----" not in self._private_key:
            raise ValueError(
                f"Invalid private key format in {private_key_path}. "
                "Expected PEM-encoded RSA private key."
            )
    
    def generate_jwt(self) -> str:
        """
        Generate a JWT for GitHub App authentication.
        
        The JWT is signed with the app's private key and used to
        authenticate as the GitHub App itself (not an installation).
        
        Returns:
            A signed JWT string valid for 10 minutes.
        
        Note:
            This JWT is used to request installation tokens, not for
            direct API access.
        """
        now = int(time.time())
        
        payload = {
            # Issued at time
            "iat": now,
            # Expiration time (10 minutes from now)
            "exp": now + self.JWT_EXPIRATION_SECONDS,
            # GitHub App ID as issuer
            "iss": self.app_id,
        }
        
        token = jwt.encode(
            payload,
            self._private_key,
            algorithm="RS256"
        )
        
        return token
    
    def generate_installation_token(
        self,
        repositories: Optional[list[str]] = None,
        permissions: Optional[dict[str, str]] = None
    ) -> dict:
        """
        Generate an installation access token.
        
        Installation tokens are valid for 1 hour and provide access to
        the repositories where the GitHub App is installed.
        
        Args:
            repositories: Optional list of repository names (not full paths)
                         to scope the token to. If None, grants access to
                         all repositories in the installation.
            permissions: Optional dict of permissions to request. Format:
                        {"contents": "read", "issues": "write"}
                        If None, uses the app's configured permissions.
        
        Returns:
            Dict with:
                - token: The installation access token
                - expires_at: ISO 8601 timestamp when token expires
                - permissions: Dict of granted permissions
                - repositories: List of accessible repos (if scoped)
        
        Raises:
            requests.HTTPError: If the GitHub API request fails
            
        Example:
            result = generator.generate_installation_token()
            token = result["token"]
            # Use token for API calls or MCP server
        """
        # Generate JWT for app authentication
        app_jwt = self.generate_jwt()
        
        # Build request
        url = f"{self.api_base_url}{self.INSTALLATION_TOKEN_ENDPOINT.format(installation_id=self.installation_id)}"
        
        headers = {
            "Accept": "application/vnd.github+json",
            "Authorization": f"Bearer {app_jwt}",
            "X-GitHub-Api-Version": "2022-11-28",
        }
        
        # Build request body for scoped tokens
        body = {}
        if repositories:
            body["repositories"] = repositories
        if permissions:
            body["permissions"] = permissions
        
        # Make request
        response = requests.post(
            url,
            headers=headers,
            json=body if body else None,
            timeout=30
        )
        
        # Handle errors
        if response.status_code != 201:
            error_detail = ""
            try:
                error_data = response.json()
                error_detail = f": {error_data.get('message', '')}"
            except json.JSONDecodeError:
                pass
            
            response.raise_for_status()
        
        data = response.json()
        
        return {
            "token": data["token"],
            "expires_at": data["expires_at"],
            "permissions": data.get("permissions", {}),
            "repositories": [
                repo["name"] for repo in data.get("repositories", [])
            ] if "repositories" in data else None,
        }
    
    def get_token_expiry_seconds(self, expires_at: str) -> int:
        """
        Calculate seconds until token expires.
        
        Args:
            expires_at: ISO 8601 timestamp from generate_installation_token()
        
        Returns:
            Seconds until expiration (negative if already expired)
        """
        expiry = datetime.fromisoformat(expires_at.replace("Z", "+00:00"))
        now = datetime.now(timezone.utc)
        return int((expiry - now).total_seconds())
    
    def should_refresh_token(self, expires_at: str, buffer_seconds: int = 600) -> bool:
        """
        Check if token should be refreshed.
        
        Args:
            expires_at: ISO 8601 timestamp from generate_installation_token()
            buffer_seconds: Refresh if less than this many seconds remain
                           (default: 600 = 10 minutes)
        
        Returns:
            True if token should be refreshed
        """
        return self.get_token_expiry_seconds(expires_at) < buffer_seconds
    
    def validate_credentials(self) -> dict:
        """
        Validate that credentials are correct by fetching app info.
        
        Returns:
            Dict with app info on success
            
        Raises:
            requests.HTTPError: If authentication fails
        """
        app_jwt = self.generate_jwt()
        
        url = f"{self.api_base_url}/app"
        headers = {
            "Accept": "application/vnd.github+json",
            "Authorization": f"Bearer {app_jwt}",
            "X-GitHub-Api-Version": "2022-11-28",
        }
        
        response = requests.get(url, headers=headers, timeout=30)
        response.raise_for_status()
        
        return response.json()



