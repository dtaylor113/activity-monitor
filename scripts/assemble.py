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
        match = re.search(r'window\.ACTIVITY_DATA\s*=\s*', content)
        if not match:
            return {}
        js_content = content[match.end():].rstrip().rstrip(';')
        return json.loads(js_content)
    except Exception:
        return {}


def assemble(raw, output_dir):
    github_user = os.environ['GITHUB_USER']
    bot_users = {'coderabbitai[bot]', 'codecov[bot]', 'sourcery-ai[bot]'}

    epics = json.loads(extract_section(raw, 'ALL_EPICS'))
    parent_list = json.loads(extract_section(raw, 'PARENT_EPIC_STATUS') or '[]')
    epic_children = parse_json_safe(extract_section(raw, 'EPIC_CHILDREN'), {})
    child_pr_status = parse_json_safe(extract_section(raw, 'CHILD_PR_STATUS'), {})
    siblings = parse_json_safe(extract_section(raw, 'SIBLINGS'), {})
    review_requests = json.loads(extract_section(raw, 'REVIEW_REQUESTS') or '[]')
    stale_reviews = json.loads(extract_section(raw, 'STALE_REVIEWS') or '[]')
    my_open_prs = json.loads(extract_section(raw, 'MY_OPEN_PRS') or '[]')
    pr_status = parse_json_safe(extract_section(raw, 'PR_STATUS'), {})
    jta_raw = extract_section(raw, 'JIRA_TICKET_ACTIVITY')
    jira_activity = json.loads(jta_raw) if jta_raw else []

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
            'what': 'Draft' if pr.get('is_draft') else '', 'comments': []
        }
    for pr in review_requests:
        if pr['number'] not in pr_map:
            pr_map[pr['number']] = {
                'number': pr['number'], 'title': pr['title'], 'author': pr['author'],
                'is_mine': False, 'updated': pr['updated_at'][:10],
                'what': 'review requested', 'comments': []
            }
    for pr in stale_reviews:
        if pr['number'] not in pr_map:
            pr_map[pr['number']] = {
                'number': pr['number'], 'title': pr['title'], 'author': pr['author'],
                'is_mine': False, 'updated': pr['updated_at'][:10],
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
                'body': c.get('body', '')[:200]
            })
    for num, comments in pr_comments_by_num.items():
        if num in pr_map:
            pr_map[num]['comments'] = sorted(comments, key=lambda x: x['when'], reverse=True)[:8]

    prs_list = sorted(pr_map.values(), key=lambda x: x['updated'])

    # Filter bots from reviewers
    for num, st in pr_status.items():
        if isinstance(st, dict):
            st['reviewers'] = [r for r in st.get('reviewers', []) if r['user'] not in bot_users]
    for key, cpr in child_pr_status.items():
        if isinstance(cpr, dict):
            cpr['reviewers'] = [r for r in cpr.get('reviewers', []) if r['user'] not in bot_users]

    # Assemble data
    data = {
        'meta': {
            'last_checked': datetime.now().astimezone().isoformat(),
            'lookback_days': 3,
            'github_user': github_user
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
        'jira_activity': jira_activity
    }

    # Generate siblings AI summaries (grouped by ticket prefix with status counts)
    today = date.today()

    def _age_with_source(dates_with_source):
        parsed = []
        for d, source in dates_with_source:
            if not d:
                continue
            try:
                if 'T' in d:
                    parsed.append((datetime.fromisoformat(d.replace('Z', '+00:00')).date(), source))
                else:
                    parsed.append((datetime.strptime(d[:10], '%Y-%m-%d').date(), source))
            except:
                pass
        if not parsed:
            return ''
        most_recent = max(parsed, key=lambda x: x[0])
        dt, source = most_recent
        delta = (today - dt).days
        if delta == 0:
            age = '@ today'
        elif delta == 1:
            age = '@ 1 day ago'
        elif delta < 14:
            age = f'@ {delta} days ago'
        elif delta < 60:
            age = f'@ ~{delta // 7} weeks ago'
        else:
            age = f'@ ~{delta // 30} months ago'
        return f"{age} ({source})"

    for epic_key, sibs in siblings.items():
        if not sibs:
            continue
        # Age indicator from most recent activity
        all_dates = []
        for s in sibs:
            if s.get('updated'):
                all_dates.append((s['updated'], 'Jira'))
            if s.get('latest_comment') and s['latest_comment'].get('created'):
                all_dates.append((s['latest_comment']['created'], 'Jira'))
        age = _age_with_source(all_dates)

        by_prefix = {}
        for s in sibs:
            prefix = s['key'].split('-')[0]
            by_prefix.setdefault(prefix, []).append(s)
        prefix_parts = []
        for prefix, items in by_prefix.items():
            status_counts = {}
            for item in items:
                status_counts[item['status']] = status_counts.get(item['status'], 0) + 1
            status_strs = [f"{count} {status}" for status, count in status_counts.items()]
            prefix_parts.append(f"{prefix} ({', '.join(status_strs)})")
        summary = ' + '.join(prefix_parts)
        data['siblings_ai'][epic_key] = f"{age} — {summary}" if age else summary

    # Merge AI summaries from previous run
    prev = load_previous_ai(output_dir)
    if prev:
        # Top-level AI fields
        if prev.get('parent_comments_ai'):
            data['parent_comments_ai'] = prev['parent_comments_ai']

        # Epic-level AI fields
        prev_epics = {e['key']: e for e in prev.get('epics', []) if isinstance(e, dict)}
        for epic in data['epics']:
            pe = prev_epics.get(epic['key'], {})
            if pe.get('comments_ai') and 'comments_ai' not in epic:
                epic['comments_ai'] = pe['comments_ai']
            if pe.get('uber_ai') and 'uber_ai' not in epic:
                epic['uber_ai'] = pe['uber_ai']

        # PR AI summaries
        prev_prs = {p['number']: p for p in prev.get('prs', []) if isinstance(p, dict)}
        for pr in data['prs']:
            pp = prev_prs.get(pr['number'], {})
            if pp.get('ai_summary') and 'ai_summary' not in pr:
                pr['ai_summary'] = pp['ai_summary']

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

    # Write output
    output_path = os.path.join(output_dir, 'activity-data.js')
    with open(output_path, 'w') as f:
        f.write('window.ACTIVITY_DATA = ')
        json.dump(data, f, indent=2)
        f.write(';')

    return len(epics), len(prs_list), len(child_pr_status)


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

    n_epics, n_prs, n_child_prs = assemble(raw, output_dir)
    print(f"[activity-monitor] Assembled: {n_epics} epics, {n_prs} PRs, {n_child_prs} child PRs")


if __name__ == '__main__':
    main()
