# Activity Monitor — Cleanup Roadmap

Codebase audit as of 2026-09-10. Total: **3,632 lines** across 4 files.

| File | Lines | Role |
|------|------:|------|
| `gather.sh` | 1,378 | Data collection (GitHub + Jira + Google Docs APIs) |
| `ACTIVITY_MONITOR.html` | 1,047 | Single-file HTML/CSS/JS dashboard |
| `SKILL.md` | 803 | Agent instructions for running the skill |
| `assemble.py` | 404 | JSON assembly + status badge generation |

---

## P0 — Dead Code & Legacy Remnants

### 1. ~~`age_label()` is dead code in `assemble.py`~~ ✅ DONE

Removed in quick-wins pass (2026-09-10).

### 2. ~~`prev_prs` loop body is `pass` in `assemble.py`~~ ✅ DONE

Removed in quick-wins pass (2026-09-10).

### 3. `jira_activity` assembled but never rendered in HTML

`assemble.py` line 162–163 parses `JIRA_TICKET_ACTIVITY` into `jira_activity`
and writes it to `activity-data.js`. The HTML never reads `D.jira_activity`.
This is ~50 lines of gather.sh (lines 1086–1137) + assembly code collecting
data nobody sees.

**Options:**
- A) Remove entirely if the Jira tab doesn't need per-ticket changelog data
- B) Wire it into the HTML if it was intended but never finished

### 4. `parent_alignment` assembled but never rendered directly

`assemble.py` builds `parent_alignment` (lines 188–198) and writes it to the
data file, but the HTML only uses `parent_comments` and the `parent_target_end`
merged into epics. The `parent_alignment` object itself (with `date_mismatch`,
`near_due`, `parent_status`) is unused in the HTML.

The data IS used indirectly — `parent_target_end` is merged into epics at
line 201–204 — but the standalone object is dead weight in the JS payload.

### 5. ~~`window.ACTIVITY_DATA` comment in `assemble.py`~~ ✅ DONE

Fixed in quick-wins pass (2026-09-10).

### 6. ~~`pr.pop('ai_summary', None)` in `assemble.py`~~ ✅ DONE

Removed in quick-wins pass (2026-09-10).

### 6b. ~~Dead `PR_ACTIVITY` section in `gather.sh`~~ ✅ DONE

Removed in quick-wins pass (2026-09-10).

### 6c. ~~Unused `BOTS` bash variable in `gather.sh`~~ ✅ DONE

Removed in quick-wins pass (2026-09-10).

---

## P1 — gather.sh Architecture (1,378 lines)

### 7. Massive inline Python blocks make the script unmaintainable

`gather.sh` is a bash script that embeds **~900 lines of Python** via heredocs
and `-c` strings. The Python blocks handle:
- Jira response parsing (ADF → plain text, comment extraction, changelog parsing)
- GitHub PR status aggregation (review state machines, team matching)
- GraphQL response processing

**Problem:** These Python blocks are unindented, untestable, and invisible to
linters. A typo in an embedded Python string fails silently at runtime.

**Recommendation:** Extract into standalone Python modules:
```
scripts/
  gather.sh          → orchestrator (curl/gh calls, section headers)
  lib/
    parse_jira.py    → ADF parsing, comment extraction, changelog
    parse_github.py  → PR status, review state machine, team matching
    parse_actions.py → Google Docs action item scanning
```

`gather.sh` would pipe API responses through these modules:
```bash
gh api ... | python3 scripts/lib/parse_github.py pr_status "$GITHUB_USER" "$MY_TEAMS"
```

### 8. Duplicated review state machine (PR_STATUS vs CHILD_PR_STATUS)

The review state aggregation logic is copy-pasted
between the PR_STATUS and CHILD_PR_STATUS sections. Both:
1. Paginate reviews, build `reviewer_state` dict
2. Handle APPROVED/CHANGES_REQUESTED/COMMENTED/DISMISSED transitions
3. Add requested reviewers, reset re-requested to pending
4. Upgrade pending→commented from issue comments

**Update (2026-09-11):** Team-based reviewer injection removed from both
sections (`via_team`, `MY_TEAMS`, `requested_teams` all deleted). Logic is
simpler now but still duplicated.

A single `resolve_reviewers(pr_num, repo, github_user)` function
would eliminate ~100 lines of duplication and ensure fixes apply to both paths.

### 9. Duplicated ADF→text extraction

The Jira ADF (Atlassian Document Format) → plain text extraction pattern appears
**5 times** across gather.sh (ALL_EPICS, PARENT_EPIC_STATUS, EPIC_CHILDREN,
SIBLINGS, JIRA_MENTIONS). Each is a slightly different inline implementation.

Extract to a shared `extract_adf_text(node)` function.

### 10. Duplicated BOT_AUTHORS filtering

`BOT_AUTHORS = {'App SRE Jira bot', 'Jira Bot', 'Automation for Jira'}` is
defined **4 times** in separate Python blocks. Same for GitHub bot filtering
(`codecov[bot]`, `coderabbitai[bot]`, etc.) which appears **3 times**.

### 11. Three redundant Jira queries for the same epic list

These three sections each independently query the same set of OCMUI epics:
- `PARENT_EPIC_STATUS` (line 457)
- `EPIC_CHILDREN` (line 652)
- `SIBLINGS` (line 977)

Each does:
```bash
curl ... "jql=project = OCMUI AND issuetype = Epic AND status in (...)"
```

This wastes 2 API calls. Fetch once, pipe the epic keys to all three sections.

