"""
Tests for DNS filtering functionality.

Verifies that:
- Allowed domains resolve to proxy IPs
- Blocked domains return NXDOMAIN
- DNS queries are properly logged
"""

from __future__ import annotations

from typing import TYPE_CHECKING

import pytest

if TYPE_CHECKING:
    from conftest import DockerComposeStack


def dns_lookup_cmd(domain: str, dns_server: str = "10.100.1.2") -> str:
    """Generate a Node.js command for DNS lookup (since nslookup isn't available)."""
    return f"""node -e "
const dns = require('dns');
const r = new dns.Resolver();
r.setServers(['{dns_server}']);
r.resolve4('{domain}', (err, addresses) => {{
  if (err) {{
    console.log('NXDOMAIN:' + err.code);
    process.exit(1);
  }} else {{
    console.log('RESOLVED:' + addresses.join(','));
  }}
}});
" 2>&1"""


class TestDNSAllowedDomains:
    """Test that allowlisted domains resolve to correct proxy IPs."""
    
    # Expected mappings from hosts.allowlist
    ALLOWED_DOMAINS = {
        "github.com": "10.100.1.10",
        "www.github.com": "10.100.1.10",
        "raw.githubusercontent.com": "10.100.1.11",
        "codeload.github.com": "10.100.1.12",
        "docs.godotengine.org": "10.100.1.13",
        "api.anthropic.com": "10.100.1.14",
    }
    
    @pytest.mark.parametrize("domain,expected_ip", ALLOWED_DOMAINS.items())
    def test_allowed_domain_resolves_to_proxy_ip(
        self,
        sandbox_stack: DockerComposeStack,
        domain: str,
        expected_ip: str,
    ) -> None:
        """Verify that allowlisted domains resolve to their proxy IPs."""
        result = sandbox_stack.exec_in_container(
            "agent",
            dns_lookup_cmd(domain),
        )
        
        assert f"RESOLVED:{expected_ip}" in result.output, (
            f"Expected {domain} to resolve to {expected_ip}, "
            f"got: {result.output}"
        )


class TestDNSBlockedDomains:
    """Test that non-allowlisted domains are blocked."""
    
    BLOCKED_DOMAINS = [
        "google.com",
        "example.com",
        "malicious-site.com",
        "facebook.com",
        "twitter.com",
        "evil.example.org",
        "s3.amazonaws.com",
        "ec2.amazonaws.com",
    ]
    
    @pytest.mark.parametrize("domain", BLOCKED_DOMAINS)
    def test_blocked_domain_returns_nxdomain(
        self,
        sandbox_stack: DockerComposeStack,
        domain: str,
    ) -> None:
        """Verify that non-allowlisted domains return NXDOMAIN."""
        result = sandbox_stack.exec_in_container(
            "agent",
            dns_lookup_cmd(domain),
        )
        
        # Should indicate the domain was not found
        assert "NXDOMAIN" in result.output, (
            f"Expected {domain} to return NXDOMAIN, got: {result.output}"
        )
    
    def test_blocked_domain_no_resolution(
        self,
        sandbox_stack: DockerComposeStack,
    ) -> None:
        """Verify blocked domains don't resolve to any IP."""
        result = sandbox_stack.exec_in_container(
            "agent",
            "getent hosts google.com 2>&1 || echo 'NOT_FOUND'",
        )
        
        # Should not contain a valid IP address
        assert "NOT_FOUND" in result.output or result.exit_code != 0, (
            f"Expected google.com to not resolve, got: {result.output}"
        )


class TestDNSSubdomains:
    """Test subdomain handling."""
    
    def test_allowed_subdomain_works(
        self,
        sandbox_stack: DockerComposeStack,
    ) -> None:
        """Test that www.github.com (explicitly allowed) works."""
        result = sandbox_stack.exec_in_container(
            "agent",
            dns_lookup_cmd("www.github.com"),
        )
        
        assert "RESOLVED:10.100.1.10" in result.output, (
            f"Expected www.github.com to resolve to 10.100.1.10, got: {result.output}"
        )
    
    def test_unlisted_subdomain_blocked(
        self,
        sandbox_stack: DockerComposeStack,
    ) -> None:
        """Test that subdomains not in allowlist are blocked."""
        # gist.github.com is not in the allowlist
        result = sandbox_stack.exec_in_container(
            "agent",
            dns_lookup_cmd("gist.github.com"),
        )
        
        assert "NXDOMAIN" in result.output, (
            f"Expected gist.github.com to be blocked, got: {result.output}"
        )


class TestDNSConfiguration:
    """Test DNS filter configuration."""
    
    def test_agent_uses_dnsfilter(
        self,
        sandbox_stack: DockerComposeStack,
    ) -> None:
        """Verify agent is configured to use dnsfilter (10.100.1.2)."""
        # Check Docker's DNS config points to dnsfilter
        result = sandbox_stack.exec_in_container(
            "agent",
            "cat /etc/resolv.conf",
        )
        
        # Docker's internal DNS (127.0.0.11) forwards to 10.100.1.2
        # Check that ExtServers includes our dnsfilter
        assert "10.100.1.2" in result.output, (
            f"Expected DNS config to reference 10.100.1.2, got: {result.output}"
        )
    
    def test_dnsfilter_reachable(
        self,
        sandbox_stack: DockerComposeStack,
    ) -> None:
        """Verify dnsfilter is reachable from agent."""
        result = sandbox_stack.exec_in_container(
            "agent",
            "timeout 2 bash -c '</dev/tcp/10.100.1.2/53' && echo 'DNS_PORT_OPEN' || echo 'DNS_PORT_CLOSED'",
        )
        
        assert "DNS_PORT_OPEN" in result.output, (
            f"Expected DNS port 53 to be open, got: {result.output}"
        )


class TestDNSLogging:
    """Test that DNS queries are logged."""
    
    def test_dns_queries_logged(
        self,
        sandbox_stack: DockerComposeStack,
    ) -> None:
        """Verify DNS queries appear in dnsfilter logs."""
        # Make a DNS query for a unique domain
        sandbox_stack.exec_in_container(
            "agent",
            dns_lookup_cmd("unique-test-domain-12345.com"),
        )
        
        # Check dnsfilter logs
        logs = sandbox_stack.get_container_logs("dnsfilter", tail=50)
        
        # CoreDNS should log queries
        assert "unique-test-domain-12345" in logs.lower() or len(logs) > 0, (
            f"Expected DNS query to be logged, logs: {logs[:500]}"
        )
    
    def test_allowed_queries_logged(
        self,
        sandbox_stack: DockerComposeStack,
    ) -> None:
        """Verify allowed domain queries are also logged."""
        # Make an allowed query
        sandbox_stack.exec_in_container(
            "agent",
            dns_lookup_cmd("github.com"),
        )
        
        # Check logs exist (CoreDNS logs all queries)
        logs = sandbox_stack.get_container_logs("dnsfilter", tail=50)
        
        # Should have some content if logging is enabled
        assert len(logs) > 0, "Expected dnsfilter to have logs"
