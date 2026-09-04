#!/usr/bin/env python3
"""
Assemble activity-data.js from gather.sh output.

Reads raw gather output from a file (or stdin), parses all sections,
and writes activity-data.js. Preserves AI summary fields from the
previous activity-data.js if it exists.

Usage:
    python3 assemble.py <gather-output-file> <output-dir>
    cat gather-output.txt | python3 assemble.py - <output-dir>
"""
import json
import re
import sys
import os
from datetime import datetime, date


def extract_section(raw, name):
    pattern = rf'### SECTION: {name}\n(.*?)(?=### SECTION:|=== END ===)'
    m = re.search(pattern, raw, re.DOTALL)
    return m.group(1).strip() if m else ''


def parse_json_safe(content, default=None):
    if not content:
        return default if default is not None else {}
    try:
        return json.loads(content)
    except json.JSONDecodeError:
        try:
            return json.loads('{' + content.lstrip('{').rstrip('}') + '}')
        except Exception:
            return default if default is not None else {}


def age_label(date_str):
    """Return a human-readable age label like '@ 3 days ago'."""
    if not date_str:
        return ''
    try:
        d = datetime.strptime(date_str[:10], '%Y-%m-%d').date()
    except (ValueError, TypeError):
        return ''
    days = (date.today() - d).days
    if days <= 0:
        return '@ today'
    if days == 1:
        return '@ 1 day ago'
    if days < 14:
        return f'@ {days} days ago'
    if days < 60:
        return f'@ ~{days // 7} weeks ago'
    return f'@ ~{days // 30} months ago'


def generate_pr_status_badge(pr, pr_st, github_user):
    """Generate a compact status badge for a PR.

    Returns a short string indicating the ball-in-court status:
    - "Changes requested by {user}" — another reviewer requested changes, awaiting author
    - "Awaiting author" — you requested changes or commented last, author hasn't replied
    - "Needs your re-review" — author pushed or replied after changes were requested
    - "New activity since approval" — user approved but new comments appeared
    - "Approved" — user approved, no new activity since
    - "Pending" — user hasn't reviewed yet
    """
    comments = pr.get('comments', [])
    reviewers = pr_st.get('reviewers', []) if pr_st else []
    author = pr.get('author', '')
    is_mine = pr.get('is_mine', False) or author == github_user
    head_sha = pr_st.get('head_sha', '') if pr_st else ''
    my_last_review_at = pr_st.get('my_last_review_at', '') if pr_st else ''

    if is_mine:
        pending = [r for r in reviewers if r.get('state') == 'pending']
        approved = [r for r in reviewers if r.get('state') == 'approved']
        changes_req = [r for r in reviewers if r.get('state') == 'changes_requested']
        if changes_req:
            names = ', '.join(r['user'] for r in changes_req)
            return f'Changes requested by {names}' if len(changes_req) == 1 else 'Changes requested'
        if approved:
            return f'{len(approved)} approved'
        if pending:
            return 'Awaiting review'
        if not reviewers:
            return 'No reviewers'
        return ''

    my_review = next((r for r in reviewers if r.get('user') == github_user), None)
    my_state = (my_review or {}).get('state', 'pending')

    non_bot_comments = [c for c in comments if c.get('who', '') not in
                        {'coderabbitai[bot]', 'codecov[bot]', 'sourcery-ai[bot]'}]

    others_cr = [r for r in reviewers if r.get('state') == 'changes_requested' and r.get('user') != github_user]
    author_replied_last = non_bot_comments and non_bot_comments[0].get('who', '') == author

    if my_state == 'approved':
        if my_last_review_at and non_bot_comments:
            latest_comment = non_bot_comments[0]
            if latest_comment.get('when', '') > my_last_review_at[:10] and latest_comment.get('who', '') != github_user:
                if author_replied_last:
                    return 'Needs your re-review'
                return 'New activity since approval'
        return 'Approved'

    if my_state == 'changes_requested':
        if author_replied_last:
            return 'Needs your re-review'
        return 'Awaiting author'

    # pending or commented — check if another reviewer's changes_requested is blocking
    if others_cr and not author_replied_last:
        names = ', '.join(r['user'] for r in others_cr)
        return f'Changes requested by {names}'

    if my_state == 'commented':
        if non_bot_comments:
            latest = non_bot_comments[0]
            if latest.get('who', '') == github_user:
                return 'Awaiting author'
            if author_replied_last:
                return 'Needs your re-review'
        return 'Pending'

    return 'Pending'


