#!/usr/bin/env bash
# =============================================================================
# orchestrator-template / dispatch-tasks.sh (v0.2)
#
# Parameterized via env vars + config/orchestrator.env (sourced as bash):
#   - ORCH_SLUG       auto-derived from ORCHESTRATOR_REPO (the {repo} part).
#   - TEST_HOST_REPO  workflow env var (set as repo variable).
#   - PROJECT_NAME    config: human-readable project name for prompt headings.
#   - TARGET_BRANCH   config: branch dev agents target ("development" vs "main").
#   - PR_LINK_PHRASE  config: "Closes" vs "Implements" for PR-issue linkage.
#   - BUILD_<REPO>    config: per-target-repo build commands, looked up via
#                     bash indirect expansion in lookup_build_cmd().
#
# Still hardcoded (deferred to v0.3 -- consumers edit the prompt heredocs):
#   - Per-project addenda in the prompt (e.g. dbproj schema-fetch instruction,
#     EF migration warning). These are heavily project-specific.
# =============================================================================
set -euo pipefail

ORCHESTRATOR_REPO="${ORCHESTRATOR_REPO:?}"
GH_TOKEN="${GH_TOKEN:?}"             # built-in token for this repo (issues)
DISPATCH_TOKEN="${DISPATCH_TOKEN:?}" # PAT for cross-repo dispatch
TEST_HOST_REPO="${TEST_HOST_REPO:?}" # consumer-set; repo hosting test-agent.yml
TRIGGER_EVENT="${TRIGGER_EVENT:-workflow_dispatch}"

# Source per-project config (required). See config/orchestrator.example.env.
CONFIG_FILE="$(dirname "$0")/../config/orchestrator.env"
if [ ! -f "$CONFIG_FILE" ]; then
  echo "ERROR: Missing required config file: $CONFIG_FILE" >&2
  echo "Copy config/orchestrator.example.env to config/orchestrator.env and edit." >&2
  exit 1
fi
# shellcheck disable=SC1090
source "$CONFIG_FILE"

# Validate required config keys
: "${PROJECT_NAME:?orchestrator.env: PROJECT_NAME is required}"
: "${TARGET_BRANCH:?orchestrator.env: TARGET_BRANCH is required}"
: "${PR_LINK_PHRASE:?orchestrator.env: PR_LINK_PHRASE is required}"

# Issues stuck in-progress longer than this are considered failed/abandoned.
# Must exceed the agent timeout (30m) + one orchestrator cycle (6h) + buffer.
STALE_THRESHOLD_SECONDS=21600  # 6 hours

owner=$(echo "$ORCHESTRATOR_REPO" | cut -d'/' -f1)
ORCH_SLUG=$(echo "$ORCHESTRATOR_REPO" | cut -d'/' -f2)

# Look up the per-target-repo build command from config. The convention is
# BUILD_<UPPERCASE_REPO_WITH_UNDERSCORES> (e.g. fn-mystore -> BUILD_FN_MYSTORE).
# Falls back to BUILD_DEFAULT if the specific repo has no entry.
lookup_build_cmd() {
  local repo="$1"
  local key="BUILD_$(echo "$repo" | tr '[:lower:]-' '[:upper:]_')"
  echo "${!key:-${BUILD_DEFAULT:-echo \"no build configured for $repo\"}}"
}

# â"€â"€ Helper: check if an open PR already references an issue â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€
pr_exists_for_issue() {
  local target_repo="$1" issue_number="$2"
  local count
  count=$(GH_TOKEN="$DISPATCH_TOKEN" gh pr list \
    --repo "${owner}/${target_repo}" \
    --state open \
    --json body \
    --jq "[.[] | select(.body | contains(\"${ORCH_SLUG}#${issue_number}\"))] | length" \
    2>/dev/null || echo "0")
  [ "${count:-0}" -gt 0 ]
}

