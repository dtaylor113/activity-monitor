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
    """Build reviewer list for a PR using raw GitHub review states.

    Each reviewer's state is their single latest PullRequestReview.state
    (lowercased), taken as-is from the API — no derived "ball in your
    court" transitions (no COMMENTED-upgrades-CHANGES_REQUESTED, no
    DISMISSED-downgrades-to-COMMENTED, no issue-comment-inferred
    pending→commented). The one adjustment: GitHub dismisses a review's
    own state (not just the PR's overall decision) when new commits
    invalidate it; if that user is back in the requested-reviewers list,
    that means awaiting a fresh review, so it's shown as 'pending' rather
    than the stale 'dismissed' state. Anyone requested who hasn't
    reviewed at all yet is also 'pending'.

    Mirrors simplifyReviewers() in GITHUB_ACTIVITY.html — keep both in
    sync if this logic changes.

    Args:
        pr_num: PR number
        repo: owner/repo string
        github_user: current user's GitHub login (excluded — self-review
            doesn't count)
        requested: list of individually-requested reviewer logins

    Returns:
        List of {'user': str, 'state': str} dicts.
    """
    if requested is None:
        requested = []

    # Fetch PR author (excluded from reviewers)
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

    # Paginate all reviews, keep each user's latest raw state (the API
    # returns reviews oldest-first, so last write wins).
    latest_state = {}
    try:
        r = subprocess.run(
            ['gh', 'api', '--paginate', f'repos/{repo}/pulls/{pr_num}/reviews',
             '--jq', '[.[] | {state: .state, user: .user.login}]'],
            capture_output=True, text=True, timeout=30)
        if r.returncode == 0 and r.stdout.strip():
            for chunk in r.stdout.strip().split('\n'):
                chunk = chunk.strip()
                if not chunk:
                    continue
                try:
                    for rev in json.loads(chunk):
                        if rev['user'] == pr_author:
                            continue
                        latest_state[rev['user']] = rev['state']
                except Exception:
                    pass
    except Exception:
        pass

    requested_set = set(requested)
    reviewers = []
    for user, state in latest_state.items():
        state = state.lower()
        if state == 'dismissed' and user in requested_set:
            state = 'pending'
        reviewers.append({'user': user, 'state': state})

    existing_users = {rv['user'] for rv in reviewers}
    for user in requested:
        if user not in existing_users:
            reviewers.append({'user': user, 'state': 'pending'})
            existing_users.add(user)

    return reviewers


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
