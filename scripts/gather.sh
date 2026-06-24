#!/usr/bin/env bash
# Activity Monitor — gather recent GitHub + Jira activity
# Outputs structured JSON sections for the AI to summarize.
#
# Usage:
#   gather.sh [DAYS]              # Lookback N days (default: 3)
#   gather.sh --since "ISO_DATE"  # Since a specific timestamp
#
# Required environment variables (set via ocmui-tokens.sh):
#   GITHUB_USER    - Your GitHub username (e.g., dtaylor113)
#   GITHUB_REPO    - The repo to monitor (e.g., RedHatInsights/uhc-portal)
#   JIRA_EMAIL     - Your Jira/Atlassian email
#   JIRA_TOKEN     - Jira API token
#   JIRA_INSTANCE  - Jira hostname (e.g., ${JIRA_INSTANCE})
#   JIRA_PROJECT   - Jira project key (e.g., OCMUI)
set -euo pipefail

# --- Validate required environment variables ---
MISSING=()
[[ -z "${GITHUB_USER:-}" ]] && MISSING+=("GITHUB_USER")
[[ -z "${GITHUB_REPO:-}" ]] && MISSING+=("GITHUB_REPO")
[[ -z "${JIRA_EMAIL:-}" ]] && MISSING+=("JIRA_EMAIL")
[[ -z "${JIRA_TOKEN:-}" ]] && MISSING+=("JIRA_TOKEN")
[[ -z "${JIRA_INSTANCE:-}" ]] && MISSING+=("JIRA_INSTANCE")
[[ -z "${JIRA_PROJECT:-}" ]] && MISSING+=("JIRA_PROJECT")