# â"€â"€ Helper: check if a branch exists in a target repo â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€
branch_exists() {
  local target_repo="$1" branch="$2"
  GH_TOKEN="$DISPATCH_TOKEN" gh api \
    "repos/${owner}/${target_repo}/branches/${branch}" \
    --silent 2>/dev/null
}

# â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
# STEP 0a -- Close any open issues that are already labeled 'done'
# (test agent sometimes hits spending cap after labeling but before closing)
# â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
gh issue list --repo "$ORCHESTRATOR_REPO" --label done --state open \
  --json number --jq '.[].number' 2>/dev/null | \
while read -r n; do
  gh issue close "$n" --repo "$ORCHESTRATOR_REPO" \
    --comment "Auto-closing: already marked done." 2>/dev/null || true
  echo "Auto-closed done issue #$n"
done

# â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
# STEP 0 -- Clear expired cap-wait labels and re-trigger stalled stages
# â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
cap_wait_issues=$(gh issue list \
  --repo "$ORCHESTRATOR_REPO" \
  --label cap-wait \
  --state open \
  --json number,labels,updatedAt \
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
      echo "Issue #$number: cap-wait active for ${remaining}m more -- skipping"
      continue
    fi
  fi

  echo "Issue #$number: cap-wait expired -- clearing label"
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
        --jq "[.[] | select(.body | contains(\"${ORCH_SLUG}#${number}\"))] | .[0].number // empty" \
        2>/dev/null || true)
      if [ -n "$pr_number" ] && [ "$pr_number" != "null" ]; then
        GH_TOKEN="$DISPATCH_TOKEN" gh workflow run test-agent.yml \
          --repo "${owner}/${TEST_HOST_REPO}" --ref main \
          -f pr_numbers="$pr_number" \
          -f target_repo="$target_repo" \
          -f orchestrator_issues="$number"
        echo "Re-triggered test agent for issue #$number (PR #$pr_number)"
      else
        echo "Issue #$number: in-test but no merged PR found -- skipping test re-trigger"
      fi
    fi
  fi

  # If code-review, re-trigger only if stale (>20 min) — avoids racing with the dev agent's
  # immediate trigger-review.sh dispatch which fires right after build+test completes.
  has_code_review=$(echo "$issue" | jq -r '[.labels[].name] | any(. == "code-review")')
  if [ "$has_code_review" = "true" ]; then
    updated_at=$(echo "$issue" | jq -r '.updatedAt')
    now=$(date +%s)
    updated_epoch=$(date -d "$updated_at" +%s 2>/dev/null || echo 0)
    age=$(( now - updated_epoch ))
    if [ "$age" -lt 1200 ]; then
      echo "Issue #$number: code-review but only ${age}s old — skipping re-trigger (threshold 1200s)"
    else
      target_repo=$(echo "$issue" | jq -r '[.labels[].name | select(startswith("repo:"))] | first // empty' | sed 's/repo://')
      if [ -n "$target_repo" ]; then
        pr_data=$(GH_TOKEN="$DISPATCH_TOKEN" gh pr list \
          --repo "${owner}/${target_repo}" --state open \
          --json number,headRefName,body \
          --jq "[.[] | select(.body | contains(\"${ORCH_SLUG}#${number}\"))] | .[0] // empty" \
          2>/dev/null || echo "")
        if [ -n "$pr_data" ] && [ "$pr_data" != "null" ] && [ "$pr_data" != "" ]; then
          pr_number=$(echo "$pr_data" | jq -r '.number')
          head_branch=$(echo "$pr_data" | jq -r '.headRefName')
          GH_TOKEN="$DISPATCH_TOKEN" gh workflow run code-review.yml \
            --repo "${owner}/${target_repo}" --ref main \
            -f pr_number="$pr_number" \
            -f head_branch="$head_branch"
          echo "Re-triggered code review for issue #$number (PR #$pr_number, age ${age}s)"
        else
          echo "Issue #$number: code-review but no open PR found — resetting to in-progress"
          gh issue edit "$number" --repo "$ORCHESTRATOR_REPO" \
            --remove-label "code-review" --add-label "in-progress"
        fi
      fi
    fi
  fi
