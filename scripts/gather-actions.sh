#!/usr/bin/env bash
# Activity Monitor — gather action items from Google Docs
# Discovers recently viewed docs and scans for action items tagged to the user.
#
# Required environment variables:
#   ACTION_ITEM_NAME  - Name to search for (default: "Dave")
#
# Optional:
#   GOG_KEYRING_BACKEND / GOG_KEYRING_PASSWORD — needed by gog CLI
#
# Output: JSON array of action items to stdout
set -euo pipefail

NAME="${ACTION_ITEM_NAME:-Dave}"
LOOKBACK_DAYS="${ACTION_ITEM_LOOKBACK:-14}"

if ! command -v gog &>/dev/null; then
  echo "[]"
  exit 0
fi

SINCE_DATE=$(date -v-${LOOKBACK_DAYS}d +%Y-%m-%d 2>/dev/null || date -d "${LOOKBACK_DAYS} days ago" +%Y-%m-%d)

DOC_LIST=$(gog drive ls \
  --query "viewedByMeTime > '${SINCE_DATE}' AND mimeType='application/vnd.google-apps.document'" \
  --max 50 --all -p 2>/dev/null || echo "")

if [[ -z "$DOC_LIST" ]]; then
  echo "[]"
  exit 0
fi

TMPDIR=$(mktemp -d)
trap "rm -rf $TMPDIR" EXIT

echo "$DOC_LIST" | tail -n +2 | grep -v "^#" | awk -F'\t' '{print $1 "\t" $2}' > "$TMPDIR/docs.tsv"

if [[ ! -s "$TMPDIR/docs.tsv" ]]; then
  echo "[]"
  exit 0
fi

# Fetch raw JSON for each doc
while IFS=$'\t' read -r doc_id doc_name; do
  [[ -z "$doc_id" ]] && continue
  gog docs raw "$doc_id" --json 2>/dev/null > "$TMPDIR/${doc_id}.json" || true
done < "$TMPDIR/docs.tsv"

# Process all docs with a single Python invocation
python3 - "$TMPDIR" "$NAME" <<'PYTHON_SCRIPT'
import json, sys, os, re, glob

tmpdir = sys.argv[1]
name = sys.argv[2]

from datetime import datetime, timedelta
cutoff_date = (datetime.now() - timedelta(days=60)).strftime('%Y-%m-%d')

patterns = [
    re.compile(rf'\[{re.escape(name)}\s+Action\s*Item\]', re.IGNORECASE),
    re.compile(rf'{re.escape(name)}:\s*Action\s*Item', re.IGNORECASE),
]

strip_patterns = [
    re.compile(rf'^\[{re.escape(name)}\s+Action\s*Item\]:?\s*', re.IGNORECASE),
    re.compile(rf'^{re.escape(name)}:\s*Action\s*Item:?\s*', re.IGNORECASE),
]

docs_tsv = os.path.join(tmpdir, 'docs.tsv')
doc_names = {}
with open(docs_tsv) as f:
    for line in f:
        parts = line.strip().split('\t', 1)
        if len(parts) == 2:
            doc_names[parts[0]] = parts[1]

all_items = []

for json_file in glob.glob(os.path.join(tmpdir, '*.json')):
    doc_id = os.path.basename(json_file).replace('.json', '')
    if doc_id == 'docs':
        continue
    doc_name = doc_names.get(doc_id, doc_id)

    try:
        with open(json_file) as f:
            doc = json.load(f)
    except:
        continue

    # Pass 1: collect all paragraphs with metadata
    paras = []
    current_date = None
    current_heading_id = None
    for elem in doc.get('body', {}).get('content', []):
        if 'paragraph' not in elem:
            continue
        para = elem['paragraph']
        style = para.get('paragraphStyle', {}).get('namedStyleType', '')
        heading_id = para.get('paragraphStyle', {}).get('headingId', '')
        elements = para.get('elements', [])

        if 'HEADING' in style:
            if heading_id:
                current_heading_id = heading_id
            for e in elements:
                if 'dateElement' in e:
                    dep = e['dateElement'].get('dateElementProperties', {})
                    ts = dep.get('timestamp', '')
                    if ts:
                        current_date = ts[:10]
                    elif dep.get('displayText'):
                        current_date = dep['displayText']

        full_text = ''
        has_strike = False
        for e in elements:
            if 'textRun' in e:
                tr = e['textRun']
                full_text += tr.get('content', '')
                if tr.get('textStyle', {}).get('strikethrough'):
                    has_strike = True

        nest = para.get('bullet', {}).get('nestingLevel', 0)
        paras.append({'text': full_text.strip(), 'nest': nest, 'date': current_date, 'strike': has_strike, 'heading_id': current_heading_id})

    # Pass 2: find action items and collect sub-lists
    for i, p in enumerate(paras):
        if not any(pat.search(p['text']) for pat in patterns):
            continue

        text = p['text']
        for sp in strip_patterns:
            text = sp.sub('', text)
        text = text.strip()
        if not text or len(text) < 3:
            continue
        if p['date'] and p['date'] < cutoff_date:
            continue

        # Collect sub-items (deeper nesting immediately following)
        base_nest = p['nest']
        sub_items = []
        for j in range(i + 1, len(paras)):
            sub = paras[j]
            if sub['nest'] <= base_nest:
                break
            if sub['text']:
                sub_items.append('- ' + sub['text'])

        full_text = text
        if sub_items:
            full_text += '\n' + '\n'.join(sub_items)

        all_items.append({
            'doc_id': doc_id,
            'doc_name': doc_name,
            'text': full_text[:500],
            'date': p['date'],
            'completed': p['strike'],
            'heading_id': p.get('heading_id') or '',
            'ai_summary': ''
        })

# Deduplicate: same text across multiple dates -> keep most recent
seen = {}
for item in all_items:
    key = (item['doc_id'], item['text'][:100])
    if key not in seen or (item['date'] or '') > (seen[key]['date'] or ''):
        seen[key] = item
deduped = sorted(seen.values(), key=lambda x: (x['completed'], x.get('date') or ''), reverse=True)

print(json.dumps(deduped))
PYTHON_SCRIPT
