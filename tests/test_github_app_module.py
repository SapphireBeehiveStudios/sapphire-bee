"""
Unit tests for the github_app Python module.

Tests the GitHubAppTokenGenerator and MCPConfigGenerator classes
without requiring actual GitHub credentials.
"""

import json
import sys
import tempfile
import time
from pathlib import Path
from unittest.mock import Mock, patch, MagicMock

import pytest

# Add parent directory to path for imports
sys.path.insert(0, str(Path(__file__).parent.parent))

from github_app.token_generator import GitHubAppTokenGenerator
from github_app.mcp_config import MCPConfigGenerator, create_mcp_config_for_agent


# =============================================================================
# Fixtures
# =============================================================================

@pytest.fixture
def sample_private_key():
    """Generate a valid RSA private key for testing."""
    from cryptography.hazmat.primitives import serialization
    from cryptography.hazmat.primitives.asymmetric import rsa
    from cryptography.hazmat.backends import default_backend
    
    # Generate a proper RSA key for testing
    private_key = rsa.generate_private_key(
        public_exponent=65537,
        key_size=2048,
        backend=default_backend()
    )
    
    # Serialize to PEM format
    pem = private_key.private_bytes(
        encoding=serialization.Encoding.PEM,
        format=serialization.PrivateFormat.TraditionalOpenSSL,
        encryption_algorithm=serialization.NoEncryption()
    )
    
    return pem.decode()


@pytest.fixture
def temp_key_file(sample_private_key):
    """Create a temporary private key file."""
    with tempfile.NamedTemporaryFile(mode='w', suffix='.pem', delete=False) as f:
        f.write(sample_private_key)
        f.flush()
        yield f.name
    Path(f.name).unlink(missing_ok=True)


@pytest.fixture
def token_generator(temp_key_file):
    """Create a GitHubAppTokenGenerator instance."""
    return GitHubAppTokenGenerator(
        app_id="123456",
        private_key_path=temp_key_file,
        installation_id="12345678"
    )


# =============================================================================
# GitHubAppTokenGenerator Tests
# =============================================================================

