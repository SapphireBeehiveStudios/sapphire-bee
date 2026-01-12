#!/usr/bin/env node
/**
 * issue-worker.js - Isolated agent that processes GitHub issues
 * 
 * This worker:
 * 1. Clones the repository into its isolated workspace
 * 2. Polls GitHub for issues with a specific label
 * 3. Claims an issue by adding "in-progress" label
 * 4. Creates a working branch
 * 5. Runs Claude to work on the issue
 * 6. Creates a PR and marks issue as done
 * 7. Repeats for next issue
 * 
 * Environment:
 *   GITHUB_REPO         - Repository to clone (owner/repo)
 *   GITHUB_BRANCH       - Base branch (default: main)
 *   ISSUE_LABEL         - Label to filter issues (default: agent-ready)
 *   POLL_INTERVAL       - Seconds between polls (default: 60)
 */

const { execSync, spawn } = require('child_process');
const fs = require('fs');
const path = require('path');
const https = require('https');
const crypto = require('crypto');

// Configuration
const GITHUB_REPO = process.env.GITHUB_REPO;
const GITHUB_BRANCH = process.env.GITHUB_BRANCH || 'main';
const ISSUE_LABEL = process.env.ISSUE_LABEL || 'agent-ready';
const POLL_INTERVAL = parseInt(process.env.POLL_INTERVAL || '60', 10) * 1000;
const PROJECT_DIR = '/project';

// Worker identity
const WORKER_ID = process.env.HOSTNAME || crypto.randomBytes(4).toString('hex');

// GitHub App auth
const GITHUB_APP_ID = process.env.GITHUB_APP_ID;
const GITHUB_APP_INSTALLATION_ID = process.env.GITHUB_APP_INSTALLATION_ID;
let GITHUB_APP_PRIVATE_KEY = process.env.GITHUB_APP_PRIVATE_KEY;
const GITHUB_APP_PRIVATE_KEY_PATH = process.env.GITHUB_APP_PRIVATE_KEY_PATH;

// State
let currentIssue = null;
let issuesProcessed = 0;
let githubToken = null;
let tokenExpiry = 0;

// Claim verification delay (ms) - wait for other workers to potentially claim
const CLAIM_VERIFICATION_DELAY = 3000;

// Claim timeout (ms) - claims older than this are considered stale/abandoned
// If a worker posted a claim but crashed/restarted before adding in-progress label,
// the claim becomes stale and should be ignored by other workers
const CLAIM_TIMEOUT = 2 * 60 * 1000; // 2 minutes (reduced from 5 to prevent ghost worker blocking)

/**
 * Log with worker prefix
 */
function log(message) {
    const timestamp = new Date().toISOString().replace('T', ' ').substring(0, 19);
    console.log(`[${timestamp}] [${WORKER_ID}] ${message}`);
}

/**
 * Sleep for specified milliseconds
 */
function sleep(ms) {
    return new Promise(resolve => setTimeout(resolve, ms));
}

/**
 * Load GitHub App private key
 */
function loadPrivateKey() {
    if (GITHUB_APP_PRIVATE_KEY) {
        // Base64 encoded
        return Buffer.from(GITHUB_APP_PRIVATE_KEY, 'base64').toString('utf-8');
    }
    if (GITHUB_APP_PRIVATE_KEY_PATH) {
        return fs.readFileSync(GITHUB_APP_PRIVATE_KEY_PATH, 'utf-8');
    }
    throw new Error('No GitHub App private key configured');
}

/**
 * Create JWT for GitHub App
 */
function createJWT(privateKey) {
    const now = Math.floor(Date.now() / 1000);
    const payload = {
        iat: now - 60,
        exp: now + 600,
        iss: GITHUB_APP_ID
    };
    
    // Simple JWT creation (header.payload.signature)
    const header = Buffer.from(JSON.stringify({ alg: 'RS256', typ: 'JWT' })).toString('base64url');
    const body = Buffer.from(JSON.stringify(payload)).toString('base64url');
    const signInput = `${header}.${body}`;
    
    const sign = crypto.createSign('RSA-SHA256');
    sign.update(signInput);
    const signature = sign.sign(privateKey, 'base64url');
    
    return `${signInput}.${signature}`;
}

