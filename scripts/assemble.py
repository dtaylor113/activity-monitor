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
    mentions = json.loads(extract_section(raw, 'MENTIONS') or '[]')
    my_open_prs = json.loads(extract_section(raw, 'MY_OPEN_PRS') or '[]')
    pr_status = parse_json_safe(extract_section(raw, 'PR_STATUS'), {})
    jta_raw = extract_section(raw, 'JIRA_TICKET_ACTIVITY')
    jira_activity = json.loads(jta_raw) if jta_raw else []

    action_items_raw = extract_section(raw, 'ACTION_ITEMS')
    action_items = json.loads(action_items_raw) if action_items_raw else []

    jira_mentions_raw = extract_section(raw, 'JIRA_MENTIONS')
    jira_mentions = json.loads(jira_mentions_raw) if jira_mentions_raw else []

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
    for pr in mentions:
        if pr['number'] not in pr_map:
            pr_map[pr['number']] = {
                'number': pr['number'], 'title': pr['title'], 'author': pr['author'],
                'is_mine': False, 'updated': pr['updated_at'][:10],
                'created': (pr.get('created_at') or '')[:10],
                'what': 'mentioned', 'comments': []
            }
        else:
            entry = pr_map[pr['number']]
            if 'mention' not in entry.get('what', ''):
                entry['what'] = (entry.get('what', '') + ', mentioned').strip(', ')

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
                'body': c.get('body', '')[:200]
            })
    for num, comments in pr_comments_by_num.items():
        if num in pr_map:
            pr_map[num]['comments'] = sorted(comments, key=lambda x: x['when'], reverse=True)[:8]

    # Populate mention_raw for mentioned PRs using MENTION_COMMENTS section
    mention_comments_raw = extract_section(raw, 'MENTION_COMMENTS')
    mention_comments = parse_json_safe(mention_comments_raw, {})
    for num, entry in pr_map.items():
        if 'mention' not in entry.get('what', ''):
            continue
        entry.setdefault('mention_summary', '')
        entry.setdefault('mention_raw', '')
        mc_list = mention_comments.get(str(num), [])
        if isinstance(mc_list, dict):
            mc_list = [mc_list]
        # Find most recent comment where @user appears in non-quoted text
        for mc in sorted(mc_list, key=lambda x: x.get('created_at', ''), reverse=True):
            body = mc.get('body', '')
            non_quoted = '\n'.join(l for l in body.split('\n') if not l.strip().startswith('>'))
            if f'@{github_user}' in non_quoted:
                lines = [l for l in body.split('\n') if not l.strip().startswith('>')]
                meaningful = [l for l in lines if l.strip()]
                tail = meaningful[-10:] if len(meaningful) > 10 else meaningful
                entry['mention_raw'] = '\n'.join(tail)
                break

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
    senior_staff = json.loads(os.environ.get('SENIOR_STAFF', '[]'))
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

        # PR AI summaries — only preserve if comment data hasn't changed
        prev_prs = {p['number']: p for p in prev.get('prs', []) if isinstance(p, dict)}
        for pr in data['prs']:
            pp = prev_prs.get(pr['number'], {})
            if not pp:
                continue
            cur_comments = pr.get('comments', [])
            prev_comments = pp.get('comments', [])
            comments_changed = (
                len(cur_comments) != len(prev_comments) or
                (cur_comments and prev_comments and cur_comments[0].get('when') != prev_comments[0].get('when'))
            )
            if pp.get('ai_summary') and 'ai_summary' not in pr and not comments_changed:
                pr['ai_summary'] = pp['ai_summary']
            if pp.get('mention_summary') and not pr.get('mention_summary') and not comments_changed:
                pr['mention_summary'] = pp['mention_summary']

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

        # Jira mentions AI summaries — match by issue key
        prev_jira_mentions = {m['key']: m for m in prev.get('jira_mentions', []) if isinstance(m, dict)}
        for item in data['jira_mentions']:
            pm = prev_jira_mentions.get(item['key'], {})
            if pm.get('ai_summary') and not item.get('ai_summary'):
                # Only preserve if mention_text hasn't changed
                if pm.get('mention_text') == item.get('mention_text'):
                    item['ai_summary'] = pm['ai_summary']

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
