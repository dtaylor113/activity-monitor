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
from datetime import datetime


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
        # Parse JSON from either "const D = {...}" format
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
    action_items_raw = extract_section(raw, 'ACTION_ITEMS')
    action_items = json.loads(action_items_raw) if action_items_raw else []

    jira_action_items_raw = extract_section(raw, 'JIRA_ACTION_ITEMS')
    jira_action_items = json.loads(jira_action_items_raw) if jira_action_items_raw else []

    jira_mentions_raw = extract_section(raw, 'JIRA_MENTIONS')
    jira_mentions = json.loads(jira_mentions_raw) if jira_mentions_raw else []

    # Backfill epic target_end from parent when the epic's own field is
    # empty, and collect each parent's recent comments for the detail panel.
    parent_target_end_by_epic, parent_comments = {}, {}
    for item in parent_list:
        pk = item['parent_key']
        parent_target_end_by_epic[item['epic_key']] = item.get('parent_target_end')
        if item.get('parent_recent_comments') and pk not in parent_comments:
            parent_comments[pk] = item['parent_recent_comments']

    for epic in epics:
        parent_target_end = parent_target_end_by_epic.get(epic['key'])
        if parent_target_end and not epic.get('parent_target_end'):
            epic['parent_target_end'] = parent_target_end

    # Filter bots from reviewers (child_pr_status only — main PR tables are
    # fetched live client-side from ACTIVITY_MONITOR.html, see gather.sh note)
    for key, cpr in child_pr_status.items():
        if isinstance(cpr, dict):
            cpr['reviewers'] = [r for r in cpr.get('reviewers', []) if r['user'] not in bot_users]

    # Assemble data
    data = {
        'meta': {
            'last_checked': datetime.now().astimezone().isoformat(),
            'github_user': github_user
        },
        'epics': epics,
        'parent_comments': parent_comments,
        'parent_comments_ai': {},
        'epic_children': epic_children,
        'child_pr_status': child_pr_status,
        'siblings': siblings,
        'siblings_ai': {},
        'action_items': action_items,
        'jira_action_items': jira_action_items,
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

    # Write output
    output_path = os.path.join(output_dir, 'activity-data.js')
    with open(output_path, 'w') as f:
        f.write('const D = ')
        json.dump(data, f, indent=2)
        f.write(';')

    return len(epics), len(child_pr_status), len(action_items), len(jira_mentions)


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

    n_epics, n_child_prs, n_actions, n_jira_mentions = assemble(raw, output_dir)
    print(f"[activity-monitor] Assembled: {n_epics} epics, {n_child_prs} child PRs, {n_actions} action items, {n_jira_mentions} jira mentions")


if __name__ == '__main__':
    main()