/**
 * Make HTTPS request
 */
function request(options, body = null) {
    return new Promise((resolve, reject) => {
        const req = https.request(options, (res) => {
            let data = '';
            res.on('data', chunk => data += chunk);
            res.on('end', () => {
                try {
                    resolve({ status: res.statusCode, data: JSON.parse(data) });
                } catch {
                    resolve({ status: res.statusCode, data });
                }
            });
        });
        req.on('error', reject);
        if (body) req.write(JSON.stringify(body));
        req.end();
    });
}

/**
 * Get installation access token
 */
async function getInstallationToken() {
    if (githubToken && Date.now() < tokenExpiry) {
        return githubToken;
    }
    
    const privateKey = loadPrivateKey();
    const jwt = createJWT(privateKey);
    
    const response = await request({
        hostname: 'api.github.com',
        path: `/app/installations/${GITHUB_APP_INSTALLATION_ID}/access_tokens`,
        method: 'POST',
        headers: {
            'Authorization': `Bearer ${jwt}`,
            'Accept': 'application/vnd.github+json',
            'User-Agent': 'sapphire-bee-agent',
            'X-GitHub-Api-Version': '2022-11-28'
        }
    });
    
    if (response.status !== 201) {
        throw new Error(`Failed to get installation token: ${JSON.stringify(response.data)}`);
    }
    
    githubToken = response.data.token;
    tokenExpiry = new Date(response.data.expires_at).getTime() - 60000; // 1 min buffer
    
    return githubToken;
}

/**
 * GitHub API call
 */
async function github(method, endpoint, body = null) {
    const token = await getInstallationToken();
    
    return request({
        hostname: 'api.github.com',
        path: endpoint,
        method,
        headers: {
            'Authorization': `Bearer ${token}`,
            'Accept': 'application/vnd.github+json',
            'User-Agent': 'sapphire-bee-agent',
            'X-GitHub-Api-Version': '2022-11-28',
            'Content-Type': 'application/json'
        }
    }, body);
}

/**
 * Clone repository if not already cloned
 */
async function ensureRepoCloned() {
    const gitDir = path.join(PROJECT_DIR, '.git');
    
    if (fs.existsSync(gitDir)) {
        log('Repository already cloned, pulling latest...');
        try {
            execSync(`git fetch origin && git checkout ${GITHUB_BRANCH} && git pull origin ${GITHUB_BRANCH}`, {
                cwd: PROJECT_DIR,
                stdio: 'inherit'
            });
        } catch (err) {
            log(`Warning: git pull failed: ${err.message}`);
        }

        // Ensure pre-commit and pre-push hooks are installed
        const preCommitConfig = path.join(PROJECT_DIR, '.pre-commit-config.yaml');
        if (fs.existsSync(preCommitConfig)) {
            try {
                // Check if hooks are installed by looking for the pre-commit hook file
                const hookFile = path.join(PROJECT_DIR, '.git', 'hooks', 'pre-commit');
                if (!fs.existsSync(hookFile)) {
                    log('Installing git hooks...');
                    execSync('pre-commit install --hook-type pre-commit', {
                        cwd: PROJECT_DIR,
                        stdio: 'pipe'  // Quiet output for existing repos
                    });
                    execSync('pre-commit install --hook-type pre-push', {
                        cwd: PROJECT_DIR,
                        stdio: 'pipe'
                    });
                    log('Git hooks installed');
                }
            } catch (err) {
                log(`Warning: Failed to install git hooks: ${err.message}`);
            }
        }

        return;
    }
    
    log(`Cloning repository: ${GITHUB_REPO}`);
    
    const token = await getInstallationToken();
    const cloneUrl = `https://x-access-token:${token}@github.com/${GITHUB_REPO}.git`;
    
    execSync(`git clone --branch ${GITHUB_BRANCH} ${cloneUrl} .`, {
        cwd: PROJECT_DIR,
        stdio: 'inherit'
    });
    
    // Configure git
    execSync('git config user.name "Sapphire Bee Agent"', { cwd: PROJECT_DIR });
    execSync('git config user.email "2587725+sapphire-bee[bot]@users.noreply.github.com"', { cwd: PROJECT_DIR });

    // Install pre-commit hooks if .pre-commit-config.yaml exists
    const preCommitConfig = path.join(PROJECT_DIR, '.pre-commit-config.yaml');
    if (fs.existsSync(preCommitConfig)) {
        log('Installing pre-commit and pre-push hooks...');
        try {
            // Install for pre-commit (runs on git commit)
            execSync('pre-commit install --hook-type pre-commit', {
                cwd: PROJECT_DIR,
                stdio: 'inherit'
            });
            // Install for pre-push (runs on git push)
            execSync('pre-commit install --hook-type pre-push', {
                cwd: PROJECT_DIR,
                stdio: 'inherit'
            });
            log('Git hooks installed successfully');
        } catch (err) {
            log(`Warning: Failed to install git hooks: ${err.message}`);
        }
    }

    log('Repository cloned successfully');
}

