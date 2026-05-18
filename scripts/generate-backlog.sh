#!/usr/bin/env bash
# Dispatches a Claude agent to read PRD.md and create new GitHub issues
# when the backlog runs low. Called from dispatch-tasks.sh.
set -euo pipefail

ORCHESTRATOR_REPO="${ORCHESTRATOR_REPO:?}"
DISPATCH_TOKEN="${DISPATCH_TOKEN:?}"

owner=$(echo "$ORCHESTRATOR_REPO" | cut -d'/' -f1)

PRD=$(cat "$(dirname "$0")/../PRD.md")

# Fetch all existing issues (all states) so the agent can avoid duplicates
EXISTING_ISSUES=$(GH_TOKEN="$DISPATCH_TOKEN" gh issue list \
  --repo "$ORCHESTRATOR_REPO" \
  --state all \
  --limit 100 \
  --json number,title,labels \
  --jq '.[] | "#\(.number) [\(.labels | map(.name) | join(", "))] \(.title)"' \
  2>/dev/null || echo "(none)")

read -r -d '' PROMPT << PROMPT || true
You are a product owner for RetroStoreManager, a SaaS platform for retro game and TCG store owners.

Your job: read the PRD below and create 3-5 new GitHub issues for features that have NOT yet been issued. Choose items in priority order from the current phase (Phase 0 first, only move to Phase 1 when all Phase 0 items are covered).

## PRD
${PRD}

## Already-created issues (DO NOT duplicate these)
${EXISTING_ISSUES}

## How to create each issue

Use this exact gh command for each issue:
  GH_TOKEN="\$GH_DISPATCH_TOKEN" gh issue create \
    --repo ${ORCHESTRATOR_REPO} \
    --title "[title]" \
    --body "[body]" \
    --label "ready" \
    --label "repo:fn-mystore"   # or repo:web-mystore for frontend issues

The body MUST follow this format:
  ## What to build
  [2-3 sentences describing what to implement]

  ## Acceptance criteria
  - [ ] [specific testable criterion]
  - [ ] [specific testable criterion]
  ...

  ## Technical notes
  [Specific files to create/modify, SQL schema changes, API routes, test file names]

Make acceptance criteria detailed enough that a developer can implement the feature without needing to ask clarifying questions.

## Important rules
- Check the phase rules in the PRD — do NOT create Phase 1 issues if any Phase 0 items are uncovered
- Create exactly 3-5 issues, no more
- Each issue must be for a distinct, implementable unit of work (not too broad, not trivially small)
- Backend issues use --label "repo:fn-mystore", frontend issues use --label "repo:web-mystore"
- After creating issues, print "Done. Created N issues." so we know you finished
PROMPT

echo "Dispatching backlog generation agent..."

jq -n --arg prompt "$PROMPT" \
  '{"ref":"main","inputs":{"prompt":$prompt}}' | \
GH_TOKEN="$DISPATCH_TOKEN" gh api \
  "repos/${owner}/orchestrator-mystore/actions/workflows/generate-backlog.yml/dispatches" \
  --method POST --input -

echo "Backlog generation dispatched."