class TestGitHubAppTokenGenerator:
    """Tests for GitHubAppTokenGenerator class."""
    
    def test_init_valid_key(self, temp_key_file):
        """Test initialization with valid private key."""
        generator = GitHubAppTokenGenerator(
            app_id="123456",
            private_key_path=temp_key_file,
            installation_id="12345678"
        )
        assert generator.app_id == "123456"
        assert generator.installation_id == "12345678"
    
    def test_init_missing_key_file(self):
        """Test initialization fails with missing key file."""
        with pytest.raises(FileNotFoundError) as exc_info:
            GitHubAppTokenGenerator(
                app_id="123456",
                private_key_path="/nonexistent/key.pem",
                installation_id="12345678"
            )
        assert "not found" in str(exc_info.value).lower()
    
    def test_init_invalid_key_format(self):
        """Test initialization fails with invalid key format."""
        with tempfile.NamedTemporaryFile(mode='w', suffix='.pem', delete=False) as f:
            f.write("not a valid key")
            f.flush()
            temp_path = f.name
        
        try:
            with pytest.raises(ValueError) as exc_info:
                GitHubAppTokenGenerator(
                    app_id="123456",
                    private_key_path=temp_path,
                    installation_id="12345678"
                )
            assert "invalid" in str(exc_info.value).lower()
        finally:
            Path(temp_path).unlink(missing_ok=True)
    
    def test_generate_jwt(self, token_generator):
        """Test JWT generation."""
        jwt_token = token_generator.generate_jwt()
        
        # JWT should be a non-empty string with 3 parts
        assert isinstance(jwt_token, str)
        assert len(jwt_token) > 0
        parts = jwt_token.split('.')
        assert len(parts) == 3, "JWT should have 3 parts (header.payload.signature)"
    
    def test_jwt_contains_correct_claims(self, token_generator):
        """Test that JWT contains correct claims."""
        import jwt
        
        jwt_token = token_generator.generate_jwt()
        
        # Decode without verification to check claims
        decoded = jwt.decode(jwt_token, options={"verify_signature": False})
        
        assert decoded["iss"] == "123456"
        assert "iat" in decoded
        assert "exp" in decoded
        assert decoded["exp"] > decoded["iat"]
        assert decoded["exp"] - decoded["iat"] == 600  # 10 minutes
    
    @patch('requests.post')
    def test_generate_installation_token_success(self, mock_post, token_generator):
        """Test successful installation token generation."""
        mock_response = Mock()
        mock_response.status_code = 201
        mock_response.json.return_value = {
            "token": "ghs_test_token_12345",
            "expires_at": "2024-01-15T12:00:00Z",
            "permissions": {"contents": "read", "issues": "write"},
            "repositories": [{"name": "test-repo"}]
        }
        mock_post.return_value = mock_response
        
        result = token_generator.generate_installation_token()
        
        assert result["token"] == "ghs_test_token_12345"
        assert result["expires_at"] == "2024-01-15T12:00:00Z"
        assert result["permissions"]["contents"] == "read"
        assert "test-repo" in result["repositories"]
    
    @patch('requests.post')
    def test_generate_installation_token_with_repos(self, mock_post, token_generator):
        """Test installation token generation with repository scope."""
        mock_response = Mock()
        mock_response.status_code = 201
        mock_response.json.return_value = {
            "token": "ghs_scoped_token",
            "expires_at": "2024-01-15T12:00:00Z",
            "permissions": {},
            "repositories": [{"name": "repo1"}, {"name": "repo2"}]
        }
        mock_post.return_value = mock_response
        
        result = token_generator.generate_installation_token(
            repositories=["repo1", "repo2"]
        )
        
        # Verify the request body included repositories
        call_kwargs = mock_post.call_args[1]
        assert call_kwargs["json"]["repositories"] == ["repo1", "repo2"]
    
    @patch('requests.post')
    def test_generate_installation_token_failure(self, mock_post, token_generator):
        """Test installation token generation handles API errors."""
        mock_response = Mock()
        mock_response.status_code = 401
        mock_response.json.return_value = {"message": "Bad credentials"}
        mock_response.raise_for_status.side_effect = Exception("401 Unauthorized")
        mock_post.return_value = mock_response
        
        with pytest.raises(Exception):
            token_generator.generate_installation_token()
    
    def test_get_token_expiry_seconds(self, token_generator):
        """Test token expiry calculation."""
        # Future expiry
        future = "2099-01-15T12:00:00Z"
        seconds = token_generator.get_token_expiry_seconds(future)
        assert seconds > 0
        
        # Past expiry
        past = "2020-01-15T12:00:00Z"
        seconds = token_generator.get_token_expiry_seconds(past)
        assert seconds < 0
    
    def test_should_refresh_token(self, token_generator):
        """Test token refresh decision."""
        # Far future - should not refresh
        future = "2099-01-15T12:00:00Z"
        assert not token_generator.should_refresh_token(future)
        
        # Past - should refresh
        past = "2020-01-15T12:00:00Z"
        assert token_generator.should_refresh_token(past)
    
    @patch('requests.get')
    def test_validate_credentials_success(self, mock_get, token_generator):
        """Test credential validation success."""
        mock_response = Mock()
        mock_response.status_code = 200
        mock_response.json.return_value = {
            "id": 123456,
            "name": "test-app",
            "owner": {"login": "test-owner"},
            "permissions": {"contents": "read"}
        }
        mock_get.return_value = mock_response
        
        result = token_generator.validate_credentials()
        
        assert result["id"] == 123456
        assert result["name"] == "test-app"
    
    @patch('requests.get')
    def test_validate_credentials_failure(self, mock_get, token_generator):
        """Test credential validation failure."""
        mock_response = Mock()
        mock_response.status_code = 401
        mock_response.raise_for_status.side_effect = Exception("Unauthorized")
        mock_get.return_value = mock_response
        
        with pytest.raises(Exception):
            token_generator.validate_credentials()


# =============================================================================
# MCPConfigGenerator Tests
# =============================================================================