done

# â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
# STEP 1 -- Recover stale in-progress issues
# Runs on every trigger — age threshold prevents premature recovery.
# â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•

stale_issues=$(gh issue list \
  --repo "$ORCHESTRATOR_REPO" \
  --label in-progress \
  --state open \
  --json number,title,body,labels,updatedAt \
  --limit 20)

stale_dispatched=0
while IFS= read -r issue; do
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
    echo "Issue #$number has active cap-wait -- skipping stale recovery"
    continue
  fi

  # Skip if already marked done (contradictory labels -- remove in-progress and move on)
  has_done=$(echo "$issue" | jq -r '[.labels[].name] | any(. == "done")')
  if [ "$has_done" = "true" ]; then
    echo "Issue #$number already has done label -- removing in-progress"
    gh issue edit "$number" --repo "$ORCHESTRATOR_REPO" --remove-label in-progress
    continue
  fi

  # Query active_runs once up-front -- used by merge-blocked detection and threshold logic.
  active_runs=$(GH_TOKEN="$DISPATCH_TOKEN" gh run list \
    --repo "${owner}/${target_repo}" \
    --workflow=claude-code.yml \
    --status in_progress \
    --json status --jq 'length' 2>/dev/null || echo "0")

  # Detect PRs blocked on merge (review passed but conflicts unresolved) and route
  # them to code-review so STEP 2b can dispatch a rebase agent. Only act when no
  # agent is currently working on this repo.
  if [ "${active_runs:-0}" -eq 0 ]; then
    open_pr=$(GH_TOKEN="$DISPATCH_TOKEN" gh pr list \
      --repo "${owner}/${target_repo}" --state open \
      --json number,body \
      --jq "[.[] | select(.body | contains(\"${ORCH_SLUG}#${number}\"))] | .[0]" \
      2>/dev/null || echo "")
    if [ -n "$open_pr" ] && [ "$open_pr" != "null" ]; then
      open_pr_number=$(echo "$open_pr" | jq -r '.number // empty' 2>/dev/null || true)
      last_comment=$(GH_TOKEN="$DISPATCH_TOKEN" gh pr view "$open_pr_number" \
        --repo "${owner}/${target_repo}" --json comments \
        --jq '.comments[-1].body[:60]' 2>/dev/null || echo "")
      if echo "$last_comment" | grep -q "Merge blocked"; then
        gh issue edit "$number" --repo "$ORCHESTRATOR_REPO" \
          --remove-label in-progress --add-label code-review 2>/dev/null || true
        echo "Issue #$number: PR #$open_pr_number has merge conflict -- moved to code-review for rebase"
        continue
      fi
    fi
  fi

  # Calculate age in seconds.
  # Use a shorter threshold when no agent runs are active -- means the issue is
  # genuinely abandoned (cap hit, network error) rather than legitimately running.
  # 15 min picks up abandoned issues quickly without false positives on legitimate work.
  age=$(( $(date +%s) - $(date -d "$updated_at" +%s) ))
  if [ "${active_runs:-0}" -eq 0 ]; then
    effective_threshold=900  # 15 min -- no agent running, recover quickly
  else
    effective_threshold="$STALE_THRESHOLD_SECONDS"  # 6h -- agent running, give it time
  fi
  if [ "$age" -lt "$effective_threshold" ]; then
    echo "Issue #$number has been in-progress for $((age/60))m (threshold: $((effective_threshold/60))m, active runs: ${active_runs:-0}) - skipping"
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

  # Hard stop at 3 retries -- mark agent-failed; STEP 3 will retry it at lower priority
  if [ "$retry_count" -ge 3 ]; then
    echo "Issue #$number: hit retry cap ($retry_count retries) -- marking agent-failed"
    gh issue edit "$number" \
      --repo "$ORCHESTRATOR_REPO" \
      --remove-label in-progress \
      --add-label agent-failed
    gh issue comment "$number" \
      --repo "$ORCHESTRATOR_REPO" \
      --body "Agent has failed **$retry_count** times on this issue (likely quota exhaustion). Marking as **agent-failed** -- will be retried automatically at lower priority once quota is restored."
    continue
  fi

  branch="feature/issue-${number}"

  if branch_exists "$target_repo" "$branch"; then
    echo "Issue #$number: branch $branch exists -- dispatching resume agent (retry $next_retry/3)"

    gh issue edit "$number" \
      --repo "$ORCHESTRATOR_REPO" \
      --add-label "retry-$next_retry"

    build_cmd=$(lookup_build_cmd "$target_repo")

    read -r -d '' prompt << PROMPT || true
