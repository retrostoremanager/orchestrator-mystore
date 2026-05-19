#!/usr/bin/env bash
set -euo pipefail

ORCHESTRATOR_REPO="${ORCHESTRATOR_REPO:?}"
GH_TOKEN="${GH_TOKEN:?}"          # built-in token for this repo (issues)
DISPATCH_TOKEN="${DISPATCH_TOKEN:?}" # PAT for cross-repo dispatch
TRIGGER_EVENT="${TRIGGER_EVENT:-workflow_dispatch}"

# Issues stuck in-progress longer than this are considered failed/abandoned.
# Must exceed the agent timeout (30m) + one orchestrator cycle (6h) + buffer.
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
# Skip on label events — those fire instantly and stale recovery adds no value.
# Only run on schedule (every 6h) or manual workflow_dispatch.
# ════════════════════════════════════════════════════════════════════════════
if [ "$TRIGGER_EVENT" = "issues" ]; then
  echo "Triggered by label event — skipping stale recovery (only runs on schedule)."
else
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

  # Skip if already marked done (contradictory labels — remove in-progress and move on)
  has_done=$(echo "$issue" | jq -r '[.labels[].name] | any(. == "done")')
  if [ "$has_done" = "true" ]; then
    echo "Issue #$number already has done label — removing in-progress"
    gh issue edit "$number" --repo "$ORCHESTRATOR_REPO" --remove-label in-progress
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

  # Count how many times this issue has already been retried
  retry_count=$(echo "$issue" | jq -r '[.labels[].name | select(startswith("retry-"))] | length')
  next_retry=$((retry_count + 1))

  # Hard stop at 3 retries — mark agent-failed; STEP 3 will retry it at lower priority
  if [ "$retry_count" -ge 3 ]; then
    echo "Issue #$number: hit retry cap ($retry_count retries) — marking agent-failed"
    gh issue edit "$number" \
      --repo "$ORCHESTRATOR_REPO" \
      --remove-label in-progress \
      --add-label agent-failed
    gh issue comment "$number" \
      --repo "$ORCHESTRATOR_REPO" \
      --body "Agent has failed **$retry_count** times on this issue (likely quota exhaustion). Marking as **agent-failed** — will be retried automatically at lower priority once quota is restored."
    continue
  fi

  branch="feature/issue-${number}"

  if branch_exists "$target_repo" "$branch"; then
    echo "Issue #$number: branch $branch exists — dispatching resume agent (retry $next_retry/3)"

    gh issue edit "$number" \
      --repo "$ORCHESTRATOR_REPO" \
      --add-label "retry-$next_retry"

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

    jq -n --arg prompt "$prompt" --arg branch "$branch" \
      '{"ref":"main","inputs":{"prompt":$prompt,"branch":$branch}}' | \
    GH_TOKEN="$DISPATCH_TOKEN" gh api \
      "repos/${owner}/${target_repo}/actions/workflows/claude-code.yml/dispatches" \
      --method POST --input -

    echo "Dispatched resume for issue #$number to $target_repo (branch: $branch)"

  else
    echo "Issue #$number: no branch found — resetting to ready (retry $next_retry/3)"
    gh issue edit "$number" \
      --repo "$ORCHESTRATOR_REPO" \
      --remove-label in-progress \
      --add-label ready \
      --add-label "retry-$next_retry"
    gh issue comment "$number" \
      --repo "$ORCHESTRATOR_REPO" \
      --body "Previous agent run failed before creating a branch (retry $next_retry/3). Resetting to **ready** for another attempt."
  fi
done
fi  # end of stale recovery block (skipped on label events)

# ════════════════════════════════════════════════════════════════════════════
# STEP 2 — Replenish backlog if running low
# ════════════════════════════════════════════════════════════════════════════
BACKLOG_THRESHOLD=3

open_count=$(gh issue list \
  --repo "$ORCHESTRATOR_REPO" \
  --state open \
  --json number,labels \
  --jq '[.[] | select(.labels | map(.name) | any(. == "ready" or . == "in-progress"))] | length' \
  2>/dev/null || echo "99")

echo "Open issues (ready + in-progress): $open_count"

if [ "${open_count:-99}" -lt "$BACKLOG_THRESHOLD" ]; then
  echo "Backlog below threshold ($BACKLOG_THRESHOLD) — triggering backlog generation"
  bash "$(dirname "$0")/generate-backlog.sh" || echo "Backlog generation dispatch failed (non-fatal)"
fi

# ════════════════════════════════════════════════════════════════════════════
# STEP 3 — Dispatch next ready task (sequential — one at a time)
# ════════════════════════════════════════════════════════════════════════════
echo "Checking pipeline state..."

active_count=$(gh issue list \
  --repo "$ORCHESTRATOR_REPO" \
  --state open \
  --json labels \
  --jq '[.[] | select(.labels | map(.name) | any(. == "in-progress" or . == "code-review" or . == "in-test"))] | length' \
  2>/dev/null || echo "0")

