#!/usr/bin/env bash
set -euo pipefail

ORCHESTRATOR_REPO="${ORCHESTRATOR_REPO:?}"
GH_TOKEN="${GH_TOKEN:?}"          # built-in token for this repo (issues)
DISPATCH_TOKEN="${DISPATCH_TOKEN:?}" # PAT for cross-repo dispatch
TRIGGER_EVENT="${TRIGGER_EVENT:-workflow_dispatch}"

# Issues stuck in-progress longer than this are considered failed/abandoned.
# Must exceed the agent timeout (30m) + one orchestrator cycle (6h) + buffer.
STALE_THRESHOLD_SECONDS=21600  # 6 hours

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
# STEP 0 — Clear expired cap-wait labels and re-trigger stalled stages
# ════════════════════════════════════════════════════════════════════════════
cap_wait_issues=$(gh issue list \
  --repo "$ORCHESTRATOR_REPO" \
  --label cap-wait \
  --state open \
  --json number,labels \
  --limit 10 \
  2>/dev/null || echo "[]")

echo "$cap_wait_issues" | jq -c '.[]' | while read -r issue; do
  number=$(echo "$issue" | jq -r '.number')

  reset_iso=$(gh issue view "$number" --repo "$ORCHESTRATOR_REPO" --json comments \
    --jq '[.comments[] | select(.body | contains("RESET_ISO:"))] | last | .body' \
    2>/dev/null | grep -oP 'RESET_ISO: \K\S+' || true)

  if [ -n "$reset_iso" ]; then
    reset_epoch=$(date -d "$reset_iso" +%s 2>/dev/null || echo "0")
    current_epoch=$(date +%s)
    if [ "$current_epoch" -lt "$reset_epoch" ]; then
      remaining=$(( (reset_epoch - current_epoch) / 60 ))
      echo "Issue #$number: cap-wait active for ${remaining}m more — skipping"
      continue
    fi
  fi

  echo "Issue #$number: cap-wait expired — clearing label"
  gh issue edit "$number" --repo "$ORCHESTRATOR_REPO" --remove-label "cap-wait"

  # If in-test, re-trigger the test agent (in-progress will be handled by STEP 1 stale recovery)
  has_in_test=$(echo "$issue" | jq -r '[.labels[].name] | any(. == "in-test")')
  if [ "$has_in_test" = "true" ]; then
    target_repo=$(echo "$issue" | jq -r '[.labels[].name | select(startswith("repo:"))] | first // empty' | sed 's/repo://')
    if [ -n "$target_repo" ]; then
      pr_number=$(GH_TOKEN="$DISPATCH_TOKEN" gh pr list \
        --repo "${owner}/${target_repo}" \
        --state merged \
        --json number,body \
        --jq "[.[] | select(.body | contains(\"orchestrator-mystore#${number}\"))] | .[0].number // empty" \
        2>/dev/null || true)
      if [ -n "$pr_number" ] && [ "$pr_number" != "null" ]; then
        GH_TOKEN="$DISPATCH_TOKEN" gh workflow run test-agent.yml \
          --repo "${owner}/${target_repo}" --ref main \
          -f pr_numbers="$pr_number" \
          -f target_repo="$target_repo" \
          -f orchestrator_issues="$number"
        echo "Re-triggered test agent for issue #$number (PR #$pr_number)"
      else
        echo "Issue #$number: in-test but no merged PR found — skipping test re-trigger"
      fi
    fi
  fi

  # If code-review, re-trigger the code review workflow
  has_code_review=$(echo "$issue" | jq -r '[.labels[].name] | any(. == "code-review")')
  if [ "$has_code_review" = "true" ]; then
    target_repo=$(echo "$issue" | jq -r '[.labels[].name | select(startswith("repo:"))] | first // empty' | sed 's/repo://')
    if [ -n "$target_repo" ]; then
      pr_data=$(GH_TOKEN="$DISPATCH_TOKEN" gh pr list \
        --repo "${owner}/${target_repo}" --state open \
        --json number,headRefName,body \
        --jq "[.[] | select(.body | contains(\"orchestrator-mystore#${number}\"))] | .[0] // empty" \
        2>/dev/null || echo "")
      if [ -n "$pr_data" ] && [ "$pr_data" != "null" ] && [ "$pr_data" != "" ]; then
        pr_number=$(echo "$pr_data" | jq -r '.number')
        head_branch=$(echo "$pr_data" | jq -r '.headRefName')
        GH_TOKEN="$DISPATCH_TOKEN" gh workflow run code-review.yml \
          --repo "${owner}/${target_repo}" --ref main \
          -f pr_number="$pr_number" \
          -f head_branch="$head_branch"
        echo "Re-triggered code review for issue #$number (PR #$pr_number)"
      else
        echo "Issue #$number: code-review but no open PR found — resetting to in-progress"
        gh issue edit "$number" --repo "$ORCHESTRATOR_REPO" \
          --remove-label "code-review" --add-label "in-progress"
      fi
    fi
  fi