RESUME incomplete task from ${PROJECT_NAME} backlog.

Issue #${number} in ${ORCHESTRATOR_REPO}: ${title}

${body}

CONTEXT: A previous agent started this task but did not finish (likely hit a spending cap or timed out).
Branch ${branch} already exists in this repo with partial work.

Resume instructions:
1. Check out the existing branch ${branch} -- do NOT create a new branch.
2. Run: git log origin/${TARGET_BRANCH}..HEAD --oneline   to see what was already committed.
3. Run: ${build_cmd}   to check current build state.
4. If the task involves SQL queries: read the relevant schema from retrostoremanager/dbproj-mystore (development branch, PostgreSQL/ directory) -- exact column names are there. Use: GH_TOKEN="\$GH_DISPATCH_TOKEN" gh api "repos/retrostoremanager/dbproj-mystore/contents/PostgreSQL/<file>?ref=development" --jq '.content' | base64 -d
5. Review the acceptance criteria above and complete any remaining items.
6. If all tests pass, open a pull request targeting the ${TARGET_BRANCH} branch.
7. PR title: ${title}. PR body must include: ${PR_LINK_PHRASE} ${ORCHESTRATOR_REPO}#${number}
PROMPT

    jq -n --arg prompt "$prompt" --arg branch "$branch" \
      '{"ref":"main","inputs":{"prompt":$prompt,"branch":$branch}}' | \
    GH_TOKEN="$DISPATCH_TOKEN" gh api \
      "repos/${owner}/${target_repo}/actions/workflows/claude-code.yml/dispatches" \
      --method POST --input -

    echo "Dispatched resume for issue #$number to $target_repo (branch: $branch)"
    stale_dispatched=$((stale_dispatched + 1))
    [ "$stale_dispatched" -ge 1 ] && break

  else
    echo "Issue #$number: no branch found -- resetting to ready (retry $next_retry/3)"
    gh issue edit "$number" \
      --repo "$ORCHESTRATOR_REPO" \
      --remove-label in-progress \
      --add-label ready \
      --add-label "retry-$next_retry"
    gh issue comment "$number" \
      --repo "$ORCHESTRATOR_REPO" \
      --body "Previous agent run failed before creating a branch (retry $next_retry/3). Resetting to **ready** for another attempt."
  fi
done < <(echo "$stale_issues" | jq -c '.[]')

# â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
# STEP 2 -- Replenish backlog if running low
# â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
BACKLOG_THRESHOLD=3

open_count=$(gh issue list \
  --repo "$ORCHESTRATOR_REPO" \
  --state open \
  --json number,labels \
  --jq '[.[] | select(.labels | map(.name) | any(. == "ready" or . == "in-progress"))] | length' \
  2>/dev/null || echo "99")

echo "Open issues (ready + in-progress): $open_count"

