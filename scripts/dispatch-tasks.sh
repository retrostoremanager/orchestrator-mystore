#!/usr/bin/env bash
set -euo pipefail

ORCHESTRATOR_REPO="${ORCHESTRATOR_REPO:?}"
GH_TOKEN="${GH_TOKEN:?}"          # built-in token for this repo (issues)
DISPATCH_TOKEN="${DISPATCH_TOKEN:?}" # PAT for cross-repo dispatch

echo "Scanning for ready tasks in $ORCHESTRATOR_REPO..."

issues=$(gh issue list \
  --repo "$ORCHESTRATOR_REPO" \
  --label ready \
  --state open \
  --json number,title,body,labels \
  --limit 5)

count=$(echo "$issues" | jq length)
echo "Found $count ready task(s)"

if [ "$count" -eq 0 ]; then
  echo "Nothing to do."
  exit 0
fi

echo "$issues" | jq -c '.[]' | while read -r issue; do
  number=$(echo "$issue" | jq -r '.number')
  title=$(echo "$issue" | jq -r '.title')
  body=$(echo "$issue" | jq -r '.body // ""')

  target_repo=$(echo "$issue" | jq -r '.labels[].name' | grep '^repo:' | head -1 | sed 's/repo://')

  if [ -z "$target_repo" ]; then
    echo "Issue #$number has no repo: label - skipping"
    continue
  fi

  echo "Dispatching issue #$number ('$title') to $target_repo..."

  owner=$(echo "$ORCHESTRATOR_REPO" | cut -d'/' -f1)

  read -r -d '' prompt << PROMPT || true
Task from RetroStoreManager Kanban.

Issue #${number} in ${ORCHESTRATOR_REPO}: ${title}

${body}

Instructions:
1. Read CLAUDE.md and AGENTS.md for coding standards before making any changes.
2. Create a feature branch feature/issue-${number} off the development branch.
3. Implement the task following all project conventions.
4. Run dotnet build MyStore.sln and dotnet test MyStore.Tests/MyStore.Tests.csproj.
5. Open a pull request targeting the development branch.
6. PR title: ${title}. PR body must include: Closes ${ORCHESTRATOR_REPO}#${number}
PROMPT

  gh issue edit "$number" \
    --repo "$ORCHESTRATOR_REPO" \
    --remove-label ready \
    --add-label in-progress

  GH_TOKEN="$DISPATCH_TOKEN" gh api "repos/${owner}/${target_repo}/dispatches" \
    --method POST \
    --field event_type=claude-agent \
    --field "client_payload[prompt]=${prompt}" \
    --field "client_payload[branch]=development" \
    --field "client_payload[issue_number]=${number}" \
    --field "client_payload[issue_repo]=${ORCHESTRATOR_REPO}"

  echo "Dispatched issue #$number to $target_repo"
done
