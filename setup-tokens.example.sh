#!/bin/bash
# Activity Monitor — Token & Config Setup
#
# This script sets environment variables needed by the activity-monitor skill.
# The values stay LOCAL — they are never sent to the LLM because the shell
# expands them before any command output reaches the AI.
#
# SETUP:
#   1. Copy this file OUTSIDE the repo:
#        cp setup-tokens.example.sh ~/ocmui-tokens.sh
#
#   2. Edit ~/ocmui-tokens.sh and fill in your values below
#
#   3. Add to your shell config (~/.bashrc or ~/.zshrc):
#        source ~/ocmui-tokens.sh
#
#   4. Restart your terminal (or run: source ~/.bashrc)
#
# WHERE TO GET TOKENS:
#   GitHub: https://github.com/settings/tokens (or just use `gh auth login`)
#   Jira:   https://id.atlassian.com/manage-profile/security/api-tokens
#
# WARNING: Never commit this file with real tokens!

# ============================================================
# REQUIRED — Fill in your values
# ============================================================

# Your GitHub username
export GITHUB_USER="<your-github-username>"

# The GitHub repo to monitor (org/repo format)
export GITHUB_REPO="RedHatInsights/uhc-portal"

# Your Atlassian/Red Hat email for Jira API auth
export JIRA_EMAIL="<your-email>@redhat.com"

# Jira API token (Atlassian Cloud)
export JIRA_TOKEN="<your-jira-api-token>"

# Jira instance hostname (no https://, no trailing slash)
export JIRA_INSTANCE="redhat.atlassian.net"

# Jira project key
export JIRA_PROJECT="OCMUI"

# ============================================================
# OPTIONAL
# ============================================================

# GitHub token — only needed if you don't use `gh auth login`
# export GITHUB_TOKEN="<your-github-token>"

# ============================================================
# VERIFICATION — run this script directly to check your setup
# ============================================================
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    echo "Activity Monitor — Token Verification"
    echo "======================================"
    echo ""

    check_var() {
        local var_name=$1
        local var_value="${!var_name}"
        if [[ -z "$var_value" || "$var_value" == "<"* ]]; then
            echo "  ❌ $var_name: NOT SET (still placeholder)"
        else
            echo "  ✅ $var_name: Set (${#var_value} chars)"
        fi
    }

    echo "Required:"
    check_var "GITHUB_USER"
    check_var "GITHUB_REPO"
    check_var "JIRA_EMAIL"
    check_var "JIRA_TOKEN"
    check_var "JIRA_INSTANCE"
    check_var "JIRA_PROJECT"

    echo ""
    echo "Optional:"
    check_var "GITHUB_TOKEN"

    echo ""
    echo "To use these, add to your ~/.bashrc or ~/.zshrc:"
    echo "  source ~/ocmui-tokens.sh"
    echo ""
    echo "Then restart your terminal or run: source ~/.bashrc"
fi