if [ "${open_count:-99}" -lt "$BACKLOG_THRESHOLD" ]; then
  # Guard: skip if a backlog generation run is already in progress (prevents duplicates from concurrent orchestrator cycles)
  backlog_running=$(GH_TOKEN="$DISPATCH_TOKEN" gh run list \
    --repo "$ORCHESTRATOR_REPO" \
    --workflow=generate-backlog.yml \
    --status in_progress \
    --json status --jq 'length' 2>/dev/null || echo "0")
  if [ "${backlog_running:-0}" -gt 0 ]; then
    echo "Backlog generation already in progress -- skipping to prevent duplicate issues"
  else
    echo "Backlog below threshold ($BACKLOG_THRESHOLD) -- triggering backlog generation"
    bash "$(dirname "$0")/generate-backlog.sh" || echo "Backlog generation dispatch failed (non-fatal)"
  fi
fi

# =============================================================================
# STEP 2b -- Re-trigger code reviews that are stuck (no active review agent)
# Covers the review-retry case: the dev agent fixed revisions but the
# "Trigger code review" step in claude-code.yml skips PRs with review-retry-*.
# =============================================================================
code_review_issues=$(gh issue list \
  --repo "$ORCHESTRATOR_REPO" \
  --label code-review --state open \
  --json number,labels \
  --limit 20 \
  2>/dev/null || echo "[]")

echo "$code_review_issues" | jq -c '.[]' | while read -r cr_issue; do
  cr_number=$(echo "$cr_issue" | jq -r '.number')
  cr_repo=$(echo "$cr_issue" | jq -r '[.labels[].name | select(startswith("repo:"))] | first // empty' | sed 's/repo://')
  [ -z "$cr_repo" ] && continue

  active_review=$(GH_TOKEN="$DISPATCH_TOKEN" gh run list \
    --repo "${owner}/${cr_repo}" \
    --workflow=code-review.yml \
    --status in_progress \
    --json status --jq 'length' 2>/dev/null || echo "0")
  [ "${active_review:-0}" -gt 0 ] && continue

  pr_data=$(GH_TOKEN="$DISPATCH_TOKEN" gh pr list \
    --repo "${owner}/${cr_repo}" --state open \
    --json number,headRefName,body \
    --jq "[.[] | select(.body | contains(\"${ORCH_SLUG}#${cr_number}\"))] | .[0] // empty" \
    2>/dev/null || echo "")
  [ -z "$pr_data" ] || [ "$pr_data" = "null" ] && continue

  pr_number=$(echo "$pr_data" | jq -r '.number')
  head_branch=$(echo "$pr_data" | jq -r '.headRefName')
  GH_TOKEN="$DISPATCH_TOKEN" gh workflow run code-review.yml \
    --repo "${owner}/${cr_repo}" --ref main \
    -f pr_number="$pr_number" \
    -f head_branch="$head_branch"
  echo "Re-triggered code review for issue #$cr_number (${cr_repo} PR #$pr_number)"
done


# â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
# STEP 3 -- Dispatch next ready task (per-repo dev slots, up to 3 per cycle)
# Each repo (fn, web, dbproj, ...) has its own dev slot -- fn work no longer
# blocks web work. Tests dispatch per-repo-per-cycle with a global cap of 3.
# Code-review runs in parallel on its own agent and is not gated here.
# â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
echo "Checking pipeline state..."

# Per-repo dev slots: collect which repos already have an in-progress issue.
# Each repo (fn-mystore, web-mystore, dbproj-mystore, ...) can run one dev agent
# concurrently. With the old single-global slot, fn work would block web work.
occupied_repos=$(gh issue list \
  --repo "$ORCHESTRATOR_REPO" \
  --state open \
  --json labels \
  --jq '[.[] | select(.labels | map(.name) | any(. == "in-progress"))
        | .labels[] | select(.name | startswith("repo:")) | .name | ltrimstr("repo:")] | unique' \
  2>/dev/null || echo "[]")
dev_active_count=$(echo "$occupied_repos" | jq length 2>/dev/null || echo "0")
echo "Occupied repos: $(echo "$occupied_repos" | jq -r 'join(", ")' 2>/dev/null || echo "none")"

in_test_issues=$(gh issue list \
  --repo "$ORCHESTRATOR_REPO" \
  --label in-test \
  --state open \
  --json number,labels,updatedAt \
  --limit 60 \
  2>/dev/null || echo "[]")