### 12. Sleep statements are arbitrary

`sleep 2` appears 3 times (lines 87, 134, 231). These were added reactively
to avoid rate limits but aren't calibrated. Consider:
- Checking `gh api rate_limit` and sleeping only when needed
- Or using exponential backoff on 429 responses

---

## P2 — ACTIVITY_MONITOR.html (1,047 lines)

### 13. All CSS/JS/HTML in one file

The entire dashboard is a single 1,047-line file mixing:
- ~120 lines of CSS (lines 3–120)
- ~900 lines of JavaScript (lines 122–1040)
- ~25 lines of HTML shell

**Recommendation:** Keep it as a single file (it's a local tool, not a deployed
app), but organize the JS into clearly separated sections with banner comments:
```javascript
// ═══════════════════════════════════════════════════
// DATA RENDERING
// ═══════════════════════════════════════════════════
```

### 14. `renderPRTable()` is 130+ lines with mixed concerns

This single function (lines ~375–510) handles:
- Table header generation
- Row rendering with reviewer badges
- Comment sub-rows with pagination
- "Load more" button logic
- Date formatting

Break into: `renderPRTableHeader()`, `renderPRRow()`, `renderPRComments()`.

### 15. Inline styles scattered throughout

Many elements use inline `style="..."` attributes instead of CSS classes:
- Section title buttons (font-weight, font-size, cursor, margin-left)
- Comment table cells (padding, vertical-align, color)
- Draft toggle buttons

These should be CSS classes for maintainability.

### 16. Sprint board section documented in SKILL.md but never built

SKILL.md (lines 322–326) describes a "My Current Sprint" kanban board feature:
```
### My Current Sprint — <Sprint Name>
    (show "Remaining Sprint Days: N" next to heading)
    (kanban board: columns for To Do, In Progress, Code Review, QE Review, Done)
```

This was never implemented in the HTML. Either build it or remove the
documentation to avoid confusion.

---

## P3 — SKILL.md Drift (803 lines)

### 17. ~~Variable name mismatch: `window.ACTIVITY_DATA` vs `const D`~~ ✅ DONE

Fixed in quick-wins pass (2026-09-10).

### 18. ~~PR table columns documentation doesn't match implementation~~ ✅ DONE

Fixed in quick-wins pass (2026-09-10).

### 19. ~~Stale "Senior Staff PRs" removal may have left orphan references~~ ✅ DONE

Senior Staff PRs section, `via_team` logic, `MY_TEAMS` pre-fetch, and
`requested_teams` API calls all removed (2026-09-11). Search query changed
from `review-requested:` to `user-review-requested:` to exclude team requests
at the source. SKILL.md references cleaned.

### 20. Manual queries section (lines 537–601) is largely obsolete

The "Manual Queries (Fallback)" section provides raw curl/gh commands for
manual data gathering. These were useful before `gather.sh` existed but are
now maintenance overhead — they drift from the actual gather.sh queries.

**Options:**
- A) Remove entirely (gather.sh is the source of truth)
- B) Keep but add a "⚠️ May be outdated" warning

### 21. Chat Output Format section may be stale

The "Chat Output Format" section (lines 97–190) describes how the agent should
present the summary in chat. This should be audited against actual recent chat
outputs to ensure the format instructions match current practice (e.g., do we
still use `=== Section Title ===` headers?).

---

## P4 — Performance & Reliability

### 22. gather.sh makes 60-80 API calls per run

A rough count:
- GitHub: ~8 search queries + N×4 calls per PR (details, reviews, comments, checks) + N×4 per child PR
- Jira: 7 queries + N parent fetches + N parent comment fetches
- Google Docs: variable

For 15 PRs + 13 child PRs + 26 epics, this is ~120 API calls. Each run
takes 4+ minutes. Consider:
- Caching PR status that hasn't changed (compare `head_sha`)
- Batching GitHub GraphQL queries (one query can fetch multiple PRs)
- Parallel API calls within sections (background subshells)

### 23. No error recovery for partial failures

If a section fails mid-way (e.g., rate limit on the 5th PR in PR_STATUS),
the entire section output is corrupted. The `set -euo pipefail` at the top
means the script exits on first error.

**Recommendation:** Wrap each section in error-tolerant blocks and output
partial results rather than dying.

### 24. assemble.py `load_previous_ai()` is fragile

The function (lines 131–143) uses `content.index('{')` and
`content.rindex('}')` to find JSON boundaries. This breaks if:
- The file has `{` in a comment before the data
- The JSON itself contains unbalanced braces in string values

Use the known prefix (`const D = `) to find the start instead.

---

## Recommended Execution Order

| Phase | Items | Effort | Impact |
|-------|-------|--------|--------|
| ~~**Quick wins**~~ | ~~#1, #2, #5, #6, #6b, #6c, #17, #18, #19~~ | ~~30 min~~ | ✅ Done |
| **Dedup** | #8, #9, #10, #11 | 2–3 hrs | Extract shared functions, reduce gather.sh by ~200 lines |
| **Architecture** | #7 | 4–6 hrs | Extract Python modules from gather.sh |
| **HTML cleanup** | #14, #15 | 1–2 hrs | Better code organization |
| **SKILL.md audit** | #16, #20, #21 | 1 hr | Remove stale docs |
| **Performance** | #22, #23, #24 | 4–6 hrs | Caching, batching, error recovery |
| **Dead features** | #3, #4 | 30 min | Remove or wire up unused data |