if [[ ${#MISSING[@]} -gt 0 ]]; then
  echo "ERROR: Missing required environment variables: ${MISSING[*]}" >&2
  echo "Set these in your ocmui-tokens.sh and source it. See README.md for setup." >&2
  exit 1
fi

# --- Validate Jira token is working ---
JIRA_AUTH_CHECK=$(curl -s -o /dev/null -w "%{http_code}" -u "$JIRA_EMAIL:$JIRA_TOKEN" "https://${JIRA_INSTANCE}/rest/api/3/myself")
if [[ "$JIRA_AUTH_CHECK" != "200" ]]; then
  echo "ERROR: Jira authentication failed (HTTP $JIRA_AUTH_CHECK)." >&2
  echo "Your JIRA_TOKEN may have expired. Generate a new one at:" >&2
  echo "  https://id.atlassian.com/manage-profile/security/api-tokens" >&2
  echo "Then update ~/ocmui-tokens.sh and re-source it." >&2
  exit 1
fi

REPO="$GITHUB_REPO"

# Parse arguments
if [[ "${1:-}" == "--since" && -n "${2:-}" ]]; then
  # Extract just the date portion from an ISO timestamp
  SINCE_DATE="${2:0:10}"
  # Calculate approximate days for Jira JQL (which needs -Nd format)
  SINCE_EPOCH=$(date -j -f "%Y-%m-%d" "$SINCE_DATE" +%s 2>/dev/null || date -d "$SINCE_DATE" +%s)
  NOW_EPOCH=$(date +%s)
  LOOKBACK_DAYS=$(( (NOW_EPOCH - SINCE_EPOCH) / 86400 + 1 ))
else
  LOOKBACK_DAYS="${1:-3}"
  SINCE_DATE=$(date -v-${LOOKBACK_DAYS}d +%Y-%m-%d 2>/dev/null || date -d "-${LOOKBACK_DAYS} days" +%Y-%m-%d)
fi

echo "=== ACTIVITY MONITOR (since $SINCE_DATE, ${LOOKBACK_DAYS}d lookback) ==="
echo ""


# --- Section 1: ALL active epics with current fields + last 3 comments ---
# Uses 'comment' field to get comments inline (1 API call instead of N+1)
echo "### SECTION: ALL_EPICS"
curl -s -u "$JIRA_EMAIL:$JIRA_TOKEN" \
  "https://${JIRA_INSTANCE}/rest/api/3/search/jql" \
  -G \
  --data-urlencode "jql=project = ${JIRA_PROJECT} AND issuetype = Epic AND status in (\"In Progress\", Review, Refinement, Backlog) ORDER BY \"Target end\" ASC, priority DESC" \
  --data-urlencode "maxResults=40" \
  --data-urlencode "fields=key,summary,status,assignee,priority,updated,customfield_10023,customfield_10542,parent,comment" \
  --data-urlencode "expand=names" | python3 -c "
import sys, json, re

data = json.load(sys.stdin)
names = data.get('names', {})
parent_link_fields = [fid for fid, label in names.items()
                      if 'parent link' in str(label).lower()]

BOT_AUTHORS = {'App SRE Jira bot', 'Jira Bot', 'Automation for Jira'}
results = []

for issue in data.get('issues', []):
    key = issue['key']
    fields = issue['fields']
    summary = fields.get('summary', '')
    status = fields.get('status', {}).get('name', '')
    assignee = (fields.get('assignee') or {}).get('displayName', 'Unassigned')
    target_end = fields.get('customfield_10023', '') or None

    # Marketing notes: can be plain string or ADF dict
    marketing_notes = ''
    mn_field = fields.get('customfield_10542')
    if mn_field:
        if isinstance(mn_field, str):
            marketing_notes = mn_field.strip()[:200]
        elif isinstance(mn_field, dict):
            for block in mn_field.get('content', []):
                for item in block.get('content', []):
                    if item.get('type') == 'text':
                        marketing_notes += item.get('text', '')
                marketing_notes += ' '
            marketing_notes = marketing_notes.strip()[:200]

    # Find parent key
    parent_key = None
    parent_summary = None
    if fields.get('parent', {}).get('key'):
        parent_key = fields['parent']['key']
        parent_summary = (fields.get('parent', {}).get('fields', {}).get('summary') or '')[:80]
    if not parent_key:
        for fid in parent_link_fields:
            val = fields.get(fid)
            if isinstance(val, str) and re.match(r'[A-Z]+-\d+', val):
                parent_key = val
                break
            elif isinstance(val, dict) and val.get('key'):
                parent_key = val['key']
                parent_summary = (val.get('fields', {}).get('summary') or '')[:80]
                break

    # Extract last 8 non-bot comments from inline comment field
    comments = []
    comment_data = fields.get('comment', {})
    all_comments = comment_data.get('comments', [])
    for c in reversed(all_comments):
        author_name = (c.get('author') or {}).get('displayName', 'Unknown')
        if author_name in BOT_AUTHORS:
            continue
        body_text = ''
        body = c.get('body')
        if body and isinstance(body, dict):
            for block in body.get('content', []):
                for item in block.get('content', []):
                    if item.get('type') == 'text':
                        body_text += item.get('text', '')
                body_text += ' '
        body_text = body_text.strip()[:200]
        comments.append({
            'author': author_name,
            'created': (c.get('created') or '')[:10],
            'body': body_text
        })
        if len(comments) >= 8:
            break

    results.append({
        'key': key,
        'summary': summary,
        'assignee': assignee,
        'status': status,
        'target_end': target_end,
        'marketing_notes': marketing_notes,
        'parent_key': parent_key,
        'parent_summary': parent_summary,
        'comments': comments
    })

print(json.dumps(results, indent=2))
"
echo ""

# --- Section 1b: Parent epic/feature date drift and status changes ---
# Fetches ALL active OCMUI epics (not just recently updated) to check parent alignment
echo "### SECTION: PARENT_EPIC_STATUS"
curl -s -u "$JIRA_EMAIL:$JIRA_TOKEN" \
  "https://${JIRA_INSTANCE}/rest/api/3/search/jql" \
  -G \
  --data-urlencode "jql=project = ${JIRA_PROJECT} AND issuetype = Epic AND status in (\"In Progress\", Review, Refinement, Backlog) ORDER BY \"Target end\" ASC" \
  --data-urlencode "maxResults=30" \
  --data-urlencode "fields=key,summary,status,assignee,customfield_10023,parent,customfield_10542" \
  --data-urlencode "expand=names" | python3 -c "
import sys, json, subprocess, os, re

data = json.load(sys.stdin)
jira_email = os.environ.get('JIRA_EMAIL', '')
jira_token = os.environ.get('JIRA_TOKEN', '')
since = '${SINCE_DATE}'
lookback_days = ${LOOKBACK_DAYS}

# Discover parent link fields from names
names = data.get('names', {})
parent_link_fields = [fid for fid, label in names.items()
                      if 'parent link' in str(label).lower()]

# Collect epics with their parent keys
epics_with_parents = []
for issue in data.get('issues', []):
    key = issue['key']
    fields = issue['fields']
    summary = fields.get('summary', '')[:80]
    target_end = fields.get('customfield_10023', '')
    assignee = (fields.get('assignee') or {}).get('displayName', 'Unassigned')
    status = fields.get('status', {}).get('name', '')

    # Find parent key
    parent_key = None
    if fields.get('parent', {}).get('key'):
        parent_key = fields['parent']['key']
    if not parent_key:
        for fid in parent_link_fields:
            val = fields.get(fid)
            if isinstance(val, str) and re.match(r'[A-Z]+-\d+', val):
                parent_key = val
                break
            elif isinstance(val, dict) and val.get('key'):
                parent_key = val['key']
                break

    if parent_key:
        epics_with_parents.append({
            'key': key,
            'summary': summary,
            'status': status,
            'assignee': assignee,
            'target_end': target_end or None,
            'parent_key': parent_key
        })

# Fetch parent tickets in batch (deduplicate parent keys)
parent_keys = list(set(e['parent_key'] for e in epics_with_parents))
parent_data = {}

if parent_keys:
    # Batch fetch parents (up to 30)
    keys_jql = ','.join(parent_keys[:30])
    import urllib.request, urllib.parse, base64
    auth = base64.b64encode(f'{jira_email}:{jira_token}'.encode()).decode()
    params = urllib.parse.urlencode({
        'jql': f'key in ({keys_jql})',
        'maxResults': 30,
        'fields': 'key,summary,status,customfield_10023,description,updated',
        'expand': 'changelog'
    })
    url = f'https://${JIRA_INSTANCE}/rest/api/3/search/jql?{params}'
    req = urllib.request.Request(url, headers={
        'Authorization': f'Basic {auth}',
        'Accept': 'application/json'
    })
    try:
        with urllib.request.urlopen(req) as resp:
            parent_response = json.loads(resp.read())
        for p in parent_response.get('issues', []):
            pkey = p['key']
            pfields = p['fields']
            # Extract target end from parent
            p_target_end = pfields.get('customfield_10023', '')
            # Extract description text (ADF -> plain text, first 500 chars)
            desc_text = ''
            desc = pfields.get('description')
            if desc and isinstance(desc, dict):
                for block in desc.get('content', []):
                    for item in block.get('content', []):
                        if item.get('type') == 'text':
                            desc_text += item.get('text', '')
                    desc_text += '\n'
            desc_text = desc_text.strip()[:500]

            # Check changelog for recent Target end changes
            p_changes = []
            for history in (p.get('changelog', {}).get('histories', []) or []):
                created = history.get('created', '')
                if created[:10] < since:
                    continue
                author = history.get('author', {}).get('displayName', 'Unknown')
                for item in history.get('items', []):
                    field = item.get('field', '')
                    if field in ('Target end', 'status', 'description', 'Description'):
                        p_changes.append({
                            'field': field,
                            'from': (item.get('fromString') or '')[:80],
                            'to': (item.get('toString') or '')[:80],
                            'who': author,
                            'when': created[:10]
                        })

            parent_data[pkey] = {
                'key': pkey,
                'summary': (pfields.get('summary') or '')[:80],
                'status': (pfields.get('status') or {}).get('name', ''),
                'target_end': p_target_end or None,
                'description_excerpt': desc_text,
                'updated': (pfields.get('updated') or '')[:10],
                'recent_changes': p_changes,
                'recent_comments': []
            }
    except Exception as e:
        pass

# Fetch last 8 comments for all parents
for pkey in list(parent_data.keys()):
    try:
        comment_url = f'https://${JIRA_INSTANCE}/rest/api/3/issue/{pkey}/comment?orderBy=-created&maxResults=8'
        req = urllib.request.Request(comment_url, headers={
            'Authorization': f'Basic {auth}',
            'Accept': 'application/json'
        })
        with urllib.request.urlopen(req) as resp:
            comment_response = json.loads(resp.read())
        BOT_AUTHORS = {'App SRE Jira bot', 'Jira Bot', 'Automation for Jira'}
        comments = []
        for c in comment_response.get('comments', []):
            author_name = (c.get('author') or {}).get('displayName', 'Unknown')
            if author_name in BOT_AUTHORS:
                continue
            body_text = ''
            body = c.get('body')
            if body and isinstance(body, dict):
                for block in body.get('content', []):
                    for item in block.get('content', []):
                        if item.get('type') == 'text':
                            body_text += item.get('text', '')
                    body_text += ' '
            body_text = body_text.strip()[:200]
            comments.append({
                'author': author_name,
                'created': (c.get('created') or '')[:10],
                'updated': (c.get('updated') or '')[:10],
                'body': body_text
            })
        parent_data[pkey]['recent_comments'] = comments
    except:
        pass

# Build results for all epics with parents
results = []
for epic in epics_with_parents:
    parent = parent_data.get(epic['parent_key'])
    if not parent:
        continue
    
    date_mismatch = False
    if epic['target_end'] and parent['target_end']:
        date_mismatch = (epic['target_end'] != parent['target_end'])

    results.append({
        'epic_key': epic['key'],
        'epic_summary': epic['summary'],
        'epic_target_end': epic['target_end'],
        'epic_assignee': epic['assignee'],
        'parent_key': epic['parent_key'],
        'parent_summary': parent['summary'],
        'parent_target_end': parent['target_end'],
        'parent_status': parent['status'],
        'parent_updated': parent['updated'],
        'parent_description_excerpt': parent['description_excerpt'],
        'date_mismatch': date_mismatch,
        'parent_recent_changes': parent.get('recent_changes', []),
        'parent_recent_comments': parent.get('recent_comments', [])
    })

print(json.dumps(results, indent=2))
"
echo ""

# --- Section 1c: Open child stories for each active epic ---
echo "### SECTION: EPIC_CHILDREN"
curl -s -u "$JIRA_EMAIL:$JIRA_TOKEN" \
  "https://${JIRA_INSTANCE}/rest/api/3/search/jql" \
  -G \
  --data-urlencode "jql=project = ${JIRA_PROJECT} AND issuetype = Epic AND status in (\"In Progress\", Review, Refinement, Backlog) ORDER BY \"Target end\" ASC" \
  --data-urlencode "maxResults=30" \
  --data-urlencode "fields=key" | python3 -c "
import sys, json, urllib.request, urllib.parse, base64, os

data = json.load(sys.stdin)
jira_email = os.environ.get('JIRA_EMAIL', '')
jira_token = os.environ.get('JIRA_TOKEN', '')
auth = base64.b64encode(f'{jira_email}:{jira_token}'.encode()).decode()

epic_keys = [issue['key'] for issue in data.get('issues', [])]
results = {}

BOT_AUTHORS = {'App SRE Jira bot', 'Jira Bot', 'Automation for Jira'}

for epic_key in epic_keys:
    # Fetch children (open only) with comments inline — 1 call per epic
    epic_link_jql = f'(parent = {epic_key} OR \"Epic Link\" = {epic_key}) AND status not in (Closed, Done) ORDER BY status ASC, updated DESC'
    params = urllib.parse.urlencode({
        'jql': epic_link_jql,
        'maxResults': 15,
        'fields': 'key,summary,status,assignee,issuetype,updated,comment'
    })
    url = f'https://${JIRA_INSTANCE}/rest/api/3/search/jql?{params}'
    req = urllib.request.Request(url, headers={
        'Authorization': f'Basic {auth}',
        'Accept': 'application/json'
    })
    try:
        with urllib.request.urlopen(req) as resp:
            child_data = json.loads(resp.read())
    except:
        continue

    children = []
    for child in child_data.get('issues', []):
        cf = child['fields']
        child_key = child['key']

        # Extract latest non-bot comment from inline comment field
        latest_comment = None
        all_comments = (cf.get('comment') or {}).get('comments', [])
        for c in reversed(all_comments):
            author_name = (c.get('author') or {}).get('displayName', 'Unknown')
            if author_name in BOT_AUTHORS:
                continue
            body_text = ''
            body = c.get('body')
            if body and isinstance(body, dict):
                for block in body.get('content', []):
                    for item in block.get('content', []):
                        if item.get('type') == 'text':
                            body_text += item.get('text', '')
                    body_text += ' '
            body_text = body_text.strip()[:150]
            latest_comment = {
                'author': author_name,
                'created': (c.get('created') or '')[:10],
                'body': body_text
            }
            break

        children.append({
            'key': child_key,
            'summary': (cf.get('summary') or '')[:100],
            'status': (cf.get('status') or {}).get('name', ''),
            'assignee': ((cf.get('assignee') or {}).get('displayName', 'Unassigned')),
            'type': (cf.get('issuetype') or {}).get('name', ''),
            'updated': (cf.get('updated') or '')[:10],
            'latest_comment': latest_comment
        })

    if children:
        results[epic_key] = {
            'total_open': len(children),
            'children': children
        }

print(json.dumps(results, indent=2))
"
echo ""

# Pre-fetch the current user's team slugs (cached for all PR sections)
# Uses GITHUB_TOKEN="" to prefer keyring token which has read:org scope
MY_TEAMS=$(GITHUB_TOKEN="" gh api --paginate "user/teams" --jq '[.[].slug]' 2>/dev/null | python3 -c "
import sys, json
teams = set()
for line in sys.stdin:
    line = line.strip()
    if line:
        try: teams.update(json.loads(line))
        except: pass
print(json.dumps(sorted(teams)))
" 2>/dev/null)
[[ -z "$MY_TEAMS" ]] && MY_TEAMS="[]"

# Fetch senior staff team members (for PR triage logic)
SENIOR_STAFF=$(GITHUB_TOKEN="" gh api "orgs/RedHatInsights/teams/uhc-portal-senior-staff/members" --jq '[.[].login]' 2>/dev/null)
[[ -z "$SENIOR_STAFF" ]] && SENIOR_STAFF="[]"
export SENIOR_STAFF

# --- Section 1d: PR lookup for child tickets in Code Review/Review ---
echo "### SECTION: CHILD_PR_STATUS"
# Collect child ticket keys in Code Review or Review from the EPIC_CHILDREN output,
# then look up their corresponding GitHub PRs
curl -s -u "$JIRA_EMAIL:$JIRA_TOKEN" \
  "https://${JIRA_INSTANCE}/rest/api/3/search/jql" \
  -G \
  --data-urlencode "jql=project = ${JIRA_PROJECT} AND issuetype != Epic AND status in (\"Code Review\", Review) AND issueFunction in linkedIssuesOf(\"project = ${JIRA_PROJECT} AND issuetype = Epic AND status in ('In Progress', Review, Refinement, Backlog)\", \"is child of\") ORDER BY updated DESC" \
  --data-urlencode "maxResults=30" \
  --data-urlencode "fields=key,summary,status" 2>/dev/null | python3 -c "
import sys, json, subprocess, os

REPO = '${REPO}'
github_user = os.environ['GITHUB_USER']
my_teams = json.loads('${MY_TEAMS}') if '${MY_TEAMS}' != '' else []

# Try to get child keys from Jira; if the linkedIssuesOf JQL fails, fall back to simpler query
try:
    data = json.load(sys.stdin)
    child_keys = [issue['key'] for issue in data.get('issues', [])]
except:
    child_keys = []

# If the JQL approach didn't work, use a simpler query
if not child_keys:
    # Fallback: search for OCMUI stories/tasks in Code Review or Review
    import urllib.request, urllib.parse, base64
    jira_email = os.environ.get('JIRA_EMAIL', '')
    jira_token = os.environ.get('JIRA_TOKEN', '')
    auth = base64.b64encode(f'{jira_email}:{jira_token}'.encode()).decode()
    params = urllib.parse.urlencode({
        'jql': 'project = ${JIRA_PROJECT} AND issuetype != Epic AND status in (\"Code Review\", Review) ORDER BY updated DESC',
        'maxResults': 30,
        'fields': 'key,summary,status'
    })
    url = f'https://${JIRA_INSTANCE}/rest/api/3/search/jql?{params}'
    req = urllib.request.Request(url, headers={
        'Authorization': f'Basic {auth}',
        'Accept': 'application/json'
    })
    try:
        with urllib.request.urlopen(req) as resp:
            fallback_data = json.loads(resp.read())
        child_keys = [issue['key'] for issue in fallback_data.get('issues', [])]
    except:
        pass

results = {}

for key in child_keys:
    # Search GitHub for a PR matching this Jira key (title first, then body/description)
    try:
        pr_info = None
        for search_scope in ['in:title', 'in:body']:
            search_result = subprocess.run(
                ['gh', 'api', '--method', 'GET', 'search/issues',
                 '-f', f'q=repo:{REPO} is:pr is:open {key} {search_scope}',
                 '-F', 'per_page=1',
                 '--jq', '.items[0] | {number, title, state, html_url, user: .user.login, updated_at}'],
                capture_output=True, text=True, timeout=15
            )
            if search_result.returncode == 0 and search_result.stdout.strip():
                candidate = json.loads(search_result.stdout)
                if candidate and candidate.get('number'):
                    pr_info = candidate
                    break
        if not pr_info:
            continue
        pr_num = pr_info['number']

        # Get PR author + requested reviewers + requested teams + mergeable state
        pr_author = ''
        mergeable_state = 'unknown'
        requested = []
        requested_teams = []
        try:
            req_result = subprocess.run(
                ['gh', 'api', f'repos/{REPO}/pulls/{pr_num}',
                 '--jq', '{author: .user.login, requested: [.requested_reviewers[].login], requested_teams: [.requested_teams[].slug], mergeable_state: .mergeable_state}'],
                capture_output=True, text=True, timeout=15
            )
            if req_result.returncode == 0 and req_result.stdout.strip():
                pr_extra = json.loads(req_result.stdout)
                pr_author = pr_extra.get('author', '')
                requested = pr_extra.get('requested', [])
                requested_teams = pr_extra.get('requested_teams', [])
                mergeable_state = pr_extra.get('mergeable_state', 'unknown')
        except: pass

        # Get reviews — paginate to get ALL, last meaningful state per user wins
        reviews_result = subprocess.run(
            ['gh', 'api', '--paginate', f'repos/{REPO}/pulls/{pr_num}/reviews',
             '--jq', '[.[] | {state: .state, user: .user.login}]'],
            capture_output=True, text=True, timeout=30
        )
        approvals = 0
        changes_requested = 0
        reviewers = []
        if reviews_result.returncode == 0 and reviews_result.stdout.strip():
            raw = reviews_result.stdout.strip()
            reviews = []
            for chunk in raw.split('\n'):
                chunk = chunk.strip()
                if chunk:
                    try: reviews.extend(json.loads(chunk))
                    except: pass
            reviewer_state = {}
            for r in reviews:
                user = r['user']
                if user == pr_author:
                    continue
                state = r['state']
                if state in ('APPROVED', 'CHANGES_REQUESTED'):
                    reviewer_state[user] = state
                elif state == 'COMMENTED':
                    if user not in reviewer_state or reviewer_state[user] == 'COMMENTED':
                        reviewer_state[user] = 'COMMENTED'
                elif state == 'DISMISSED':
                    reviewer_state[user] = 'COMMENTED'
            for user, state in reviewer_state.items():
                if state == 'APPROVED':
                    approvals += 1
                elif state == 'CHANGES_REQUESTED':
                    changes_requested += 1
                reviewers.append({'user': user, 'state': state.lower()})
        # Add requested reviewers not yet in the list
        existing = {rv['user'] for rv in reviewers}
        for u in requested:
            if u not in existing:
                reviewers.append({'user': u, 'state': 'pending'})
                existing.add(u)
        # Add current user as pending if in a requested team but not already listed
        if github_user != pr_author and github_user not in existing:
            matched_teams = [t for t in requested_teams if t in my_teams]
            if matched_teams:
                reviewers.append({'user': github_user, 'state': 'pending', 'via_team': matched_teams[0]})

        # Get last 8 unresolved non-bot comments (issue + review via GraphQL)
        comments = []
        BOT_USERS = {'codecov[bot]', 'coderabbitai[bot]', 'github-actions[bot]', 'dependabot[bot]'}

        # Issue comments
        comments_result = subprocess.run(
            ['gh', 'api', f'repos/{REPO}/issues/{pr_num}/comments',
             '--jq', '[.[] | {user: .user.login, body: .body[:150], created_at: .created_at[:10]}]'],
            capture_output=True, text=True, timeout=15
        )
        if comments_result.returncode == 0 and comments_result.stdout.strip():
            comments.extend(json.loads(comments_result.stdout))

        # Unresolved review thread comments via GraphQL
        owner, repo_name = REPO.split('/')
        gql_query = 'query { repository(owner: "%s", name: "%s") { pullRequest(number: %d) { reviewThreads(first: 50) { nodes { isResolved comments(last: 1) { nodes { author { login } body createdAt } } } } } } }' % (owner, repo_name, pr_num)
        gql_result = subprocess.run(
            ['gh', 'api', 'graphql', '-f', f'query={gql_query}'],
            capture_output=True, text=True, timeout=15
        )
        if gql_result.returncode == 0 and gql_result.stdout.strip():
            gql = json.loads(gql_result.stdout)
            threads = gql.get('data',{}).get('repository',{}).get('pullRequest',{}).get('reviewThreads',{}).get('nodes',[])
            for thread in threads:
                if thread.get('isResolved'):
                    continue
                nodes = thread.get('comments',{}).get('nodes',[])
                if nodes:
                    c = nodes[0]
                    comments.append({
                        'user': (c.get('author') or {}).get('login',''),
                        'body': c.get('body','')[:150],
                        'created_at': (c.get('createdAt') or '')[:10]
                    })

        # Filter bots, sort by date, take last 8
        comments = [c for c in comments if c.get('user') not in BOT_USERS]
        comments.sort(key=lambda c: c.get('created_at', ''), reverse=True)
        comments = comments[:8]

        # Upgrade "pending" reviewers to "commented" if they left issue comments
        commenters = {c['user'] for c in comments if c.get('user')}
        for rv in reviewers:
            if rv['state'] == 'pending' and rv['user'] in commenters:
                rv['state'] = 'commented'

        # Get CI check status
        checks_status = 'unknown'
        try:
            checks_result = subprocess.run(
                ['gh', 'api', f'repos/{REPO}/commits/{pr_num}/check-runs',
                 '--jq', '{total: .total_count, success: ([.check_runs[] | select(.conclusion == \"success\")] | length), fail: ([.check_runs[] | select(.conclusion == \"failure\")] | length), pending: ([.check_runs[] | select(.status == \"in_progress\" or .status == \"queued\")] | length)}'],
                capture_output=True, text=True, timeout=15
            )
            if checks_result.returncode != 0 or not checks_result.stdout.strip():
                # Try using PR head SHA via combined status
                checks_result = subprocess.run(
                    ['gh', 'pr', 'checks', str(pr_num), '--repo', REPO, '--json', 'name,state',
                     '--jq', '{total: length, success: ([.[] | select(.state == \"SUCCESS\")] | length), fail: ([.[] | select(.state == \"FAILURE\")] | length), pending: ([.[] | select(.state == \"PENDING\")] | length)}'],
                    capture_output=True, text=True, timeout=15
                )
            if checks_result.returncode == 0 and checks_result.stdout.strip():
                ck = json.loads(checks_result.stdout)
                if ck.get('fail', 0) > 0:
                    checks_status = 'failing'
                elif ck.get('pending', 0) > 0:
                    checks_status = 'pending'
                elif ck.get('success', 0) > 0:
                    checks_status = 'passing'
        except:
            pass

        results[key] = {
            'pr_number': pr_num,
            'pr_title': pr_info.get('title', ''),
            'pr_state': pr_info.get('state', ''),
            'pr_author': pr_info.get('user', ''),
            'pr_updated': pr_info.get('updated_at', '')[:10],
            'approvals': approvals,
            'changes_requested': changes_requested,
            'reviewers': reviewers,
            'checks': checks_status,
            'mergeable_state': mergeable_state,
            'comments': comments
        }
    except Exception:
        continue

print(json.dumps(results, indent=2))
"
echo ""

# --- Section 1e: Siblings — open children of each epic's parent (non-OCMUI) ---
echo "### SECTION: SIBLINGS"
curl -s -u "$JIRA_EMAIL:$JIRA_TOKEN" \
  "https://${JIRA_INSTANCE}/rest/api/3/search/jql" \
  -G \
  --data-urlencode "jql=project = ${JIRA_PROJECT} AND issuetype = Epic AND status in (\"In Progress\", Review, Refinement, Backlog) ORDER BY \"Target end\" ASC" \
  --data-urlencode "maxResults=40" \
  --data-urlencode "fields=key,parent" \
  --data-urlencode "expand=names" | python3 -c "
import sys, json, urllib.request, urllib.parse, base64, os, re

data = json.load(sys.stdin)
jira_email = os.environ.get('JIRA_EMAIL', '')
jira_token = os.environ.get('JIRA_TOKEN', '')
auth = base64.b64encode(f'{jira_email}:{jira_token}'.encode()).decode()

names = data.get('names', {})
parent_link_fields = [fid for fid, label in names.items()
                      if 'parent link' in str(label).lower()]

# Collect epic -> parent_key mapping
epic_parents = {}
for issue in data.get('issues', []):
    key = issue['key']
    fields = issue.get('fields')
    if not fields:
        continue
    parent_key = None
    if fields.get('parent', {}).get('key'):
        parent_key = fields['parent']['key']
    if not parent_key:
        for fid in parent_link_fields:
            val = fields.get(fid)
            if isinstance(val, str) and re.match(r'[A-Z]+-\d+', val):
                parent_key = val
                break
            elif isinstance(val, dict) and val.get('key'):
                parent_key = val['key']
                break
    if parent_key and not parent_key.startswith('OCMUI-'):
        epic_parents[key] = parent_key

# For each unique parent, fetch its open children (excluding OCMUI epics)
parent_keys = list(set(epic_parents.values()))
parent_children = {}

for pkey in parent_keys:
    try:
        epic_link_jql = f'\"Epic Link\" = {pkey}'
        exclude_keys = chr(44).join(k for k,v in epic_parents.items() if v == pkey)
        jql = f'(parent = {pkey} OR {epic_link_jql}) AND status not in (Closed, Done) AND key not in ({exclude_keys}) ORDER BY status ASC, updated DESC'
        params = urllib.parse.urlencode({
            'jql': jql,
            'maxResults': 15,
            'fields': 'key,summary,status,assignee,issuetype,updated,comment'
        })
        url = f'https://${JIRA_INSTANCE}/rest/api/3/search/jql?{params}'
        req = urllib.request.Request(url, headers={
            'Authorization': f'Basic {auth}',
            'Accept': 'application/json'
        })
        with urllib.request.urlopen(req) as resp:
            resp_data = json.loads(resp.read())

        children = []
        BOT_AUTHORS = {'App SRE Jira bot', 'Jira Bot', 'Automation for Jira'}
        for issue in resp_data.get('issues', []):
            ikey = issue['key']
            ifields = issue['fields']
            # Get latest non-bot comment
            latest_comment = None
            comments_data = ifields.get('comment', {}).get('comments', [])
            for c in reversed(comments_data):
                author_name = (c.get('author') or {}).get('displayName', 'Unknown')
                if author_name in BOT_AUTHORS:
                    continue
                body_text = ''
                body = c.get('body')
                if body and isinstance(body, dict):
                    for block in body.get('content', []):
                        for item in block.get('content', []):
                            if item.get('type') == 'text':
                                body_text += item.get('text', '')
                        body_text += ' '
                body_text = body_text.strip()[:150]
                latest_comment = {'author': author_name, 'created': (c.get('created') or '')[:10], 'body': body_text}
                break

            children.append({
                'key': ikey,
                'summary': (ifields.get('summary') or '')[:100],
                'status': (ifields.get('status') or {}).get('name', ''),
                'assignee': ((ifields.get('assignee') or {}).get('displayName', 'Unassigned')),
                'type': (ifields.get('issuetype') or {}).get('name', ''),
                'updated': (ifields.get('updated') or '')[:10],
                'latest_comment': latest_comment
            })
        parent_children[pkey] = children
    except:
        pass

# Map back to epics
results = {}
for epic_key, parent_key in epic_parents.items():
    siblings = parent_children.get(parent_key, [])
    if siblings:
        results[epic_key] = siblings

print(json.dumps(results, indent=2))
"
echo ""

# --- Section 2: PRs involving me (recent activity) ---
echo "### SECTION: PR_ACTIVITY"
gh api --method GET search/issues \
  -f "q=repo:${REPO} is:pr involves:${GITHUB_USER} updated:>${SINCE_DATE}" \
  -F per_page=20 \
  --jq '[.items[] | {number, title: .title, state, updated_at, author: .user.login}]' 2>/dev/null || echo "[]"
echo ""

# --- Section 3: Review requests for me ---
echo "### SECTION: REVIEW_REQUESTS"
REVIEW_REQUESTS_JSON=$(gh api --method GET search/issues \
  -f "q=repo:${REPO} is:pr is:open review-requested:${GITHUB_USER}" \
  -F per_page=10 \
  --jq '[.items[] | {number, title: .title, author: .user.login, updated_at}]' 2>/dev/null || echo "[]")
echo "$REVIEW_REQUESTS_JSON"
REVIEW_REQUEST_NUMS=$(echo "$REVIEW_REQUESTS_JSON" | python3 -c "import sys,json; print(' '.join(str(p['number']) for p in json.load(sys.stdin)))" 2>/dev/null)
echo ""

# --- Section 3b: PRs where my review is stale (reviewed but new commits pushed) ---
echo "### SECTION: STALE_REVIEWS"
STALE_REVIEWS_JSON=$(gh api --method GET search/issues \
  -f "q=repo:${REPO} is:pr is:open reviewed-by:${GITHUB_USER} -review:approved -author:${GITHUB_USER}" \
  -F per_page=10 \
  --jq '[.items[] | {number, title: .title, author: .user.login, updated_at}]' 2>/dev/null || echo "[]")
echo "$STALE_REVIEWS_JSON"
STALE_REVIEW_NUMS=$(echo "$STALE_REVIEWS_JSON" | python3 -c "import sys,json; print(' '.join(str(p['number']) for p in json.load(sys.stdin)))" 2>/dev/null)
MY_PR_NUMS=$(gh pr list --repo "$REPO" --author "$GITHUB_USER" --state open --json number --jq '.[].number' 2>/dev/null)
echo ""

# --- Section 3c: My open PRs (always include regardless of activity) ---
echo "### SECTION: MY_OPEN_PRS"
gh pr list --repo "$REPO" --author "$GITHUB_USER" --state open --json number,title,updatedAt,isDraft \
  --jq '[.[] | {number, title, updated_at: .updatedAt, is_draft: .isDraft}]' 2>/dev/null || echo "[]"
echo ""

# --- Section 4: Last 3 human comments for all PRs needing attention ---
# Reuses PR numbers collected from earlier sections (avoid duplicate API calls)
echo "### SECTION: PR_COMMENTS"
ALL_PR_NUMS=$(echo "$REVIEW_REQUEST_NUMS $STALE_REVIEW_NUMS $MY_PR_NUMS" | tr ' ' '\n' | sort -un | tr '\n' ' ')

BOTS="codecov|coderabbitai|github-actions|dependabot"
echo "["
FIRST=true
for PR_NUM in $ALL_PR_NUMS; do
  [[ -z "$PR_NUM" ]] && continue
  COMMENTS=$(python3 -c "
import subprocess, json
pr_num = ${PR_NUM}
repo = '${REPO}'
owner, name = repo.split('/')
bots = {'codecov[bot]', 'coderabbitai[bot]', 'github-actions[bot]', 'dependabot[bot]', 'codecov', 'coderabbitai'}
all_comments = []

# Issue comments (general PR conversation — these are never 'resolved')
r = subprocess.run(['gh', 'api', f'repos/{repo}/issues/{pr_num}/comments',
    '--jq', '[.[] | {user: .user.login, body: .body[:150], updated_at: .created_at}]'],
    capture_output=True, text=True, timeout=15)
if r.returncode == 0 and r.stdout.strip():
    all_comments.extend(json.loads(r.stdout))

# Review comments — use GraphQL to get only UNRESOLVED thread comments
query = '''query {
  repository(owner: \"%s\", name: \"%s\") {
    pullRequest(number: %d) {
      reviewThreads(first: 50) {
        nodes {
          isResolved
          comments(last: 1) {
            nodes { author { login } body createdAt }
          }
        }
      }
    }
  }
}''' % (owner, name, pr_num)
r = subprocess.run(['gh', 'api', 'graphql', '-f', f'query={query}'],
    capture_output=True, text=True, timeout=15)
if r.returncode == 0 and r.stdout.strip():
    gql = json.loads(r.stdout)
    threads = gql.get('data',{}).get('repository',{}).get('pullRequest',{}).get('reviewThreads',{}).get('nodes',[])
    for thread in threads:
        if thread.get('isResolved'):
            continue
        comments = thread.get('comments',{}).get('nodes',[])
        if comments:
            c = comments[0]
            author = c.get('author',{}).get('login','')
            all_comments.append({
                'user': author,
                'body': c.get('body','')[:150],
                'updated_at': c.get('createdAt','')[:10]
            })

# Filter bots, sort by date, take last 8
all_comments = [c for c in all_comments if c.get('user') not in bots]
all_comments.sort(key=lambda c: c.get('updated_at', ''))
all_comments = all_comments[-8:]

# Add pr number
for c in all_comments:
    c['pr'] = pr_num

if all_comments:
    print(','.join(json.dumps(c) for c in all_comments))
" 2>/dev/null)
  if [[ -n "$COMMENTS" ]]; then
    if [[ "$FIRST" == "true" ]]; then FIRST=false; else echo ","; fi
    echo "$COMMENTS"
  fi
done
echo "]"
echo ""

# --- Section 4b: PR reviews and checks status for all PRs ---
echo "### SECTION: PR_STATUS"
echo "{"

FIRST=true
for PR_NUM in $ALL_PR_NUMS; do
  [[ -z "$PR_NUM" ]] && continue
  STATUS=$(python3 -c "
import subprocess, json, os
pr_num = ${PR_NUM}
repo = '${REPO}'
github_user = os.environ['GITHUB_USER']
my_teams = json.loads('${MY_TEAMS}')

# Get PR author + requested reviewers + requested teams + mergeable state
pr_author = ''
mergeable_state = 'unknown'
requested = []
requested_teams = []
try:
    r = subprocess.run(['gh', 'api', f'repos/{repo}/pulls/{pr_num}', '--jq', '{author: .user.login, requested: [.requested_reviewers[].login], requested_teams: [.requested_teams[].slug], mergeable_state: .mergeable_state, draft: .draft}'], capture_output=True, text=True, timeout=15)
    if r.returncode == 0 and r.stdout.strip():
        pr_data = json.loads(r.stdout)
        pr_author = pr_data.get('author', '')
        requested = pr_data.get('requested', [])
        requested_teams = pr_data.get('requested_teams', [])
        mergeable_state = pr_data.get('mergeable_state', 'unknown')
except: pass

# Reviews — paginate to get ALL reviews, last meaningful state per user wins
reviewers = []
try:
    r = subprocess.run(['gh', 'api', '--paginate', f'repos/{repo}/pulls/{pr_num}/reviews', '--jq', '[.[] | {state: .state, user: .user.login}]'], capture_output=True, text=True, timeout=30)
    if r.returncode == 0 and r.stdout.strip():
        raw = r.stdout.strip()
        reviews = []
        for chunk in raw.split('\n'):
            chunk = chunk.strip()
            if chunk:
                try: reviews.extend(json.loads(chunk))
                except: pass
        reviewer_state = {}
        for rev in reviews:
            user = rev['user']
            if user == pr_author:
                continue
            state = rev['state']
            if state in ('APPROVED', 'CHANGES_REQUESTED'):
                reviewer_state[user] = state
            elif state == 'COMMENTED':
                if user not in reviewer_state or reviewer_state[user] == 'COMMENTED':
                    reviewer_state[user] = 'COMMENTED'
            elif state == 'DISMISSED':
                reviewer_state[user] = 'COMMENTED'
        for user, state in reviewer_state.items():
            reviewers.append({'user': user, 'state': state.lower()})
except: pass

# Add requested reviewers not yet in the list
existing_users = {rv['user'] for rv in reviewers}
for user in requested:
    if user not in existing_users:
        reviewers.append({'user': user, 'state': 'pending'})
        existing_users.add(user)

# Add current user as pending if they are in a requested team but not already listed
if github_user != pr_author and github_user not in existing_users:
    matched_teams = [t for t in requested_teams if t in my_teams]
    if matched_teams:
        reviewers.append({'user': github_user, 'state': 'pending', 'via_team': matched_teams[0]})

# Upgrade "pending" reviewers to "commented" if they left issue comments
try:
    r = subprocess.run(['gh', 'api', f'repos/{repo}/issues/{pr_num}/comments',
        '--jq', '[.[].user.login]'], capture_output=True, text=True, timeout=15)
    if r.returncode == 0 and r.stdout.strip():
        issue_commenters = set(json.loads(r.stdout))
        for rv in reviewers:
            if rv['state'] == 'pending' and rv['user'] in issue_commenters:
                rv['state'] = 'commented'
except: pass

# Checks
checks_status = 'unknown'
try:
    r = subprocess.run(['gh', 'pr', 'checks', str(pr_num), '--repo', repo, '--json', 'name,state', '--jq', '{total: length, success: ([.[] | select(.state == \"SUCCESS\")] | length), fail: ([.[] | select(.state == \"FAILURE\")] | length), pending: ([.[] | select(.state == \"PENDING\")] | length)}'], capture_output=True, text=True, timeout=15)
    if r.returncode == 0 and r.stdout.strip():
        ck = json.loads(r.stdout)
        if ck.get('fail', 0) > 0: checks_status = 'failing'
        elif ck.get('pending', 0) > 0: checks_status = 'pending'
        elif ck.get('success', 0) > 0: checks_status = 'passing'
except: pass

print(json.dumps({'reviewers': reviewers, 'checks': checks_status, 'mergeable_state': mergeable_state}))
" 2>/dev/null)
  if [[ -n "$STATUS" ]]; then
    if [[ "$FIRST" == "true" ]]; then FIRST=false; else echo ","; fi
    echo "\"${PR_NUM}\": ${STATUS}"
  fi
done
echo "}"
echo ""

# --- Section 5: Jira tickets I'm involved in (recent changes) ---
echo "### SECTION: JIRA_TICKET_ACTIVITY"
curl -s -u "$JIRA_EMAIL:$JIRA_TOKEN" \
  "https://${JIRA_INSTANCE}/rest/api/3/search/jql" \
  -G \
  --data-urlencode "jql=project = ${JIRA_PROJECT} AND (assignee = currentUser() OR watcher = currentUser() OR reporter = currentUser()) AND issuetype != Epic AND updated >= -${LOOKBACK_DAYS}d ORDER BY updated DESC" \
  --data-urlencode "maxResults=20" \
  --data-urlencode "fields=key,summary,status,assignee,updated,issuetype" \
  --data-urlencode "expand=changelog" | python3 -c "
import sys, json

data = json.load(sys.stdin)
since = '${SINCE_DATE}T00:00:00.000+0000'
results = []

for issue in data.get('issues', []):
    key = issue['key']
    fields = issue['fields']
    summary = fields.get('summary', '')[:80]
    status = fields.get('status', {}).get('name', '')
    issue_type = fields.get('issuetype', {}).get('name', '')

    changes = []
    for history in (issue.get('changelog', {}).get('histories', []) or []):
        created = history.get('created', '')
        if created < since:
            continue
        author = history.get('author', {}).get('displayName', 'Unknown')
        for item in history.get('items', []):
            field = item.get('field', '')
            if field in ('status', 'priority', 'assignee', 'Sprint', 'Flagged', 'resolution'):
                changes.append({
                    'field': field,
                    'from': item.get('fromString', ''),
                    'to': item.get('toString', ''),
                    'who': author,
                    'when': created[:10]
                })

    if changes:
        results.append({
            'key': key,
            'summary': summary,
            'status': status,
            'type': issue_type,
            'changes': changes
        })

print(json.dumps(results, indent=2))
"
echo ""
echo "=== END ==="
