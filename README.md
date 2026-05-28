# Activity Monitor

A Cursor AI skill that generates a consolidated status report of your GitHub PR activity and Jira epic progress. It produces an interactive HTML dashboard showing:

- **GitHub PRs** — your open PRs and PRs you're reviewing, with reviewer status, CI checks, merge state, and AI-synthesized summaries
- **Jira Epics** — all your active epics with child stories, parent alignment, sibling epics, target dates, and urgency indicators
- **AI Summaries** — synthesized insights including "ball in court" tracking, age indicators, and cross-section uber summaries per epic

## Prerequisites

| Requirement | Details |
|-------------|---------|
| `gh` CLI | Authenticated with `repo` and `read:org` scopes |
| Jira API token | Personal API token from https://id.atlassian.com/manage-profile/security/api-tokens |
| Environment variables | `JIRA_EMAIL` and `JIRA_TOKEN` |
| Cursor IDE | With agent skills enabled |

## Setup

### 1. Clone this repo

```bash
git clone <repo-url>
cd AI/activity-monitor
```

### 2. Install the skill in Cursor

Cursor looks for skills in `~/.cursor/skills/`. Create a symlink so Cursor can find it:

```bash
mkdir -p ~/.cursor/skills
ln -s "$(pwd)" ~/.cursor/skills/activity-monitor
```

Alternatively, copy the directory:
```bash
cp -r . ~/.cursor/skills/activity-monitor
```

The key files Cursor needs:
| File | Location | Purpose |
|------|----------|---------|
| `SKILL.md` | `~/.cursor/skills/activity-monitor/SKILL.md` | Tells the AI agent what this skill does and how to run it |
| `scripts/gather.sh` | `~/.cursor/skills/activity-monitor/scripts/gather.sh` | Data collection script the agent executes |
| `ACTIVITY_MONITOR.html` | Same directory (or anywhere you like) | Open in browser to view the dashboard |
| `activity-data.js` | Same directory as the HTML | Generated each run — the HTML loads this |

### 3. Set environment variables

Add to `~/.bashrc` or `~/.zshrc`:

```bash
export JIRA_EMAIL="you@redhat.com"
export JIRA_TOKEN="your-atlassian-api-token"
```

Get a Jira API token from: https://id.atlassian.com/manage-profile/security/api-tokens

### 4. Authenticate `gh` CLI

```bash
gh auth login
```

### 5. Personalize the config

**Edit `SKILL.md`** — update these values near the top:
- `GitHub user: dtaylor113` → your GitHub username
- `Jira instance: redhat.atlassian.net` → your Jira instance (if different)
- `Repo: RedHatInsights/uhc-portal` → your repo (if different)

**Edit `scripts/gather.sh`** — update:
- `GITHUB_USER="dtaylor113"` → your GitHub username
- `REPO="RedHatInsights/uhc-portal"` → your repo (if different)
- The Jira `project = OCMUI` in JQL queries → your project key (if different)

## Usage

Ask your Cursor agent any of:
- "Run the activity monitor"
- "What's new?"
- "Morning briefing"
- "Check my notifications"
- "Status update"

The agent will:
1. Run `scripts/gather.sh` to collect data from GitHub and Jira APIs
2. Assemble the data into `activity-data.js`
3. Generate AI summaries for each section
4. Write `activity-data.js` alongside the HTML

Then open `ACTIVITY_MONITOR.html` in a browser to view the dashboard.

## File Structure

```
activity-monitor/
├── README.md              # This file
├── SKILL.md               # Agent instructions (how the AI runs the skill)
├── ACTIVITY_MONITOR.html  # Static HTML template (rarely changes)
├── scripts/
│   └── gather.sh          # Data collection script (GitHub + Jira APIs)
├── activity-data.js       # Generated data (gitignored)
└── .gitignore
```

## How It Works

1. **`gather.sh`** makes API calls to GitHub and Jira, outputting structured JSON sections
2. The Cursor agent parses that output and assembles `activity-data.js`
3. The agent writes AI summaries by reading comments and synthesizing insights
4. **`ACTIVITY_MONITOR.html`** loads `activity-data.js` and renders everything client-side

The HTML is a self-contained single-page app — no build step, no server, no dependencies.

## Customization

- **Jira project**: Change `OCMUI` in gather.sh JQL queries
- **Epic filter**: The default JQL fetches epics assigned to you or where you're a watcher
- **Comment depth**: Currently fetches last 8 unresolved non-bot comments per PR
- **Lookback period**: Default 3 days for PR activity, configurable via `--since` flag
