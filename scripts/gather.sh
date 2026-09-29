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
JIRA_OK=true
if [[ "$JIRA_AUTH_CHECK" != "200" ]]; then
  echo "WARNING: Jira authentication failed (HTTP $JIRA_AUTH_CHECK). Jira sections will be empty." >&2
  echo "Your JIRA_TOKEN may have expired. Generate a new one at:" >&2
  echo "  https://id.atlassian.com/manage-profile/security/api-tokens" >&2
  echo "Then update ~/ocmui-tokens.sh and re-source it." >&2
  JIRA_OK=false
fi

jira_skip() {
  # Output an empty section placeholder when Jira is unavailable
  echo "[]"
  echo ""
}

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

# =====================================================
# JIRA / EPIC SECTIONS (populates Jira tab)
# =====================================================
# NOTE: The GitHub tab's main PR tables (My PRs / Reviewing / Approved) are
# fetched live client-side via GraphQL from ACTIVITY_MONITOR.html and no
# longer sourced from this script. CHILD_PR_STATUS below is unrelated —
# it looks up PRs by Jira ticket key for the Jira tab's epic-children view
# and is independently fetched, so it stays.

# --- Section 1: ALL active epics with current fields + last 3 comments ---
# Uses 'comment' field to get comments inline (1 API call instead of N+1)
echo "### SECTION: ALL_EPICS"
if ! $JIRA_OK; then jira_skip; else
curl -s -u "$JIRA_EMAIL:$JIRA_TOKEN" \
  "https://${JIRA_INSTANCE}/rest/api/3/search/jql" \
  -G \
  --data-urlencode "jql=project = ${JIRA_PROJECT} AND issuetype = Epic AND status in (\"In Progress\", Review, Refinement, Backlog) ORDER BY \"Target end\" ASC, priority DESC" \
  --data-urlencode "maxResults=40" \
  --data-urlencode "fields=key,summary,status,assignee,priority,updated,customfield_10023,customfield_10542,parent,comment" \
  --data-urlencode "expand=names" | python3 -c "
import sys, json, re
sys.path.insert(0, '$(dirname "$0")')
from lib.shared import JIRA_BOT_AUTHORS, adf_to_text

data = json.load(sys.stdin)
names = data.get('names', {})
parent_link_fields = [fid for fid, label in names.items()
                      if 'parent link' in str(label).lower()]

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
            marketing_notes = adf_to_text(mn_field, 200)

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
        if author_name in JIRA_BOT_AUTHORS:
            continue
        body_text = adf_to_text(c.get('body'), 200)
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
fi # end ALL_EPICS jira guard

# --- Section 1b: Parent target-end backfill + parent recent comments ---
# Epics without their own Target End fall back to the parent's. Also
# surfaces the parent's recent comments for the epic detail panel. The
# epic's own summary/status/assignee/target_end already come from
# ALL_EPICS above — this section only needs the epic->parent mapping.
echo "### SECTION: PARENT_EPIC_STATUS"
if ! $JIRA_OK; then jira_skip; else
curl -s -u "$JIRA_EMAIL:$JIRA_TOKEN" \
  "https://${JIRA_INSTANCE}/rest/api/3/search/jql" \
  -G \
  --data-urlencode "jql=project = ${JIRA_PROJECT} AND issuetype = Epic AND status in (\"In Progress\", Review, Refinement, Backlog) ORDER BY \"Target end\" ASC" \
  --data-urlencode "maxResults=30" \
  --data-urlencode "fields=key,parent" \
  --data-urlencode "expand=names" | python3 -c "
import sys, json, os, re
sys.path.insert(0, '$(dirname "$0")')
from lib.shared import JIRA_BOT_AUTHORS, adf_to_text

data = json.load(sys.stdin)
jira_email = os.environ.get('JIRA_EMAIL', '')
jira_token = os.environ.get('JIRA_TOKEN', '')

# Discover parent link fields from names
names = data.get('names', {})
parent_link_fields = [fid for fid, label in names.items()
                      if 'parent link' in str(label).lower()]

# Collect epic -> parent_key mapping
epic_parents = {}
for issue in data.get('issues', []):
    key = issue['key']
    fields = issue['fields']

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
        epic_parents[key] = parent_key