/**
 * Find an available issue to work on
 */
async function findAvailableIssue() {
    const [owner, repo] = GITHUB_REPO.split('/');
    
    // Get issues with our label, excluding ones already in progress
    const response = await github('GET', 
        `/repos/${owner}/${repo}/issues?labels=${ISSUE_LABEL}&state=open&sort=created&direction=asc`
    );
    
    if (response.status !== 200) {
        log(`Failed to fetch issues: ${JSON.stringify(response.data)}`);
        return null;
    }
    
    // Find first issue not labeled "in-progress"
    for (const issue of response.data) {
        const hasInProgress = issue.labels.some(l => l.name === 'in-progress');
        if (!hasInProgress && !issue.pull_request) {
            return issue;
        }
    }
    
    return null;
}

/**
 * Claim an issue using atomic comment verification
 * 
 * This prevents race conditions where multiple workers claim the same issue.
 * Uses a two-phase approach:
 * 1. Check if already claimed (in-progress label exists)
 * 2. Post claim comment, wait, verify we were first
 * 3. Add in-progress label BEFORE updating comment (so other workers see it)
 */
async function claimIssue(issue) {
    const [owner, repo] = GITHUB_REPO.split('/');
    const claimId = `CLAIM:${WORKER_ID}:${Date.now()}`;
    
    log(`Attempting to claim issue #${issue.number}...`);
    
    // Step 0: Double-check issue doesn't already have in-progress label
    // (might have been claimed between findAvailableIssue and now)
    const issueResponse = await github('GET',
        `/repos/${owner}/${repo}/issues/${issue.number}`
    );
    if (issueResponse.status === 200) {
        const hasInProgress = issueResponse.data.labels?.some(l => l.name === 'in-progress');
        if (hasInProgress) {
            log(`Issue #${issue.number} already has in-progress label, skipping...`);
            return false;
        }
    }
    
    // Step 1: Post claim comment atomically
    const claimResponse = await github('POST',
        `/repos/${owner}/${repo}/issues/${issue.number}/comments`,
        { body: claimId }
    );
    
    if (claimResponse.status !== 201) {
        log(`Failed to post claim comment: ${JSON.stringify(claimResponse.data)}`);
        return false;
    }
    
    const ourCommentId = claimResponse.data.id;
    log(`Posted claim comment (id: ${ourCommentId}), waiting for other claims...`);
    
    // Step 2: Wait for other workers to potentially post their claims
    await sleep(CLAIM_VERIFICATION_DELAY);
    
    // Step 3: Re-check for in-progress label (another worker might have won and added it)
    const recheckResponse = await github('GET',
        `/repos/${owner}/${repo}/issues/${issue.number}`
    );
    if (recheckResponse.status === 200) {
        const hasInProgress = recheckResponse.data.labels?.some(l => l.name === 'in-progress');
        if (hasInProgress) {
            log(`Issue #${issue.number} was claimed by another worker (in-progress label found)`);
            // Clean up our claim comment
            await github('DELETE',
                `/repos/${owner}/${repo}/issues/comments/${ourCommentId}`
            );
            return false;
        }
    }
    
    // Step 4: Fetch all comments and find CLAIM comments
    const commentsResponse = await github('GET',
        `/repos/${owner}/${repo}/issues/${issue.number}/comments?per_page=100`
    );
    
    if (commentsResponse.status !== 200) {
        log(`Failed to fetch comments: ${JSON.stringify(commentsResponse.data)}`);
        return false;
    }
    
    // Filter for CLAIM comments, exclude stale ones, verify accessibility, and sort by creation time
    const now = Date.now();
    const allClaims = commentsResponse.data.filter(c => c.body && c.body.startsWith('CLAIM:'));

    log(`Found ${allClaims.length} total CLAIM comment(s), verifying...`);

    // Verify each claim is still accessible and not stale
    const validClaims = [];
    for (const claim of allClaims) {
        const workerId = claim.body.split(':')[1] || 'unknown';
        const claimAge = now - new Date(claim.created_at).getTime();

        // Check if claim is stale (older than CLAIM_TIMEOUT)
        if (claimAge > CLAIM_TIMEOUT) {
            log(`Ignoring stale claim from worker ${workerId} (age: ${Math.round(claimAge / 1000)}s, limit: ${CLAIM_TIMEOUT / 1000}s)`);
            continue;
        }

        // Verify claim comment is still accessible (not deleted/ghost)
        try {
            const verifyResponse = await github('GET',
                `/repos/${owner}/${repo}/issues/comments/${claim.id}`
            );
            if (verifyResponse.status !== 200) {
                log(`Ignoring ghost claim from worker ${workerId} (comment ${claim.id} returned ${verifyResponse.status})`);
                continue;
            }
            validClaims.push(claim);
            log(`Verified claim from worker ${workerId} (age: ${Math.round(claimAge / 1000)}s)`);
        } catch (err) {
            log(`Ignoring ghost claim from worker ${workerId} (comment ${claim.id} verification failed: ${err.message})`);
        }
    }

    const claims = validClaims.sort((a, b) => new Date(a.created_at) - new Date(b.created_at));
    
    // Step 5: Check if our claim was first
    if (claims.length === 0 || claims[0].id !== ourCommentId) {
        // We lost the race - another worker claimed first
        const winner = claims.length > 0 ? claims[0].body.split(':')[1] : 'unknown';
        log(`Lost claim race to worker ${winner}, skipping issue #${issue.number}`);
        
        // Clean up our claim comment
        await github('DELETE',
            `/repos/${owner}/${repo}/issues/comments/${ourCommentId}`
        );
        
        return false;
    }
    
    // Step 6: We won! Add in-progress label FIRST (before updating comment)
    // This is critical - other workers check for this label
    log(`Won claim for issue #${issue.number}!`);
    
    const labelResponse = await github('POST',
        `/repos/${owner}/${repo}/issues/${issue.number}/labels`,
        { labels: ['in-progress'] }
    );
    
    if (labelResponse.status !== 200) {
        log(`Warning: Failed to add in-progress label: ${JSON.stringify(labelResponse.data)}`);
        // Continue anyway since we have the claim
    }
    
    // Step 7: NOW update our claim comment to a nicer message
    // (only after in-progress label is set)
    await github('PATCH',
        `/repos/${owner}/${repo}/issues/comments/${ourCommentId}`,
        { body: `🤖 Agent \`${WORKER_ID}\` claimed and is now working on this issue.` }
    );
    
    return true;
}

