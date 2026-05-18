#!/usr/bin/env bash
set -euo pipefail

ORCHESTRATOR_REPO="${ORCHESTRATOR_REPO:?}"
GH_TOKEN="${GH_TOKEN:?}"          # built-in token for this repo (issues)
DISPATCH_TOKEN="${DISPATCH_TOKEN:?}" # PAT for cross-repo dispatch

# Issues stuck in-progress longer than this are considered failed/abandoned.
# Must exceed the agent timeout (30m) + one orchestrator cycle (30m) + buffer.
STALE_THRESHOLD_SECONDS=7200  # 2 hours

owner=$(echo "$ORCHESTRATOR_REPO" | cut -d'/' -f1)

# ── Helper: check if an open PR already references an issue ──────────────────
pr_exists_for_issue() {
  local target_repo="$1" issue_number="$2"
  local count
  count=$(GH_TOKEN="$DISPATCH_TOKEN" gh pr list \
    --repo "${owner}/${target_repo}" \
    --state open \
    --json body \
    --jq "[.[] | select(.body | contains(\"orchestrator-mystore#${issue_number}\"))] | length" \
    2>/dev/null || echo "0")
  [ "${count:-0}" -gt 0 ]
}

# ── Helper: check if a branch exists in a target repo ───────────────────────
branch_exists() {
  local target_repo="$1" branch="$2"
  GH_TOKEN="$DISPATCH_TOKEN" gh api \
    "repos/${owner}/${target_repo}/branches/${branch}" \
    --silent 2>/dev/null
}

# ════════════════════════════════════════════════════════════════════════════
# STEP 1 — Recover stale in-progress issues
# ════════════════════════════════════════════════════════════════════════════
echo "Checking for stale in-progress issues..."

stale_issues=$(gh issue list \
  --repo "$ORCHESTRATOR_REPO" \
  --label in-progress \
  --state open \
  --json number,title,body,labels,updatedAt \
  --limit 20)

echo "$stale_issues" | jq -c '.[]' | while read -r issue; do
  number=$(echo "$issue" | jq -r '.number')
  title=$(echo "$issue" | jq -r '.title')
  body=$(echo "$issue" | jq -r '.body // ""')
  updated_at=$(echo "$issue" | jq -r '.updatedAt')
  target_repo=$(echo "$issue" | jq -r '.labels[].name' | grep '^repo:' | head -1 | sed 's/repo://' || true)

  if [ -z "$target_repo" ]; then
    echo "Stale issue #$number has no repo: label - skipping"
    continue
  fi

  # Calculate age in seconds
  age=$(( $(date +%s) - $(date -d "$updated_at" +%s) ))
  if [ "$age" -lt "$STALE_THRESHOLD_SECONDS" ]; then
    echo "Issue #$number has been in-progress for $((age/60))m - still within timeout, skipping"
    continue
  fi

  echo "Issue #$number ('$title') has been in-progress for $((age/60))m - checking recovery options..."

  # Skip if an open PR already references it (agent succeeded, label just wasn't updated)
  if pr_exists_for_issue "$target_repo" "$number"; then
    echo "Issue #$number has an open PR - skipping (label will be updated when PR merges)"
    continue
  fi

  branch="feature/issue-${number}"

  if branch_exists "$target_repo" "$branch"; then
    echo "Issue #$number: branch $branch exists — dispatching resume agent"

    read -r -d '' prompt << PROMPT || true
RESUME incomplete task from RetroStoreManager Kanban.

Issue #${number} in ${ORCHESTRATOR_REPO}: ${title}

${body}

CONTEXT: A previous agent started this task but did not finish (likely hit a spending cap or timed out).
Branch ${branch} already exists in this repo with partial work.

Resume instructions:
1. Check out the existing branch ${branch} — do NOT create a new branch.
2. Run: git log origin/development..HEAD --oneline   to see what was already committed.
3. Run: dotnet build MyStore.sln   to check current build state.
4. Review the acceptance criteria above and complete any remaining items.
5. Run: dotnet test MyStore.Tests/MyStore.Tests.csproj
6. If all tests pass, open a pull request targeting the development branch.
7. PR title: ${title}. PR body must include: Closes ${ORCHESTRATOR_REPO}#${number}
PROMPT

    GH_TOKEN="$DISPATCH_TOKEN" gh api \
      "repos/${owner}/${target_repo}/actions/workflows/claude-code.yml/dispatches" \
      --method POST \
      --field ref=main \
      -f "inputs[prompt]=${prompt}" \
      -f "inputs[branch]=${branch}"

    echo "Dispatched resume for issue #$number to $target_repo (branch: $branch)"

  else
    echo "Issue #$number: no branch found — resetting to ready for fresh attempt"
    gh issue edit "$number" \
      --repo "$ORCHESTRATOR_REPO" \
      --remove-label in-progress \
      --add-label ready
    gh issue comment "$number" \
      --repo "$ORCHESTRATOR_REPO" \
      --body "Previous agent run failed before creating a branch (likely a spending cap). Resetting to **ready** for a fresh attempt."
  fi
done

# ════════════════════════════════════════════════════════════════════════════
# STEP 2 — Dispatch new ready tasks
# ════════════════════════════════════════════════════════════════════════════
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
  echo "Nothing to dispatch."
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

  GH_TOKEN="$DISPATCH_TOKEN" gh api \
    "repos/${owner}/${target_repo}/actions/workflows/claude-code.yml/dispatches" \
    --method POST \
    --field ref=main \
    -f "inputs[prompt]=${prompt}" \
    -f "inputs[branch]=development"

  echo "Dispatched issue #$number to $target_repo"
done