# Fetch parent tickets in batch (deduplicate parent keys) for target_end
parent_keys = list(set(epic_parents.values()))
parent_data = {}

if parent_keys:
    keys_jql = ','.join(parent_keys[:30])
    import urllib.request, urllib.parse, base64
    auth = base64.b64encode(f'{jira_email}:{jira_token}'.encode()).decode()
    params = urllib.parse.urlencode({
        'jql': f'key in ({keys_jql})',
        'maxResults': 30,
        'fields': 'key,customfield_10023'
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
            parent_data[pkey] = {
                'target_end': p['fields'].get('customfield_10023') or None,
                'recent_comments': []
            }
    except Exception:
        pass

# Fetch last 8 non-bot comments for all parents
for pkey in list(parent_data.keys()):
    try:
        comment_url = f'https://${JIRA_INSTANCE}/rest/api/3/issue/{pkey}/comment?orderBy=-created&maxResults=8'
        req = urllib.request.Request(comment_url, headers={
            'Authorization': f'Basic {auth}',
            'Accept': 'application/json'
        })
        with urllib.request.urlopen(req) as resp:
            comment_response = json.loads(resp.read())
        comments = []
        for c in comment_response.get('comments', []):
            author_name = (c.get('author') or {}).get('displayName', 'Unknown')
            if author_name in JIRA_BOT_AUTHORS:
                continue
            body_text = adf_to_text(c.get('body'), 200)
            comments.append({
                'author': author_name,
                'created': (c.get('created') or '')[:10],
                'body': body_text
            })
        parent_data[pkey]['recent_comments'] = comments
    except Exception:
        pass

# Build results: epic -> parent target_end + comments
results = []
for epic_key, parent_key in epic_parents.items():
    parent = parent_data.get(parent_key)
    if not parent:
        continue
    results.append({
        'epic_key': epic_key,
        'parent_key': parent_key,
        'parent_target_end': parent['target_end'],
        'parent_recent_comments': parent.get('recent_comments', [])
    })

print(json.dumps(results, indent=2))
"
echo ""
fi # end PARENT_EPIC_STATUS jira guard

# --- Section 1c: Open child stories for each active epic ---
echo "### SECTION: EPIC_CHILDREN"
if ! $JIRA_OK; then echo "{}"; echo ""; else
curl -s -u "$JIRA_EMAIL:$JIRA_TOKEN" \
  "https://${JIRA_INSTANCE}/rest/api/3/search/jql" \
  -G \
  --data-urlencode "jql=project = ${JIRA_PROJECT} AND issuetype = Epic AND status in (\"In Progress\", Review, Refinement, Backlog) ORDER BY \"Target end\" ASC" \
  --data-urlencode "maxResults=30" \
  --data-urlencode "fields=key" | python3 -c "
import sys, json, urllib.request, urllib.parse, base64, os
sys.path.insert(0, '$(dirname "$0")')
from lib.shared import JIRA_BOT_AUTHORS, adf_to_text

data = json.load(sys.stdin)
jira_email = os.environ.get('JIRA_EMAIL', '')
jira_token = os.environ.get('JIRA_TOKEN', '')
auth = base64.b64encode(f'{jira_email}:{jira_token}'.encode()).decode()

epic_keys = [issue['key'] for issue in data.get('issues', [])]
results = {}

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
            if author_name in JIRA_BOT_AUTHORS:
                continue
            body_text = adf_to_text(c.get('body'), 150)
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
fi # end EPIC_CHILDREN jira guard

# --- Section 1d: PR lookup for child tickets in Code Review/Review ---
echo "### SECTION: CHILD_PR_STATUS"
if ! $JIRA_OK; then echo "{}"; echo ""; else
# Collect child ticket keys in Code Review or Review from the EPIC_CHILDREN output,
# then look up their corresponding GitHub PRs
curl -s -u "$JIRA_EMAIL:$JIRA_TOKEN" \
  "https://${JIRA_INSTANCE}/rest/api/3/search/jql" \
  -G \
  --data-urlencode "jql=project = ${JIRA_PROJECT} AND issuetype != Epic AND status in (\"Code Review\", Review) AND issueFunction in linkedIssuesOf(\"project = ${JIRA_PROJECT} AND issuetype = Epic AND status in ('In Progress', Review, Refinement, Backlog)\", \"is child of\") ORDER BY updated DESC" \
  --data-urlencode "maxResults=30" \
  --data-urlencode "fields=key,summary,status" 2>/dev/null | python3 -c "
import sys, json, subprocess, os
sys.path.insert(0, '$(dirname "$0")')
from lib.shared import resolve_reviewers, get_checks_status, GITHUB_BOT_USERS

REPO = '${REPO}'
github_user = os.environ['GITHUB_USER']

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
                 '--jq', '.items[0] | {number, title, user: .user.login}'],
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

        # Get PR details + mergeable state
        mergeable_state = 'unknown'
        requested = []
        try:
            req_result = subprocess.run(
                ['gh', 'api', f'repos/{REPO}/pulls/{pr_num}',
                 '--jq', '{requested: [.requested_reviewers[].login], mergeable_state: .mergeable_state}'],
                capture_output=True, text=True, timeout=15
            )
            if req_result.returncode == 0 and req_result.stdout.strip():
                pr_extra = json.loads(req_result.stdout)
                requested = pr_extra.get('requested', [])
                mergeable_state = pr_extra.get('mergeable_state', 'unknown')
        except: pass

        reviewers = resolve_reviewers(pr_num, REPO, github_user, requested)
        approvals = sum(1 for r in reviewers if r['state'] == 'approved')
        changes_requested = sum(1 for r in reviewers if r['state'] == 'changes_requested')

        # Get last 8 unresolved non-bot comments (issue + review via GraphQL)
        comments = []

        # Issue comments
        comments_result = subprocess.run(
            ['gh', 'api', f'repos/{REPO}/issues/{pr_num}/comments',
             '--jq', '[.[] | {user: .user.login, body: .body[:1500], created_at: .created_at}]'],
            capture_output=True, text=True, timeout=15
        )
        if comments_result.returncode == 0 and comments_result.stdout.strip():
            comments.extend(json.loads(comments_result.stdout))

        # Unresolved review thread comments via GraphQL (last 5 per thread)
        owner, repo_name = REPO.split('/')
        gql_query = 'query { repository(owner: "%s", name: "%s") { pullRequest(number: %d) { reviewThreads(first: 50) { nodes { isResolved comments(last: 5) { nodes { author { login } body createdAt } } } } } } }' % (owner, repo_name, pr_num)
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
                for c in nodes:
                    comments.append({
                        'user': (c.get('author') or {}).get('login',''),
                        'body': c.get('body','')[:150],
                        'created_at': (c.get('createdAt') or '')
                    })

        # Filter bots, sort by date, take last 8
        comments = [c for c in comments if c.get('user') not in GITHUB_BOT_USERS]
        comments.sort(key=lambda c: c.get('created_at', ''), reverse=True)
        comments = comments[:8]

        checks_status = get_checks_status(pr_num, REPO)

        results[key] = {
            'pr_number': pr_num,
            'pr_title': pr_info.get('title', ''),
            'pr_author': pr_info.get('user', ''),
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
fi # end CHILD_PR_STATUS jira guard

# --- Section 1e: Siblings — open children of each epic's parent (non-OCMUI) ---
echo "### SECTION: SIBLINGS"
if ! $JIRA_OK; then echo "{}"; echo ""; else
curl -s -u "$JIRA_EMAIL:$JIRA_TOKEN" \
  "https://${JIRA_INSTANCE}/rest/api/3/search/jql" \
  -G \
  --data-urlencode "jql=project = ${JIRA_PROJECT} AND issuetype = Epic AND status in (\"In Progress\", Review, Refinement, Backlog) ORDER BY \"Target end\" ASC" \
  --data-urlencode "maxResults=40" \
  --data-urlencode "fields=key,parent" \
  --data-urlencode "expand=names" | python3 -c "
import sys, json, urllib.request, urllib.parse, base64, os, re
sys.path.insert(0, '$(dirname "$0")')
from lib.shared import JIRA_BOT_AUTHORS, adf_to_text

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
        for issue in resp_data.get('issues', []):
            ikey = issue['key']
            ifields = issue['fields']
            # Get latest non-bot comment
            latest_comment = None
            comments_data = ifields.get('comment', {}).get('comments', [])
            for c in reversed(comments_data):
                author_name = (c.get('author') or {}).get('displayName', 'Unknown')
                if author_name in JIRA_BOT_AUTHORS:
                    continue
                body_text = adf_to_text(c.get('body'), 150)
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
fi # end SIBLINGS jira guard

# --- Section 6: Jira tickets where I was @mentioned (last 1 month, unanswered) ---
echo "### SECTION: JIRA_MENTIONS"
if ! $JIRA_OK; then jira_skip; else
MY_JIRA_ACCOUNT_ID=$(curl -s -u "$JIRA_EMAIL:$JIRA_TOKEN" "https://${JIRA_INSTANCE}/rest/api/3/myself" | python3 -c "import sys,json; print(json.load(sys.stdin).get('accountId',''))" 2>/dev/null)
curl -s -u "$JIRA_EMAIL:$JIRA_TOKEN" \
  "https://${JIRA_INSTANCE}/rest/api/3/search/jql" \
  -G \
  --data-urlencode "jql=project = ${JIRA_PROJECT} AND status not in (Done, Closed) AND updated >= -4w AND (assignee is EMPTY OR assignee != currentUser()) AND reporter != currentUser() ORDER BY updated DESC" \
  --data-urlencode "fields=key,summary,status,assignee,updated,comment" \
  --data-urlencode "maxResults=100" | python3 -c "
import sys, json
from datetime import datetime, timedelta, timezone

MY_ID = '${MY_JIRA_ACCOUNT_ID}'
ONE_MONTH_AGO = (datetime.now(timezone.utc) - timedelta(weeks=4)).isoformat()

data = json.load(sys.stdin)
issues = data.get('issues', [])
mentioned_in = []

for issue in issues:
    key = issue['key']
    fields = issue.get('fields', {})
    comments = fields.get('comment', {}).get('comments', [])
    # Check comments in reverse (most recent first) for a mention of me
    mention_comment = None
    mention_date = None
    for c in reversed(comments):
        created = c.get('created', '')
        if created < ONE_MONTH_AGO:
            continue
        body = c.get('body', {})
        def has_mention(node):
            if isinstance(node, dict):
                if node.get('type') == 'mention' and node.get('attrs', {}).get('id') == MY_ID:
                    return True
                for v in node.values():
                    if has_mention(v):
                        return True
            elif isinstance(node, list):
                for item in node:
                    if has_mention(item):
                        return True
            return False
        if has_mention(body):
            mention_comment = c
            mention_date = created
            break

    if not mention_comment:
        continue

    # Check if I replied to the mentioner in a later comment
    # (my later comment must @mention the person who mentioned me)
    mentioner_id = mention_comment.get('author', {}).get('accountId', '')
    i_responded = False
    for c in comments:
        c_date = c.get('created', '')
        if c_date <= mention_date:
            continue
        c_author_id = c.get('author', {}).get('accountId', '')
        if c_author_id != MY_ID:
            continue
        # Check if this comment @mentions the original mentioner
        def mentions_user(node, target_id):
            if isinstance(node, dict):
                if node.get('type') == 'mention' and node.get('attrs', {}).get('id') == target_id:
                    return True
                for v in node.values():
                    if mentions_user(v, target_id):
                        return True
            elif isinstance(node, list):
                for item in node:
                    if mentions_user(item, target_id):
                        return True
            return False
        if mentions_user(c.get('body', {}), mentioner_id):
            i_responded = True
            break

    if i_responded:
        continue

    # Extract text from the mention comment
    author = mention_comment.get('author', {}).get('displayName', '?')
    texts = []
    def get_text(node):
        if isinstance(node, dict):
            if node.get('type') == 'text':
                texts.append(node.get('text', ''))
            elif node.get('type') == 'mention':
                texts.append(node.get('attrs', {}).get('text', ''))
            for v in node.values():
                get_text(v)
        elif isinstance(node, list):
            for item in node:
                get_text(item)
    get_text(mention_comment.get('body', {}))
    full_text = ' '.join(texts)[:300]
    mentioned_in.append({
        'key': key,
        'summary': fields.get('summary', '')[:100],
        'status': fields.get('status', {}).get('name', ''),
        'assignee': (fields.get('assignee') or {}).get('displayName', 'Unassigned'),
        'mentioned_by': author,
        'mention_date': mention_date[:10],
        'mention_text': full_text
    })

print(json.dumps(mentioned_in, indent=2))
"
echo ""
fi # end JIRA_MENTIONS jira guard

# ─── ACTION ITEMS FROM GOOGLE DOCS ───────────────────────────────────
echo "### SECTION: ACTION_ITEMS"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
bash "$SCRIPT_DIR/gather-actions.sh" 2>/dev/null || echo "[]"
echo ""

# ─── ACTION ITEMS FROM JIRA (description or comments containing action item tags) ───
echo "### SECTION: JIRA_ACTION_ITEMS"
if ! $JIRA_OK; then jira_skip; else
ACTION_ITEM_NAME="${ACTION_ITEM_NAME:-Dave}"
curl -s -u "$JIRA_EMAIL:$JIRA_TOKEN" \
  "https://${JIRA_INSTANCE}/rest/api/3/search/jql" \
  -G \
  --data-urlencode "jql=project = ${JIRA_PROJECT} AND (description ~ \"Action Item ${ACTION_ITEM_NAME}\" OR comment ~ \"Action Item ${ACTION_ITEM_NAME}\") AND updated >= -1w ORDER BY updated DESC" \
  --data-urlencode "fields=key,summary,status,description,comment,updated,created" \
  --data-urlencode "maxResults=20" | python3 -c "
import sys, json, re

ACTION_NAME = '${ACTION_ITEM_NAME}'
PATTERNS = [
    re.compile(r'\[' + ACTION_NAME + r'\s+Action\s+Item\]', re.IGNORECASE),
    re.compile(r'\[Action\s+Item\s+' + ACTION_NAME + r'\]', re.IGNORECASE),
    re.compile(ACTION_NAME + r':\s*Action\s+Item', re.IGNORECASE),
]

def extract_text(node):
    if isinstance(node, dict):
        t = node.get('type', '')
        if t == 'text':
            return node.get('text', '')
        if t == 'hardBreak':
            return '\n'
        if t in ('paragraph', 'heading', 'bulletList', 'listItem', 'orderedList'):
            content = node.get('content', [])
            inner = ''.join(extract_text(c) for c in content)
            return inner + '\n'
        parts = []
        for v in node.values():
            parts.append(extract_text(v))
        return ''.join(parts)
    elif isinstance(node, list):
        return ''.join(extract_text(item) for item in node)
    return ''

def find_action_lines(text):
    results = []
    for line in text.split('\n'):
        for pat in PATTERNS:
            if pat.search(line):
                results.append(line.strip())
                break
    return results

data = json.load(sys.stdin)
items = []

for issue in data.get('issues', []):
    key = issue['key']
    fields = issue.get('fields', {})
    summary = fields.get('summary', '')
    
    # Check description
    desc_adf = fields.get('description') or {}
    desc_text = extract_text(desc_adf)
    desc_actions = find_action_lines(desc_text)
    for action in desc_actions:
        items.append({
            'key': key,
            'summary': summary[:80],
            'text': action,
            'source': 'description',
            'date': (fields.get('updated') or fields.get('created') or '')[:10],
            'url': f'https://redhat.atlassian.net/browse/{key}'
        })
    
    # Check comments
    comment_data = fields.get('comment', {})
    comments = comment_data.get('comments', []) if isinstance(comment_data, dict) else []
    for c in comments:
        c_text = extract_text(c.get('body', {}))
        c_actions = find_action_lines(c_text)
        for action in c_actions:
            items.append({
                'key': key,
                'summary': summary[:80],
                'text': action,
                'source': 'comment',
                'date': (c.get('created') or '')[:10],
                'url': f'https://redhat.atlassian.net/browse/{key}?focusedId={c.get(\"id\",\"\")}&page=com.atlassian.jira.plugin.system.issuetabpanels%3Acomment-tabpanel#comment-{c.get(\"id\",\"\")}'
            })

print(json.dumps(items, indent=2))
"
echo ""
fi # end JIRA_ACTION_ITEMS jira guard
echo "=== END ==="