in_test_count=$(echo "$in_test_issues" | jq length)

linked_bugs=""

# -- Auto-close story issues where all linked bugs are resolved -----------------
# A "story" is any in-test issue that is NOT itself a bug. Once every linked bug
# has been closed, the story is functionally done -- mark it done.
if [ "$in_test_count" -gt 0 ]; then
  echo "$in_test_issues" | jq -c '.[]' | while read -r in_test_entry; do
    in_test_number=$(echo "$in_test_entry" | jq -r '.number')
    is_bug=$(echo "$in_test_entry" | jq -r '[.labels[].name] | any(. == "bug")')
    [ "$is_bug" = "true" ] && continue  # bugs are closed by the test agent directly

    all_bugs=$(gh issue list \
      --repo "$ORCHESTRATOR_REPO" --label bug --state all --limit 50 \
      --json body \
      --jq "[.[] | select(.body | contains(\"${ORCH_SLUG}#${in_test_number}\"))] | length" \
      2>/dev/null || echo "0")
    [ "${all_bugs:-0}" -eq 0 ] && continue  # never been tested yet -- let test agent run first

    open_bugs=$(gh issue list \
      --repo "$ORCHESTRATOR_REPO" --label bug --state open --limit 50 \
      --json body \
      --jq "[.[] | select(.body | contains(\"${ORCH_SLUG}#${in_test_number}\"))] | length" \
      2>/dev/null || echo "1")

    if [ "${open_bugs:-1}" -eq 0 ]; then
      # Guard: do not mark a story done while its implementation PR is still open.
      # Linked bugs being resolved does NOT mean the story's own work reached main --
      # an open PR means the code is unmerged, so closing here would lose the work.
      story_repo=$(echo "$in_test_entry" | jq -r '[.labels[].name | select(startswith("repo:"))] | first // empty' | sed 's/repo://')
      if [ -n "$story_repo" ] && pr_exists_for_issue "$story_repo" "$in_test_number"; then
        echo "Story #$in_test_number: all bugs resolved but an open PR exists in $story_repo -- NOT closing (work unmerged)"
        continue
      fi
      gh issue edit "$in_test_number" --repo "$ORCHESTRATOR_REPO" \
        --remove-label in-test --add-label done 2>/dev/null || true
      echo "Story #$in_test_number: all $all_bugs bug(s) resolved -- marking done"
    else
      echo "Story #$in_test_number: $open_bugs/$all_bugs bug(s) still open"
    fi
  done
fi