done

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

  # Skip if waiting for spending cap to reset
  has_cap_wait=$(echo "$issue" | jq -r '[.labels[].name] | any(. == "cap-wait")')
  if [ "$has_cap_wait" = "true" ]; then
    echo "Issue #$number has active cap-wait — skipping stale recovery"
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
4. If the task involves SQL queries: read the relevant schema from retrostoremanager/dbproj-mystore (development branch, PostgreSQL/ directory) — exact column names are there. Use: GH_TOKEN="$GH_DISPATCH_TOKEN" gh api "repos/retrostoremanager/dbproj-mystore/contents/PostgreSQL/<file>?ref=development" --jq '.content' | base64 -d
5. Review the acceptance criteria above and complete any remaining items.
6. Run: dotnet test MyStore.Tests/MyStore.Tests.csproj
7. If all tests pass, open a pull request targeting the development branch.
8. PR title: ${title}. PR body must include: Closes ${ORCHESTRATOR_REPO}#${number}
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

  in_test_issues=$(gh issue list \
    --repo "$ORCHESTRATOR_REPO" \
    --label in-test \
    --state open \
    --json number,labels,updatedAt \
    --limit 20 \
    2>/dev/null || echo "[]")

  in_test_count=$(echo "$in_test_issues" | jq length)

  if [ "$in_test_count" -eq 0 ]; then
    echo "No in-test issues — waiting for in-progress/code-review work to complete."
    exit 0
  fi

  # Check ALL in-test issues for linked ready bug fixes; also find stale ones to re-trigger
  linked_bugs=""
  retest_prs=""
  retest_issues=""
  retest_repo=""

  while IFS= read -r in_test_entry; do
    in_test_number=$(echo "$in_test_entry" | jq -r '.number')
    echo "Checking issue #$in_test_number (in-test) for linked ready bugs..."

    linked=$(gh issue list \
      --repo "$ORCHESTRATOR_REPO" \
      --label ready --label bug --state open \
      --json number,title,body,labels \
      --limit 10 \
      --jq "[.[] | select(.body | contains(\"orchestrator-mystore#${in_test_number}\"))]" \
      2>/dev/null || echo "[]")

    cnt=$(echo "$linked" | jq length)
    if [ "$cnt" -gt 0 ]; then
      echo "Found $cnt bug(s) linked to #$in_test_number — dispatching first"
      linked_bugs="$linked"
      break
    fi

    echo "No linked ready bugs for #$in_test_number"

    # Check if this in-test issue is stale and should have its test re-triggered
    updated_at=$(echo "$in_test_entry" | jq -r '.updatedAt')
    age=$(( $(date +%s) - $(date -d "$updated_at" +%s) ))
    if [ "$age" -gt "$STALE_THRESHOLD_SECONDS" ]; then
      target_repo_raw=$(echo "$in_test_entry" | jq -r '[.labels[].name | select(startswith("repo:"))] | first // empty' | sed 's/repo://')
      if [ -n "$target_repo_raw" ]; then
        pr=$(GH_TOKEN="$DISPATCH_TOKEN" gh pr list \
          --repo "${owner}/${target_repo_raw}" --state merged \
          --json number,body \
          --jq "[.[] | select(.body | contains(\"orchestrator-mystore#${in_test_number}\"))] | .[0].number // empty" \
          2>/dev/null || true)
        if [ -n "$pr" ] && [ "$pr" != "null" ]; then
          if [ -z "$retest_prs" ]; then
            retest_prs="$pr"
            retest_issues="$in_test_number"
            retest_repo="$target_repo_raw"
          else
            retest_prs="${retest_prs},${pr}"
            retest_issues="${retest_issues},${in_test_number}"
          fi
          echo "Issue #$in_test_number is stale ($((age/60))m) — will re-trigger test (PR #$pr)"
        fi
      fi
    fi
  done < <(echo "$in_test_issues" | jq -c '.[]')

  if [ -n "$linked_bugs" ]; then
    issues="$linked_bugs"
  elif [ -n "$retest_prs" ]; then
    echo "Re-triggering stale tests: issues $retest_issues (PRs $retest_prs in $retest_repo)"
    GH_TOKEN="$DISPATCH_TOKEN" gh workflow run test-agent.yml \
      --repo "${owner}/${retest_repo}" --ref main \
      -f pr_numbers="$retest_prs" \
      -f target_repo="$retest_repo" \
      -f orchestrator_issues="$retest_issues"
    echo "Dispatched batched test re-trigger for issues $retest_issues"
    exit 0
  else
    echo "All in-test issues have active linked work — waiting."
    exit 0
  fi
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
2. If the task involves database queries or SQL: read the relevant schema file(s) from retrostoremanager/dbproj-mystore (development branch, PostgreSQL/ directory) before writing any SQL — exact column names are there. Use: GH_TOKEN="$GH_DISPATCH_TOKEN" gh api "repos/retrostoremanager/dbproj-mystore/contents/PostgreSQL/<file>?ref=development" --jq '.content' | base64 -d
3. Create a feature branch feature/issue-${number} off the development branch.
4. Implement the task following all project conventions.
5. Run: ${build_cmd}
6. Open a pull request targeting the development branch.
7. PR title: ${title}. PR body must include: Closes ${ORCHESTRATOR_REPO}#${number}
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