/**
 * Check if issue has an existing open PR
 * Returns PR object with branch name if found, null otherwise
 */
async function findExistingPR(issue) {
    const [owner, repo] = GITHUB_REPO.split('/');

    // Search for PRs that reference this issue
    const response = await github('GET',
        `/repos/${owner}/${repo}/pulls?state=open&per_page=100`
    );

    if (response.status !== 200) {
        log(`Warning: Failed to fetch PRs: ${response.status}`);
        return null;
    }

    // Find PR that mentions this issue number in body or title
    const issueRef = `#${issue.number}`;
    for (const pr of response.data) {
        const titleMatch = pr.title && pr.title.includes(issueRef);
        const bodyMatch = pr.body && pr.body.includes(issueRef);

        if (titleMatch || bodyMatch) {
            log(`Found existing PR #${pr.number} for issue #${issue.number}: ${pr.head.ref}`);
            return {
                number: pr.number,
                branch: pr.head.ref,
                title: pr.title,
                checks_failed: false // We'll assume it needs fixing if we're here
            };
        }
    }

    return null;
}

/**
 * Create a working branch for the issue, or check out existing PR branch
 */
async function createWorkingBranch(issue) {
    // CRITICAL: Clean up any uncommitted changes from previous failed attempts
    // This prevents "Your local changes would be overwritten" errors
    try {
        log('Cleaning workspace...');
        // Reset any staged changes
        execSync('git reset --hard HEAD', {
            cwd: PROJECT_DIR,
            stdio: 'pipe'
        });
        // Remove untracked files
        execSync('git clean -fd', {
            cwd: PROJECT_DIR,
            stdio: 'pipe'
        });
    } catch (err) {
        log(`Warning: Failed to clean workspace: ${err.message}`);
    }

    // First, check if there's an existing PR for this issue
    const existingPR = await findExistingPR(issue);

    if (existingPR) {
        log(`Checking out existing PR branch: ${existingPR.branch}`);

        // Ensure we're on the base branch first
        execSync(`git checkout ${GITHUB_BRANCH}`, {
            cwd: PROJECT_DIR,
            stdio: 'pipe'
        });

        // Fetch the PR branch and check it out
        try {
            execSync(`git fetch origin ${existingPR.branch}`, {
                cwd: PROJECT_DIR,
                stdio: 'inherit'
            });
            execSync(`git checkout ${existingPR.branch}`, {
                cwd: PROJECT_DIR,
                stdio: 'inherit'
            });
            execSync(`git pull origin ${existingPR.branch}`, {
                cwd: PROJECT_DIR,
                stdio: 'inherit'
            });

            log(`✓ Checked out existing branch: ${existingPR.branch}`);
            return existingPR.branch;
        } catch (err) {
            log(`Warning: Failed to checkout existing branch, creating new one: ${err.message}`);
            // Fall through to create new branch
        }
    }

    // No existing PR, or failed to check it out - create new branch
    const branchName = `claude/issue-${issue.number}-${Date.now()}`;
    log(`Creating new branch: ${branchName}`);

    // Ensure we're on the base branch and up to date
    execSync(`git checkout ${GITHUB_BRANCH} && git pull origin ${GITHUB_BRANCH}`, {
        cwd: PROJECT_DIR,
        stdio: 'inherit'
    });

    // Create and checkout new branch
    execSync(`git checkout -b ${branchName}`, {
        cwd: PROJECT_DIR,
        stdio: 'inherit'
    });

    return branchName;
}