class TestMCPConfigGenerator:
    """Tests for MCPConfigGenerator class."""
    
    def test_generate_config_basic(self):
        """Test basic MCP config generation."""
        generator = MCPConfigGenerator()
        config = generator.generate_config("test_token_123")
        
        assert "mcpServers" in config
        assert "github" in config["mcpServers"]
        
        github_config = config["mcpServers"]["github"]
        assert github_config["command"] == "npx"
        assert "-y" in github_config["args"]
        assert "@github/github-mcp-server" in github_config["args"]
        assert github_config["env"]["GITHUB_PERSONAL_ACCESS_TOKEN"] == "test_token_123"
    
    def test_generate_config_with_additional_env(self):
        """Test MCP config with additional environment variables."""
        generator = MCPConfigGenerator()
        config = generator.generate_config(
            "test_token",
            additional_env={"CUSTOM_VAR": "custom_value"}
        )
        
        github_config = config["mcpServers"]["github"]
        assert github_config["env"]["GITHUB_PERSONAL_ACCESS_TOKEN"] == "test_token"
        assert github_config["env"]["CUSTOM_VAR"] == "custom_value"
    
    def test_generate_config_with_additional_servers(self):
        """Test MCP config with additional servers."""
        generator = MCPConfigGenerator()
        config = generator.generate_config(
            "test_token",
            additional_servers={
                "other-server": {
                    "command": "node",
                    "args": ["server.js"]
                }
            }
        )
        
        assert "github" in config["mcpServers"]
        assert "other-server" in config["mcpServers"]
        assert config["mcpServers"]["other-server"]["command"] == "node"
    
    def test_write_config_new_file(self):
        """Test writing config to a new file."""
        with tempfile.TemporaryDirectory() as tmpdir:
            generator = MCPConfigGenerator()
            config = generator.generate_config("test_token")
            
            config_path = Path(tmpdir) / "subdir" / "config.json"
            result = generator.write_config(config, str(config_path))
            
            assert result.exists()
            
            # Verify content
            written = json.loads(result.read_text())
            assert written["mcpServers"]["github"]["env"]["GITHUB_PERSONAL_ACCESS_TOKEN"] == "test_token"
    
    def test_write_config_merge_existing(self):
        """Test merging with existing config file."""
        with tempfile.TemporaryDirectory() as tmpdir:
            config_path = Path(tmpdir) / "config.json"
            
            # Write initial config
            initial = {
                "mcpServers": {
                    "existing-server": {"command": "existing"}
                }
            }
            config_path.write_text(json.dumps(initial))
            
            # Merge new config
            generator = MCPConfigGenerator()
            config = generator.generate_config("test_token")
            generator.write_config(config, str(config_path), merge_existing=True)
            
            # Verify merge
            merged = json.loads(config_path.read_text())
            assert "existing-server" in merged["mcpServers"]
            assert "github" in merged["mcpServers"]
    
    def test_generate_env_file(self):
        """Test environment file generation."""
        with tempfile.TemporaryDirectory() as tmpdir:
            generator = MCPConfigGenerator()
            
            env_path = Path(tmpdir) / "github.env"
            result = generator.generate_env_file("test_token_xyz", str(env_path))
            
            assert result.exists()
            content = result.read_text()
            assert "GITHUB_PERSONAL_ACCESS_TOKEN=test_token_xyz" in content
            
            # Check permissions (should be 600)
            import stat
            mode = result.stat().st_mode
            assert mode & 0o777 == 0o600


class TestCreateMCPConfigForAgent:
    """Tests for the convenience function."""
    
    def test_create_mcp_config_for_agent(self):
        """Test the convenience function for agent config creation."""
        with tempfile.TemporaryDirectory() as tmpdir:
            result = create_mcp_config_for_agent(
                github_token="agent_token",
                config_dir=tmpdir
            )
            
            assert result.exists()
            assert result.name == "claude_mcp_config.json"
            
            config = json.loads(result.read_text())
            assert config["mcpServers"]["github"]["env"]["GITHUB_PERSONAL_ACCESS_TOKEN"] == "agent_token"


# =============================================================================
# Integration-style Tests (still mocked, but test full flow)
# =============================================================================

class TestFullTokenFlow:
    """Tests that verify the complete token generation flow."""
    
    @patch('requests.post')
    @patch('requests.get')
    def test_complete_flow(self, mock_get, mock_post, temp_key_file):
        """Test complete flow from validation to MCP config."""
        # Mock validate credentials
        mock_get.return_value = Mock(
            status_code=200,
            json=lambda: {"id": 123, "name": "test-app", "owner": {"login": "owner"}}
        )
        
        # Mock token generation
        mock_post.return_value = Mock(
            status_code=201,
            json=lambda: {
                "token": "ghs_complete_flow_token",
                "expires_at": "2024-01-15T12:00:00Z",
                "permissions": {"contents": "read"}
            }
        )
        
        # Create generator
        generator = GitHubAppTokenGenerator(
            app_id="123",
            private_key_path=temp_key_file,
            installation_id="456"
        )
        
        # Validate
        app_info = generator.validate_credentials()
        assert app_info["name"] == "test-app"
        
        # Generate token
        token_result = generator.generate_installation_token()
        assert token_result["token"] == "ghs_complete_flow_token"
        
        # Create MCP config
        with tempfile.TemporaryDirectory() as tmpdir:
            mcp_gen = MCPConfigGenerator()
            config = mcp_gen.generate_config(token_result["token"])
            config_path = mcp_gen.write_config(config, f"{tmpdir}/mcp.json")
            
            assert config_path.exists()
            saved = json.loads(config_path.read_text())
            assert saved["mcpServers"]["github"]["env"]["GITHUB_PERSONAL_ACCESS_TOKEN"] == "ghs_complete_flow_token"