if [ "${active_count:-0}" -gt 0 ]; then
  echo "Pipeline active ($active_count issue(s) in flight)"

  in_test_number=$(gh issue list \
    --repo "$ORCHESTRATOR_REPO" \
    --label in-test \
    --state open \
    --json number \
    --jq '.[0].number // empty' \
    2>/dev/null || true)

  if [ -z "$in_test_number" ]; then
    echo "No in-test issue — waiting for in-progress/code-review work to complete."
    exit 0
  fi

  echo "Issue #$in_test_number is in-test — checking for linked ready bug fixes..."

  linked_bugs=$(gh issue list \
    --repo "$ORCHESTRATOR_REPO" \
    --label ready \
    --label bug \
    --state open \
    --json number,title,body,labels \
    --limit 10 \
    --jq "[.[] | select(.body | contains(\"orchestrator-mystore#${in_test_number}\"))]")

  bug_count=$(echo "$linked_bugs" | jq length)

  if [ "$bug_count" -eq 0 ]; then
    echo "No linked bug fixes ready — waiting for issue #$in_test_number to complete."
    exit 0
  fi

  echo "Found $bug_count linked bug fix(es) for issue #$in_test_number — dispatching first"
  issues="$linked_bugs"
else
  echo "Pipeline clear — picking next ready task..."

  ready_issues=$(gh issue list \
    --repo "$ORCHESTRATOR_REPO" \
    --label ready \
    --state open \
    --json number,title,body,labels \
    --limit 10)

  failed_issues=$(gh issue list \
    --repo "$ORCHESTRATOR_REPO" \
    --label agent-failed \
    --state open \
    --json number,title,body,labels \
    --limit 10)

  issues=$(jq -s '
    (.[0] + .[1]) | unique_by(.number) |
    sort_by(
      if (.labels | map(.name) | any(. == "priority:high")) then 0
      elif (.labels | map(.name) | any(. == "agent-failed")) then 1
      else 2
      end
    )
  ' <(echo "$ready_issues") <(echo "$failed_issues"))
fi

count=$(echo "$issues" | jq length)
echo "Found $count ready task(s)"

if [ "$count" -eq 0 ]; then
  echo "Nothing to dispatch."
  exit 0
fi

# Dispatch exactly one at a time
dispatched=0

echo "$issues" | jq -c '.[]' | while read -r issue; do
  if [ "$dispatched" -ge 1 ]; then
    break
  fi

  number=$(echo "$issue" | jq -r '.number')
  title=$(echo "$issue" | jq -r '.title')
  body=$(echo "$issue" | jq -r '.body // ""')
  is_bug=$(echo "$issue" | jq -r '[.labels[].name] | any(. == "bug")')
  is_priority=$(echo "$issue" | jq -r '[.labels[].name] | any(. == "priority:high")')
  is_failed=$(echo "$issue" | jq -r '[.labels[].name] | any(. == "agent-failed")')

  target_repo=$(echo "$issue" | jq -r '.labels[].name' | grep '^repo:' | head -1 | sed 's/repo://')

  if [ -z "$target_repo" ]; then
    echo "Issue #$number has no repo: label - skipping"
    continue
  fi

  priority_tag=""
  if [ "$is_priority" = "true" ]; then
    priority_tag=" [PRIORITY]"
  fi
  echo "Dispatching issue #$number ('$title')${priority_tag} to $target_repo..."

  if [ "$target_repo" = "fn-mystore" ]; then
    build_cmd="dotnet build MyStore.sln && dotnet test MyStore.Tests/MyStore.Tests.csproj"
  else
    build_cmd="npm install && npm run build && npm test -- --run"
  fi

  if [ "$is_bug" = "true" ]; then
    task_type="Bug fix"
    task_note="This is a confirmed bug found by the QA testing agent after deployment to dev. Fix the specific issue described — do not add unrelated changes."
  else
    task_type="Feature task"
    task_note=""
  fi

  read -r -d '' prompt << PROMPT || true
${task_type} from RetroStoreManager Kanban.

Issue #${number} in ${ORCHESTRATOR_REPO}: ${title}

${body}

${task_note}

Instructions:
1. Read CLAUDE.md for coding standards and file map before making any changes.
2. Create a feature branch feature/issue-${number} off the development branch.
3. Implement the task following all project conventions.
4. Run: ${build_cmd}
5. Open a pull request targeting the development branch.
6. PR title: ${title}. PR body must include: Closes ${ORCHESTRATOR_REPO}#${number}
PROMPT

  if [ "$is_failed" = "true" ]; then
    # Clear agent-failed and reset retry labels so stale recovery starts fresh
    gh issue edit "$number" \
      --repo "$ORCHESTRATOR_REPO" \
      --remove-label agent-failed \
      --add-label in-progress
    for n in 1 2 3; do
      gh issue edit "$number" --repo "$ORCHESTRATOR_REPO" --remove-label "retry-$n" 2>/dev/null || true
    done
  else
    gh issue edit "$number" \
      --repo "$ORCHESTRATOR_REPO" \
      --remove-label ready \
      --add-label in-progress
  fi

  jq -n --arg prompt "$prompt" \
    '{"ref":"main","inputs":{"prompt":$prompt,"branch":"development"}}' | \
  GH_TOKEN="$DISPATCH_TOKEN" gh api \
    "repos/${owner}/${target_repo}/actions/workflows/claude-code.yml/dispatches" \
    --method POST --input -

  echo "Dispatched issue #$number to $target_repo"
  dispatched=$((dispatched + 1))
done