/**
 * Refresh MCP token in ~/.claude.json
 * This ensures Claude's MCP tools have a fresh token for GitHub API calls
 */
async function refreshMcpToken() {
    try {
        const token = await getInstallationToken();
        const claudeConfigPath = path.join(process.env.HOME || '/home/claude', '.claude.json');
        
        let config = {};
        if (fs.existsSync(claudeConfigPath)) {
            config = JSON.parse(fs.readFileSync(claudeConfigPath, 'utf-8'));
        }
        
        // Update the MCP GitHub server token
        if (!config.mcpServers) config.mcpServers = {};
        if (!config.mcpServers.github) {
            config.mcpServers.github = {
                command: 'npx',
                args: ['-y', '@github/github-mcp-server']
            };
        }
        if (!config.mcpServers.github.env) config.mcpServers.github.env = {};
        config.mcpServers.github.env.GITHUB_PERSONAL_ACCESS_TOKEN = token;
        
        fs.writeFileSync(claudeConfigPath, JSON.stringify(config, null, 2));
        log('Refreshed MCP token in ~/.claude.json');
    } catch (err) {
        log(`Warning: Failed to refresh MCP token: ${err.message}`);
        // Continue anyway - MCP tools may still work with existing token
    }
}

/**
 * Run Claude on the issue
 */