# -- Dispatch up to one test per repo per cycle --------------------------------
# Replaces the old comma-joined batched dispatch. Per-repo per-cycle lets fn
# and web run in parallel while a global cap (3) prevents runaway concurrency.
if [ "$in_test_count" -gt 0 ]; then
  total_test_active=$(GH_TOKEN="$DISPATCH_TOKEN" gh run list \
    --repo "${owner}/${TEST_HOST_REPO}" \
    --workflow=test-agent.yml \
    --status in_progress \
    --json status --jq 'length' 2>/dev/null || echo "0")
  test_dispatched_repos=""

  while IFS= read -r in_test_entry; do
    in_test_number=$(echo "$in_test_entry" | jq -r '.number')

    linked=$(gh issue list \
      --repo "$ORCHESTRATOR_REPO" \
      --label ready --label bug --state open \
      --json number,title,body,labels \
      --limit 10 \
      --jq "[.[] | select(.body | contains(\"${ORCH_SLUG}#${in_test_number}\"))]" \
      2>/dev/null || echo "[]")

    cnt=$(echo "$linked" | jq length)
    if [ "$cnt" -gt 0 ]; then
      [ -z "$linked_bugs" ] && linked_bugs="$linked"
      continue
    fi

    # Skip if this issue has already been tested (bugs were filed) -- the
    # auto-close loop above handles its closure once those bugs resolve.
    is_bug=$(echo "$in_test_entry" | jq -r '[.labels[].name] | any(. == "bug")')
    if [ "$is_bug" = "false" ]; then
      all_bugs=$(gh issue list \
        --repo "$ORCHESTRATOR_REPO" --label bug --state all --limit 50 \
        --json body \
        --jq "[.[] | select(.body | contains(\"${ORCH_SLUG}#${in_test_number}\"))] | length" \
        2>/dev/null || echo "0")
      if [ "${all_bugs:-0}" -gt 0 ]; then
        echo "Story #$in_test_number: previously tested ($all_bugs bug(s) filed) -- skipping re-test"
        continue
      fi
    fi

    # Skip if open linked bugs (that are NOT already in-test themselves) block
    # this story -- the parent can't pass E2E while its bugs are unresolved.
    open_linked_bug_cnt=$(gh issue list \
      --repo "$ORCHESTRATOR_REPO" \
      --label bug --state open \
      --json number,body,labels \
      --limit 20 \
      --jq "[.[] | select(
        (.body | contains(\"${ORCH_SLUG}#${in_test_number}\")) and
        (.labels | map(.name) | any(. == \"in-test\") | not)
      )] | length" \
      2>/dev/null || echo "0")
    if [ "${open_linked_bug_cnt:-0}" -gt 0 ]; then
      continue
    fi

    target_repo_raw=$(echo "$in_test_entry" | jq -r '[.labels[].name | select(startswith("repo:"))] | first // empty' | sed 's/repo://')
    [ -z "$target_repo_raw" ] && continue

    # One test per target repo per cycle.
    if echo "$test_dispatched_repos" | grep -qF "$target_repo_raw"; then
      continue
    fi

    updated_at=$(echo "$in_test_entry" | jq -r '.updatedAt')
    age=$(( $(date +%s) - $(date -d "$updated_at" +%s) ))

    # Skip if at concurrent cap and issue is not stale.
    if [ "${total_test_active:-0}" -ge 3 ] && [ "$age" -le "$STALE_THRESHOLD_SECONDS" ]; then
      echo "Issue #$in_test_number: test capacity full ($total_test_active active) -- skipping"
      continue
    fi

    pr=$(GH_TOKEN="$DISPATCH_TOKEN" gh pr list \
      --repo "${owner}/${target_repo_raw}" --state merged \
      --json number,body \
      --jq "[.[] | select(.body | contains(\"${ORCH_SLUG}#${in_test_number}\"))] | .[0].number // empty" \
      2>/dev/null || true)
    if [ -n "$pr" ] && [ "$pr" != "null" ]; then
      GH_TOKEN="$DISPATCH_TOKEN" gh workflow run test-agent.yml \
        --repo "${owner}/${TEST_HOST_REPO}" --ref main \
        -f pr_numbers="$pr" \
        -f target_repo="$target_repo_raw" \
        -f orchestrator_issues="$in_test_number"
      echo "Dispatched test for issue #$in_test_number (PR #$pr in $target_repo_raw)"
      test_dispatched_repos="$test_dispatched_repos $target_repo_raw"
      total_test_active=$((total_test_active + 1))
    fi
  done < <(echo "$in_test_issues" | jq -c '.[]')
fi

# -- Build candidate pool for dev dispatch -------------------------------------
# Linked bugs take priority. Otherwise: ready + agent-failed, sorted by priority.
# Per-repo gating happens in the dispatch loop so an occupied fn slot doesn't
# block a free web/dbproj dispatch in the same cycle.
if [ -n "$linked_bugs" ]; then
  issues="$linked_bugs"
else
  ready_issues=$(gh issue list \
    --repo "$ORCHESTRATOR_REPO" \
    --label ready --state open \
    --json number,title,body,labels \
    --limit 10)

  failed_issues=$(gh issue list \
    --repo "$ORCHESTRATOR_REPO" \
    --label agent-failed --state open \
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

# Dispatch up to 3 per cycle (one per free repo slot). dispatched_repos tracks
# within-cycle assignments so a batch of issues for the same repo doesn't all
# dispatch at once and spawn conflicting concurrent agents.
dispatched=0
dispatched_repos=""

echo "$issues" | jq -c '.[]' | while read -r issue; do
  if [ "$dispatched" -ge 3 ]; then
    break
  fi

  number=$(echo "$issue" | jq -r '.number')
  title=$(echo "$issue" | jq -r '.title')
  body=$(echo "$issue" | jq -r '.body // ""')
  is_bug=$(echo "$issue" | jq -r '[.labels[].name] | any(. == "bug")')
  is_priority=$(echo "$issue" | jq -r '[.labels[].name] | any(. == "priority:high")')
  is_failed=$(echo "$issue" | jq -r '[.labels[].name] | any(. == "agent-failed")')

  target_repo=$(echo "$issue" | jq -r '.labels[].name' | grep '^repo:' | head -1 | sed 's/repo://' || true)

  if [ -z "$target_repo" ]; then
    echo "Issue #$number has no repo: label - skipping"
    continue
  fi

  # Skip if this repo already has an in-progress issue (per-repo dev slot).
  if echo "$occupied_repos" | jq -e --arg r "$target_repo" 'index($r) != null' >/dev/null 2>&1; then
    echo "Issue #$number: $target_repo slot occupied -- skipping"
    continue
  fi

  # Skip if we already dispatched to this repo in THIS run (occupied_repos is a
  # start-of-run snapshot, so without this a batch of issues for the same repo
  # would all dispatch at once, spawning concurrent agents that then conflict).
  if echo " $dispatched_repos " | grep -q " $target_repo "; then
    echo "Issue #$number: $target_repo already dispatched this cycle -- skipping"
    continue
  fi

  build_cmd=$(lookup_build_cmd "$target_repo")

  if [ "$is_bug" = "true" ]; then
    task_type="Bug fix"
    task_note="This is a confirmed bug found by the QA testing agent after deployment to dev. Fix the specific issue described -- do not add unrelated changes."
  else
    task_type="Feature task"
    task_note=""
  fi

  priority_tag=""
  [ "$is_priority" = "true" ] && priority_tag=" [PRIORITY]"
  echo "Dispatching issue #$number ('$title')${priority_tag} to $target_repo..."

  read -r -d '' prompt << PROMPT || true
${task_type} from ${PROJECT_NAME} backlog.

Issue #${number} in ${ORCHESTRATOR_REPO}: ${title}

${body}

${task_note}

Instructions:
1. Read CLAUDE.md for coding standards and file map before making any changes.
2. If the task involves database queries or SQL: read the relevant schema file(s) from retrostoremanager/dbproj-mystore (development branch, PostgreSQL/ directory) before writing any SQL -- exact column names are there. Use: GH_TOKEN="\$GH_DISPATCH_TOKEN" gh api "repos/retrostoremanager/dbproj-mystore/contents/PostgreSQL/<file>?ref=development" --jq '.content' | base64 -d
3. Create a feature branch feature/issue-${number} off the ${TARGET_BRANCH} branch.
4. Implement the task following all project conventions.
5. Run: ${build_cmd}
6. Open a pull request targeting the ${TARGET_BRANCH} branch.
7. PR title: ${title}. PR body must include: ${PR_LINK_PHRASE} ${ORCHESTRATOR_REPO}#${number}
PROMPT

  if [ "$is_failed" = "true" ]; then
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

  jq -n --arg prompt "$prompt" --arg branch "$TARGET_BRANCH" \
    '{"ref":"main","inputs":{"prompt":$prompt,"branch":$branch}}' | \
  GH_TOKEN="$DISPATCH_TOKEN" gh api \
    "repos/${owner}/${target_repo}/actions/workflows/claude-code.yml/dispatches" \
    --method POST --input -

  echo "Dispatched issue #$number to $target_repo"
  dispatched=$((dispatched + 1))
  dispatched_repos="$dispatched_repos $target_repo"
done