def load_previous_ai(output_dir):
    """Load AI summary fields from existing activity-data.js."""
    path = os.path.join(output_dir, 'activity-data.js')
    if not os.path.exists(path):
        return {}
    try:
        with open(path) as f:
            content = f.read()
        # Support both "const D = {...}" and "window.ACTIVITY_DATA = {...}" formats
        start = content.index('{')
        end = content.rindex('}') + 1
        return json.loads(content[start:end])
    except Exception:
        return {}


def assemble(raw, output_dir):
    github_user = os.environ.get('GITHUB_USER', 'dtaylor113')
    bot_users = {'coderabbitai[bot]', 'codecov[bot]', 'sourcery-ai[bot]'}

    epics = json.loads(extract_section(raw, 'ALL_EPICS'))
    parent_list = json.loads(extract_section(raw, 'PARENT_EPIC_STATUS') or '[]')
    epic_children = parse_json_safe(extract_section(raw, 'EPIC_CHILDREN'), {})
    child_pr_status = parse_json_safe(extract_section(raw, 'CHILD_PR_STATUS'), {})
    siblings = parse_json_safe(extract_section(raw, 'SIBLINGS'), {})
    review_requests = json.loads(extract_section(raw, 'REVIEW_REQUESTS') or '[]')
    stale_reviews = json.loads(extract_section(raw, 'STALE_REVIEWS') or '[]')
    approved_reviews = json.loads(extract_section(raw, 'APPROVED_REVIEWS') or '[]')
    my_open_prs = json.loads(extract_section(raw, 'MY_OPEN_PRS') or '[]')
    pr_status = parse_json_safe(extract_section(raw, 'PR_STATUS'), {})
    jta_raw = extract_section(raw, 'JIRA_TICKET_ACTIVITY')
    jira_activity = json.loads(jta_raw) if jta_raw else []

    action_items_raw = extract_section(raw, 'ACTION_ITEMS')
    action_items = json.loads(action_items_raw) if action_items_raw else []

    jira_action_items_raw = extract_section(raw, 'JIRA_ACTION_ITEMS')
    jira_action_items = json.loads(jira_action_items_raw) if jira_action_items_raw else []

    jira_mentions_raw = extract_section(raw, 'JIRA_MENTIONS')
    jira_mentions = json.loads(jira_mentions_raw) if jira_mentions_raw else []

    qa_contact_raw = extract_section(raw, 'QA_CONTACT')
    qa_contact = json.loads(qa_contact_raw) if qa_contact_raw else []

    pc_raw = extract_section(raw, 'PR_COMMENTS')
    pr_comments_flat = []
    if pc_raw:
        nested = json.loads(f'[{pc_raw}]')
        for entry in nested:
            if isinstance(entry, list):
                pr_comments_flat.extend(entry)
            elif isinstance(entry, dict):
                pr_comments_flat.append(entry)

    # Parent alignment and comments
    parent_alignment, parent_comments = {}, {}
    for item in parent_list:
        ek, pk = item['epic_key'], item['parent_key']
        parent_alignment[ek] = {
            'parent_key': pk,
            'parent_summary': item.get('parent_summary', ''),
            'parent_target_end': item.get('parent_target_end'),
            'parent_status': item.get('parent_status', ''),
            'date_mismatch': item.get('date_mismatch', False),
            'near_due': False
        }
        if item.get('parent_recent_comments') and pk not in parent_comments:
            parent_comments[pk] = item['parent_recent_comments']

    for epic in epics:
        pa = parent_alignment.get(epic['key'])
        if pa and pa.get('parent_target_end') and not epic.get('parent_target_end'):
            epic['parent_target_end'] = pa['parent_target_end']

    # Build PR map
    pr_map = {}
    for pr in my_open_prs:
        pr_map[pr['number']] = {
            'number': pr['number'], 'title': pr['title'], 'author': github_user,
            'is_mine': True, 'updated': pr['updated_at'][:10],
            'created': (pr.get('created_at') or '')[:10],
            'what': 'Draft' if pr.get('is_draft') else '', 'comments': []
        }
    for pr in review_requests:
        if pr['number'] not in pr_map:
            pr_map[pr['number']] = {
                'number': pr['number'], 'title': pr['title'], 'author': pr['author'],
                'is_mine': False, 'updated': pr['updated_at'][:10],
                'created': (pr.get('created_at') or '')[:10],
                'what': 'review requested', 'comments': []
            }
    for pr in stale_reviews:
        if pr['number'] not in pr_map:
            pr_map[pr['number']] = {
                'number': pr['number'], 'title': pr['title'], 'author': pr['author'],
                'is_mine': False, 'updated': pr['updated_at'][:10],
                'created': (pr.get('created_at') or '')[:10],
                'what': 'stale review', 'comments': []
            }
        else:
            entry = pr_map[pr['number']]
            if 'stale' not in entry.get('what', ''):
                entry['what'] = ('stale review, ' + entry.get('what', '')).strip(', ')
    # Group PR comments
    pr_comments_by_num = {}
    for c in pr_comments_flat:
        if not isinstance(c, dict):
            continue
        num = c.get('pr')
        if num:
            pr_comments_by_num.setdefault(num, []).append({
                'who': c.get('user', ''),
                'when': c.get('updated_at', '')[:10],
                'body': c.get('body', '')[:500]
            })
    for num, comments in pr_comments_by_num.items():
        if num in pr_map:
            pr_map[num]['comments'] = sorted(comments, key=lambda x: x['when'], reverse=True)[:12]

    # Add approved PRs that aren't already in pr_map
    for pr in approved_reviews:
        if pr['number'] not in pr_map:
            pr_map[pr['number']] = {
                'number': pr['number'], 'title': pr['title'], 'author': pr['author'],
                'is_mine': False, 'updated': pr['updated_at'][:10],
                'created': (pr.get('created_at') or '')[:10],
                'what': 'approved', 'comments': []
            }

    prs_list = sorted(pr_map.values(), key=lambda x: x['updated'])

    # Filter bots from reviewers
    for num, st in pr_status.items():
        if isinstance(st, dict):
            st['reviewers'] = [r for r in st.get('reviewers', []) if r['user'] not in bot_users]
    for key, cpr in child_pr_status.items():
        if isinstance(cpr, dict):
            cpr['reviewers'] = [r for r in cpr.get('reviewers', []) if r['user'] not in bot_users]

    # Assemble data
    senior_staff = ['zherman0', 'lizagilman', 'jmekkatt']
    data = {
        'meta': {
            'last_checked': datetime.now().astimezone().isoformat(),
            'lookback_days': 3,
            'github_user': github_user,
            'senior_staff': senior_staff
        },
        'epics': epics,
        'parent_alignment': parent_alignment,
        'parent_comments': parent_comments,
        'parent_comments_ai': {},
        'epic_children': epic_children,
        'child_pr_status': child_pr_status,
        'siblings': siblings,
        'siblings_ai': {},
        'prs': prs_list,
        'pr_status': pr_status,
        'jira_activity': jira_activity,
        'action_items': action_items,
        'jira_action_items': jira_action_items,
        'qa_contact': qa_contact,
        'jira_mentions': jira_mentions,
        'dismissed_jira_mentions': [],
        'retro_items': []
    }

    # Merge AI summaries from previous run
    prev = load_previous_ai(output_dir)
    if prev:
        # Top-level AI fields
        if prev.get('parent_comments_ai'):
            data['parent_comments_ai'] = prev['parent_comments_ai']
        if prev.get('siblings_ai'):
            data['siblings_ai'] = prev['siblings_ai']

        # Epic-level AI fields
        prev_epics = {e['key']: e for e in prev.get('epics', []) if isinstance(e, dict)}
        for epic in data['epics']:
            pe = prev_epics.get(epic['key'], {})
            if pe.get('comments_ai') and 'comments_ai' not in epic:
                epic['comments_ai'] = pe['comments_ai']
            if pe.get('uber_ai') and 'uber_ai' not in epic:
                epic['uber_ai'] = pe['uber_ai']

        # PR status badges — always regenerate (they're deterministic and cheap)
        prev_prs = {p['number']: p for p in prev.get('prs', []) if isinstance(p, dict)}
        for pr in data['prs']:
            pass  # status_badge is always regenerated below, no need to preserve

        # Epic children AI summaries
        prev_children = prev.get('epic_children', {})
        for ek, ch in data['epic_children'].items():
            pch = prev_children.get(ek, {})
            if pch.get('ai_summary') and 'ai_summary' not in ch:
                ch['ai_summary'] = pch['ai_summary']

        # Child PR AI summaries
        prev_cpr = prev.get('child_pr_status', {})
        for key, cpr in data['child_pr_status'].items():
            pcpr = prev_cpr.get(key, {})
            if isinstance(pcpr, dict) and pcpr.get('ai_summary') and isinstance(cpr, dict) and 'ai_summary' not in cpr:
                cpr['ai_summary'] = pcpr['ai_summary']

        # Action item AI summaries — match by (doc_id, text[:100])
        prev_actions = {(a['doc_id'], a['text'][:100]): a for a in prev.get('action_items', []) if isinstance(a, dict)}
        for item in data['action_items']:
            key = (item['doc_id'], item['text'][:100])
            pa = prev_actions.get(key, {})
            if pa.get('ai_summary') and not item.get('ai_summary'):
                item['ai_summary'] = pa['ai_summary']

        # Retro items — preserve from previous run (manually maintained)
        if prev.get('retro_items'):
            data['retro_items'] = prev['retro_items']

        # Dismissed jira mentions — preserve from previous run (manually maintained)
        if prev.get('dismissed_jira_mentions'):
            data['dismissed_jira_mentions'] = prev['dismissed_jira_mentions']

        # Jira action items — merge previous with new (accumulate over time)
        prev_jira_ai = prev.get('jira_action_items', [])
        if prev_jira_ai:
            existing_keys = {(i.get('key', '') + '|' + (i.get('text', '')[:80])) for i in data['jira_action_items']}
            for item in prev_jira_ai:
                item_key = item.get('key', '') + '|' + (item.get('text', '')[:80])
                if item_key not in existing_keys:
                    data['jira_action_items'].append(item)
                    existing_keys.add(item_key)

        # Jira mentions AI summaries — match by issue key
        prev_jira_mentions = {m['key']: m for m in prev.get('jira_mentions', []) if isinstance(m, dict)}
        for item in data['jira_mentions']:
            pm = prev_jira_mentions.get(item['key'], {})
            if pm.get('ai_summary') and not item.get('ai_summary'):
                # Only preserve if mention_text hasn't changed
                if pm.get('mention_text') == item.get('mention_text'):
                    item['ai_summary'] = pm['ai_summary']

    # Generate status badges for all PRs (deterministic, always regenerated)
    for pr in data['prs']:
        pr_st = pr_status.get(str(pr['number']))
        pr['status_badge'] = generate_pr_status_badge(pr, pr_st, github_user)
        pr.pop('ai_summary', None)

    # Write output
    output_path = os.path.join(output_dir, 'activity-data.js')
    with open(output_path, 'w') as f:
        f.write('const D = ')
        json.dump(data, f, indent=2)
        f.write(';')

    return len(epics), len(prs_list), len(child_pr_status), len(action_items), len(jira_mentions)


def main():
    if len(sys.argv) < 3:
        print("Usage: assemble.py <gather-output-file | -> <output-dir>", file=sys.stderr)
        sys.exit(1)

    input_path = sys.argv[1]
    output_dir = sys.argv[2]

    if input_path == '-':
        raw = sys.stdin.read()
    else:
        with open(input_path) as f:
            raw = f.read()

    n_epics, n_prs, n_child_prs, n_actions, n_jira_mentions = assemble(raw, output_dir)
    print(f"[activity-monitor] Assembled: {n_epics} epics, {n_prs} PRs, {n_child_prs} child PRs, {n_actions} action items, {n_jira_mentions} jira mentions")


if __name__ == '__main__':
    main()