async function runClaude(issue, branchName) {
    // Check if this is an existing PR branch that needs fixing
    const isExistingBranch = branchName.includes('-') &&
                            !branchName.endsWith(Date.now().toString().slice(0, -3));

    const prompt = isExistingBranch
        ? `You are working on GitHub issue #${issue.number}: "${issue.title}"

Issue description:
${issue.body || 'No description provided.'}

IMPORTANT: You are working on an EXISTING branch (${branchName}) that has an open PR.
This means there's already an implementation attempt that may be failing tests or checks.

Instructions:
1. Review the existing code changes in this branch (git log, git diff ${GITHUB_BRANCH})
2. Identify what's failing (check test output, build errors, or issue comments)
3. Fix the problems - don't start from scratch, improve what's there
4. Run tests to verify your fixes work
5. Commit your changes with a clear message explaining what you fixed

When you're done, summarize what was broken and how you fixed it.`
        : `You are working on GitHub issue #${issue.number}: "${issue.title}"

Issue description:
${issue.body || 'No description provided.'}

Instructions:
1. Analyze the issue and understand what needs to be done
2. Make the necessary code changes to address this issue
3. Write tests for your changes
4. Run all tests to verify everything works
5. Commit your changes with a clear commit message referencing the issue

When you're done, summarize what you changed.`;

    log(`Running Claude on issue #${issue.number}...`);
    if (isExistingBranch) {
        log(`📝 Note: Fixing existing PR branch`);
    }

    // Refresh MCP token before running Claude (in case it expired)
    await refreshMcpToken();

    // Set up log file for this conversation
    const logDir = '/pool-logs';
    const logFile = path.join(logDir, `worker-${WORKER_ID}-issue-${issue.number}-${Date.now()}.log`);
    let logStream = null;

    // Create log directory if it exists (mounted volume)
    if (fs.existsSync(logDir)) {
        try {
            logStream = fs.createWriteStream(logFile, { flags: 'a' });
            logStream.write(`\n${'═'.repeat(70)}\n`);
            logStream.write(`Worker: ${WORKER_ID}\n`);
            logStream.write(`Issue: #${issue.number} - ${issue.title}\n`);
            logStream.write(`Started: ${new Date().toISOString()}\n`);
            logStream.write(`${'═'.repeat(70)}\n\n`);
            log(`Logging conversation to: ${logFile}`);
        } catch (err) {
            log(`Warning: Failed to create log file: ${err.message}`);
        }
    }

    return new Promise((resolve) => {
        const claude = spawn('claude', [
            '--dangerously-skip-permissions',
            '--no-session-persistence',  // Fresh context for each issue
            prompt
        ], {
            cwd: PROJECT_DIR,
            stdio: ['ignore', 'pipe', 'pipe'],
            env: { ...process.env, TERM: 'xterm-256color' }
        });

        let output = '';

        claude.stdout.on('data', (data) => {
            const text = data.toString();
            // Write to stdout (captured by Docker logs)
            process.stdout.write(text);
            // Write to log file (persistent)
            if (logStream) logStream.write(text);
            output += text;
        });

        claude.stderr.on('data', (data) => {
            const text = data.toString();
            process.stderr.write(text);
            if (logStream) logStream.write(`[STDERR] ${text}`);
        });

        claude.on('close', (code) => {
            if (logStream) {
                logStream.write(`\n\n${'═'.repeat(70)}\n`);
                logStream.write(`Finished: ${new Date().toISOString()}\n`);
                logStream.write(`Exit code: ${code}\n`);
                logStream.write(`${'═'.repeat(70)}\n`);
                logStream.end();
            }
            resolve({ success: code === 0, output });
        });

        claude.on('error', (err) => {
            log(`Failed to run Claude: ${err.message}`);
            if (logStream) {
                logStream.write(`\nERROR: ${err.message}\n`);
                logStream.end();
            }
            resolve({ success: false, output: err.message });
        });
    });
}

/**
 * Push branch and create PR
 */
async function createPullRequest(issue, branchName, claudeOutput) {
    const [owner, repo] = GITHUB_REPO.split('/');
    const token = await getInstallationToken();
    
    // Push the branch
    log('Pushing branch...');
    execSync(`git push https://x-access-token:${token}@github.com/${GITHUB_REPO}.git ${branchName}`, {
        cwd: PROJECT_DIR,
        stdio: 'inherit'
    });
    
    // Create PR
    log('Creating pull request...');
    const prBody = `## Fixes #${issue.number}

### Changes Made
${claudeOutput.substring(0, 3000)}

---
🤖 *This PR was automatically created by Sapphire Bee Agent \`${WORKER_ID}\`*`;

    const prResponse = await github('POST',
        `/repos/${owner}/${repo}/pulls`,
        {
            title: `Fix: ${issue.title}`,
            body: prBody,
            head: branchName,
            base: GITHUB_BRANCH
        }
    );
    
    if (prResponse.status !== 201) {
        log(`Failed to create PR: ${JSON.stringify(prResponse.data)}`);
        return null;
    }
    
    return prResponse.data;
}

