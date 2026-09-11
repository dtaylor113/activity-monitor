"""Shared utilities for activity-monitor gather scripts.

Centralizes duplicated patterns: ADF parsing, bot filtering, and review state machine.
"""
import json
import subprocess


# ── Bot Filters ──────────────────────────────────────────────────────────────

JIRA_BOT_AUTHORS = frozenset({
    'App SRE Jira bot',
    'Jira Bot',
    'Automation for Jira',
})

GITHUB_BOT_USERS = frozenset({
    'codecov[bot]',
    'coderabbitai[bot]',
    'github-actions[bot]',
    'dependabot[bot]',
    'codecov',
    'coderabbitai',
})


# ── ADF (Atlassian Document Format) → Plain Text ────────────────────────────

def adf_to_text(node, max_len=500):
    """Extract plain text from a Jira ADF document node.

    Args:
        node: ADF dict (typically a field like 'description' or 'body')
        max_len: truncate result to this length

    Returns:
        Plain text string, stripped and truncated.
    """
    if not node or not isinstance(node, dict):
        return ''
    parts = []
    for block in node.get('content', []):
        for item in block.get('content', []):
            if item.get('type') == 'text':
                parts.append(item.get('text', ''))
        parts.append(' ')
    return ' '.join(''.join(parts).split())[:max_len]


# ── Review State Machine ────────────────────────────────────────────────────

def resolve_reviewers(pr_num, repo, github_user, requested=None):
    """Build reviewer list for a PR with correct state transitions.

    Fetches reviews via gh API, applies state machine:
    - APPROVED / CHANGES_REQUESTED set directly
    - COMMENTED upgrades CHANGES_REQUESTED to show engagement
    - DISMISSED downgrades to COMMENTED
    - Re-requested reviewers reset to pending
    - Issue commenters upgrade from pending to commented

    Args:
        pr_num: PR number
        repo: owner/repo string
        github_user: current user's GitHub login
        requested: list of individually-requested reviewer logins

    Returns:
        (reviewers, my_last_review_at) where reviewers is list of
        {'user': str, 'state': str} dicts and my_last_review_at is ISO timestamp.
    """
    if requested is None:
        requested = []

    # Fetch PR author
    pr_author = ''
    try:
        r = subprocess.run(
            ['gh', 'api', f'repos/{repo}/pulls/{pr_num}',
             '--jq', '.user.login'],
            capture_output=True, text=True, timeout=15)
        if r.returncode == 0 and r.stdout.strip():
            pr_author = r.stdout.strip()
    except Exception:
        pass

    # Paginate all reviews
    reviewers = []
    my_last_review_at = ''
    try:
        r = subprocess.run(
            ['gh', 'api', '--paginate', f'repos/{repo}/pulls/{pr_num}/reviews',
             '--jq', '[.[] | {state: .state, user: .user.login, submitted_at: .submitted_at}]'],
            capture_output=True, text=True, timeout=30)
        if r.returncode == 0 and r.stdout.strip():
            reviews = []
            for chunk in r.stdout.strip().split('\n'):
                chunk = chunk.strip()
                if chunk:
                    try:
                        reviews.extend(json.loads(chunk))
                    except Exception:
                        pass
            reviewer_state = {}
            for rev in reviews:
                user = rev['user']
                if user == pr_author:
                    continue
                state = rev['state']
                if state in ('APPROVED', 'CHANGES_REQUESTED'):
                    reviewer_state[user] = state
                elif state == 'COMMENTED':
                    if user not in reviewer_state or reviewer_state[user] in ('COMMENTED', 'CHANGES_REQUESTED'):
                        reviewer_state[user] = 'COMMENTED'
                elif state == 'DISMISSED':
                    reviewer_state[user] = 'COMMENTED'
                if user == github_user and rev.get('submitted_at'):
                    my_last_review_at = rev['submitted_at']
            for user, state in reviewer_state.items():
                reviewers.append({'user': user, 'state': state.lower()})
    except Exception:
        pass

    # Add requested reviewers; reset to pending if re-requested
    existing_users = {rv['user'] for rv in reviewers}
    for user in requested:
        if user not in existing_users:
            reviewers.append({'user': user, 'state': 'pending'})
            existing_users.add(user)
        else:
            for rv in reviewers:
                if rv['user'] == user:
                    rv['state'] = 'pending'
                    break

    # Upgrade pending → commented if they left issue comments
    try:
        r = subprocess.run(
            ['gh', 'api', f'repos/{repo}/issues/{pr_num}/comments',
             '--jq', '[.[].user.login]'],
            capture_output=True, text=True, timeout=15)
        if r.returncode == 0 and r.stdout.strip():
            issue_commenters = set(json.loads(r.stdout))
            for rv in reviewers:
                if rv['state'] == 'pending' and rv['user'] in issue_commenters:
                    rv['state'] = 'commented'
    except Exception:
        pass

    return reviewers, my_last_review_at


def get_checks_status(pr_num, repo):
    """Get CI check status for a PR.

    Returns:
        String: 'passing', 'failing', 'pending', or 'unknown'
    """
    try:
        r = subprocess.run(
            ['gh', 'pr', 'checks', str(pr_num), '--repo', repo,
             '--json', 'name,state',
             '--jq', '{total: length, success: ([.[] | select(.state == "SUCCESS")] | length), fail: ([.[] | select(.state == "FAILURE")] | length), pending: ([.[] | select(.state == "PENDING")] | length)}'],
            capture_output=True, text=True, timeout=15)
        if r.returncode == 0 and r.stdout.strip():
            c = json.loads(r.stdout)
            if c['fail'] > 0:
                return 'failing'
            if c['pending'] > 0:
                return 'pending'
            if c['success'] > 0:
                return 'passing'
    except Exception:
        pass
    return 'unknown'
