#!/usr/bin/env bash
# PostToolUse hook on the Atlassian transitionJiraIssue tool. The tool can report success while the issue keeps its old
# status, so after every transition the agent is told to re-read it and retry once. Advisory only: it prints context for
# the agent and always exits 0, so a fault here never blocks a call.
set -u
trap 'exit 0' ERR

IFS= read -r -d '' input || true

key=""
if [[ $input =~ \"issueIdOrKey\"[[:space:]]*:[[:space:]]*\"([A-Za-z0-9_-]+)\" ]]; then
    key=${BASH_REMATCH[1]}
fi
issue=${key:-the issue}

printf '{"hookSpecificOutput":{"hookEventName":"PostToolUse","additionalContext":"%s"}}\n' \
    "Jira transitions can report success without changing the status. Re-read the status of $issue with getJiraIssue now. If it is unchanged, retry transitionJiraIssue once and re-read again; if it is still unchanged, report $issue as not transitioned."
exit 0