/**
 * Complete issue processing
 */
async function completeIssue(issue, pr, success) {
    const [owner, repo] = GITHUB_REPO.split('/');
    
    // Remove in-progress, add agent-complete or agent-failed
    const newLabel = success ? 'agent-complete' : 'agent-failed';
    
    // Remove in-progress label
    await github('DELETE',
        `/repos/${owner}/${repo}/issues/${issue.number}/labels/in-progress`
    );
    
    // Remove the trigger label
    await github('DELETE',
        `/repos/${owner}/${repo}/issues/${issue.number}/labels/${ISSUE_LABEL}`
    );
    
    // Add completion label
    await github('POST',
        `/repos/${owner}/${repo}/issues/${issue.number}/labels`,
        { labels: [newLabel] }
    );
    
    // Add completion comment
    const message = success && pr
        ? `✅ Agent completed work on this issue.\n\nPull request: #${pr.number}`
        : `❌ Agent encountered an error while working on this issue.`;
    
    await github('POST',
        `/repos/${owner}/${repo}/issues/${issue.number}/comments`,
        { body: message }
    );
}

/**
 * Process a single issue
 */
async function processIssue(issue) {
    currentIssue = issue;
    log(`\n${'═'.repeat(70)}`);
    log(`📋 Processing issue #${issue.number}: ${issue.title}`);
    log(`${'═'.repeat(70)}`);
    
    try {
        // Claim the issue
        const claimed = await claimIssue(issue);
        if (!claimed) {
            log('Failed to claim issue, skipping...');
            currentIssue = null;
            return false;
        }
        
        // Create working branch or checkout existing PR branch
        const branchName = await createWorkingBranch(issue);
        log(`Working on branch: ${branchName}`);

        // Check if this is an existing PR
        const existingPR = await findExistingPR(issue);

        // Run Claude (with context about whether fixing existing PR)
        const result = await runClaude(issue, branchName);
        
        // Check if any commits were made
        let hasChanges = false;
        try {
            const status = execSync('git status --porcelain', { cwd: PROJECT_DIR }).toString();
            hasChanges = status.trim().length > 0;
            
            if (hasChanges) {
                // Commit any uncommitted changes
                execSync('git add -A', { cwd: PROJECT_DIR });
                execSync(`git commit -m "Address issue #${issue.number}" --allow-empty`, { cwd: PROJECT_DIR });
            }
            
            // Check if we have commits beyond the base branch
            const commits = execSync(`git log ${GITHUB_BRANCH}..HEAD --oneline`, { cwd: PROJECT_DIR }).toString();
            hasChanges = commits.trim().length > 0;
        } catch {
            hasChanges = false;
        }
        
        let pr = existingPR;
        if (hasChanges && result.success) {
            if (existingPR) {
                // Update existing PR with a comment
                log(`Updating existing PR #${existingPR.number}`);
                const [owner, repo] = GITHUB_REPO.split('/');
                await github('POST',
                    `/repos/${owner}/${repo}/issues/${existingPR.number}/comments`,
                    {
                        body: `🔧 Agent fixed issues in this PR.\n\n${result.output || 'Updated code and fixed failing checks.'}`
                    }
                );
            } else {
                // Create new PR
                pr = await createPullRequest(issue, branchName, result.output);
                if (pr) {
                    log(`✅ Created PR #${pr.number}`);
                }
            }
        }
        
        // Complete the issue
        await completeIssue(issue, pr, result.success && (pr || !hasChanges));
        
        issuesProcessed++;
        log(`✅ Completed issue #${issue.number}`);

        // Return to base branch for next issue and clean up
        execSync('git reset --hard HEAD && git clean -fd', { cwd: PROJECT_DIR, stdio: 'pipe' });
        execSync(`git checkout ${GITHUB_BRANCH}`, { cwd: PROJECT_DIR, stdio: 'inherit' });

        currentIssue = null;
        return true;
        
    } catch (err) {
        log(`❌ Error processing issue #${issue.number}: ${err.message}`);

        try {
            await completeIssue(issue, null, false);
            // Clean up any uncommitted changes before moving to next issue
            execSync('git reset --hard HEAD && git clean -fd', { cwd: PROJECT_DIR, stdio: 'pipe' });
            execSync(`git checkout ${GITHUB_BRANCH}`, { cwd: PROJECT_DIR, stdio: 'pipe' });
        } catch {}

        currentIssue = null;
        return false;
    }
}

/**
 * Main polling loop
 */
async function pollForIssues() {
    const issue = await findAvailableIssue();
    
    if (issue) {
        await processIssue(issue);
        // Add small random jitter before next poll to reduce collisions
        const jitter = Math.random() * 5000;
        await sleep(jitter);
        setImmediate(pollForIssues);
    } else {
        // No issues, wait and poll again with jitter
        const jitter = Math.random() * 10000;
        setTimeout(pollForIssues, POLL_INTERVAL + jitter);
    }
}

/**
 * Display startup banner
 */
function showBanner() {
    console.log('');
    console.log('╔══════════════════════════════════════════════════════════════════════╗');
    console.log('║                   Claude Issue Worker (Isolated)                     ║');
    console.log('╠══════════════════════════════════════════════════════════════════════╣');
    console.log(`║  Worker ID:   ${WORKER_ID.padEnd(52)} ║`);
    console.log(`║  Repository:  ${(GITHUB_REPO || 'NOT SET').padEnd(52)} ║`);
    console.log(`║  Branch:      ${GITHUB_BRANCH.padEnd(52)} ║`);
    console.log(`║  Issue Label: ${ISSUE_LABEL.padEnd(52)} ║`);
    console.log(`║  Poll:        ${(POLL_INTERVAL/1000 + 's').padEnd(52)} ║`);
    console.log('╠══════════════════════════════════════════════════════════════════════╣');
    console.log('║  Polls for issues labeled with ISSUE_LABEL, claims and processes.    ║');
    console.log('║  Creates PRs for completed work. Runs in complete isolation.         ║');
    console.log('╚══════════════════════════════════════════════════════════════════════╝');
    console.log('');
}

/**
 * Handle graceful shutdown
 */
function setupShutdown() {
    const shutdown = (signal) => {
        log('');
        log(`📊 Worker Statistics`);
        log(`   Issues processed: ${issuesProcessed}`);
        log(`   Current issue: ${currentIssue ? `#${currentIssue.number}` : 'none'}`);
        log(`\n👋 Received ${signal}, shutting down...`);
        process.exit(0);
    };
    
    process.on('SIGINT', () => shutdown('SIGINT'));
    process.on('SIGTERM', () => shutdown('SIGTERM'));
}

/**
 * Validate configuration
 */
function validateConfig() {
    const errors = [];
    
    if (!GITHUB_REPO) errors.push('GITHUB_REPO is required');
    if (!GITHUB_APP_ID) errors.push('GITHUB_APP_ID is required');
    if (!GITHUB_APP_INSTALLATION_ID) errors.push('GITHUB_APP_INSTALLATION_ID is required');
    if (!GITHUB_APP_PRIVATE_KEY && !GITHUB_APP_PRIVATE_KEY_PATH) {
        errors.push('GITHUB_APP_PRIVATE_KEY or GITHUB_APP_PRIVATE_KEY_PATH is required');
    }
    
    if (errors.length > 0) {
        console.error('Configuration errors:');
        errors.forEach(e => console.error(`  - ${e}`));
        process.exit(1);
    }
}

/**
 * Main entry point
 */
async function main() {
    showBanner();
    validateConfig();
    setupShutdown();
    
    // Clone/update repository
    await ensureRepoCloned();
    
    // Add startup jitter to stagger workers (0-15 seconds)
    const startupJitter = Math.random() * 15000;
    log(`⏳ Starting issue polling in ${(startupJitter/1000).toFixed(1)}s (stagger delay)`);
    log(`   Poll interval: ${POLL_INTERVAL/1000}s`);
    log(`   Looking for issues with label: "${ISSUE_LABEL}"`);
    
    await sleep(startupJitter);
    
    // Start polling
    pollForIssues();
}

// Run
main().catch(err => {
    console.error('Fatal error:', err);
    process.exit(1);
});

