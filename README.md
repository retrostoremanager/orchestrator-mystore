# RetroStoreManager — Autonomous AI Development Pipeline

A multi-tenant SaaS platform for retro game and trading card retailers, built end-to-end by a pipeline of autonomous AI agents coordinated through GitHub Issues.

The interesting part isn't the app — it's the infrastructure: a self-managing development system where AI agents write code, review it, deploy it, and test it against a live environment, with a human setting direction through a backlog and reviewing the occasional escalation.

---

## The Application

RetroStoreManager is a production SaaS with:

- **Multi-tenant backend** — Azure Functions (.NET 8, C#) with PostgreSQL. Every query is scoped to `company_id`; company context is extracted from JWT claims via middleware on every request.
- **Role-based access control** — Custom RBAC middleware with fine-grained permissions per role, enforced at the function level via a `[RequirePermission]` attribute.
- **Point-of-sale and inventory** — Sales transactions, inventory tracking, customer management.
- **Billing** — Stripe subscriptions, trial periods, webhook-driven state transitions, automated trial-to-paid conversion via timer triggers.
- **React frontend** — Full store management UI with role-aware navigation.

---

## The Pipeline

```
 GitHub Issues (labels = pipeline state)
        │
        ▼
 ┌─────────────────────────────────────┐
 │  Orchestrator                       │  ← runs every 6h + on label events
 │  - Recovers cap-wait issues         │
 │  - Recovers stale in-progress       │
 │  - Dispatches next ready task (×1)  │
 └──────────────┬──────────────────────┘
                │
                ▼
        ┌───────────────┐
        │   Dev Agent   │  ← reads schema, writes code, opens PR
        └───────┬───────┘
                │
                ▼
        ┌───────────────────┐
        │  Code Review Agent│  ← classifies MAJOR / MODERATE / MINOR
        └──────┬────────────┘
               │
       ┌───────┴────────┐
       │                │
    Approved        Changes Requested
       │                │
       ▼                ▼
  Merge + Deploy   Revision Agent  (up to 3 cycles, then → human)
       │
       ▼
  ┌─────────────┐
  │  Test Agent │  ← authenticates against dev API, runs endpoint tests
  └──────┬──────┘
         │
    ┌────┴─────┐
    │          │
  Pass       Fail
    │          │
  Done    Bug Issue → priority queue → Dev Agent
```

**Issue labels drive state:**
`ready` → `in-progress` → `code-review` → `in-test` → `done`

Bug issues discovered by the test agent are filed into the same backlog with `priority:high` and automatically worked before new features.

---

## How Each Agent Works

**Orchestrator** (`dispatch-tasks.sh`, runs as GitHub Actions on schedule + label events):
Checks cap-wait expiry, recovers stale issues, dispatches exactly one new task per cycle. Priority order: `priority:high` bugs → `agent-failed` retries → new features.

**Dev Agent** (`claude-code.yml`, Claude Sonnet via `claude-code-action`):
Receives a structured prompt with the issue title, acceptance criteria, and explicit instructions to read the PostgreSQL migration files from a separate schema repo before writing any SQL. Creates a feature branch, implements the feature, writes unit tests, opens a PR targeting `development`.

**Code Review Agent** (`code-review.yml`):
Reads only the PR diff — not the full codebase. Classifies issues as MAJOR (security, auth bypass, data loss, wrong business logic), MODERATE (significant bugs, wrong status codes), or MINOR (style). Approves and merges on clean reviews; dispatches a revision agent with specific feedback on failures. Escalates to `needs-human-review` after 3 revision cycles.

**Test Agent** (`test-agent.yml`, Claude Sonnet):
Reads the PR diff and acceptance criteria, authenticates against the deployed dev environment, and tests each modified endpoint: happy path, error cases (400/401/404), and business logic. Files structured bug issues with exact `curl` reproduction steps. Checks for existing open bugs before creating new ones to prevent duplicate issue accumulation across retry cycles. Can receive comma-separated PR numbers for batched testing.

---

## Engineering Challenges Worth Noting

### Spending Cap Management

Claude's API has a daily spending cap. When an agent hits it mid-task, the naive outcome is: issue stays `in-progress` forever, next cycle re-dispatches immediately, hits cap again, repeat.

The solution:

1. The workflow detects cap hits by scanning `steps.claude.outputs.output` for `"Spending cap reached resets"` (deliberately scoped — our own issue comments contain `"Spending cap reached."` and would trigger false positives with a looser match)
2. Parses the reset timestamp from the error string, writes `RESET_ISO: <timestamp>` into a GitHub issue comment
3. Adds a `cap-wait` label to the issue
4. Every orchestrator cycle, cap-wait issues are checked: if `current_time > RESET_ISO`, the label is removed and the appropriate agent is re-dispatched

### Concurrent Agent Throttling

When multiple issues had cap-wait cleared in the same orchestrator cycle, all of them were dispatched simultaneously. Three agents burning tokens in parallel could exhaust the freshly-reset daily quota in under two hours.

Fixed by:
- Throttling stale recovery to **1 dispatch per orchestrator cycle** (changed the stale loop from a pipe subshell to process substitution so a counter variable persists across iterations)
- Dual-threshold stale detection: 90 minutes when no agent runs are active (issue is abandoned), 6 hours when a run is in-flight (give it time to finish)

### Schema Accuracy Across Repos

The authoritative PostgreSQL schema lives in a separate `dbproj-mystore` repository. Early agents were guessing column names, causing runtime SQL errors. The fix was to:
- Transfer `dbproj-mystore` to the org with its own `CLAUDE_CODE_OAUTH_TOKEN`
- Mandate in `CLAUDE.md` and `AGENTS.md` that agents must read the relevant migration file via `gh api` before writing any query
- Include the key table/column facts directly in agent prompts for common tables (e.g., `sale` has `subtotal`, `tax`, `total` columns — agents were previously joining `sale_item` unnecessarily)

### Duplicate Issue Prevention

The test agent was filing a new bug issue on every retry cycle for the same failure. After several retry attempts on a persistent bug, the backlog had 10+ duplicate issues for the same broken endpoint.

Fixed in the test agent prompt: before creating a bug issue, search for an existing open issue with a matching keyword. If found, comment on it with the new reproduction attempt instead of creating a duplicate.

### Multi-Repo Coordination

The system spans four repositories with different access requirements:

| Repo | Access needed |
|------|--------------|
| `orchestrator-mystore` | Read/write issues and labels (`GH_TOKEN`) |
| `fn-mystore` | Dispatch workflows, read PRs, push code (`GH_DISPATCH_TOKEN`) |
| `web-mystore` | Same as above |
| `dbproj-mystore` | Read migration files (`CLAUDE_CODE_OAUTH_TOKEN`) |

The orchestrator uses two tokens: a built-in `GITHUB_TOKEN` scoped to its own repo for issue operations, and a PAT (`GH_DISPATCH_TOKEN`) for cross-repo workflow dispatch and PR reads.

---

## Tech Stack

| Layer | Technology |
|-------|-----------|
| Backend | Azure Functions v4 isolated worker, .NET 8, C# |
| Database | PostgreSQL, Dapper |
| Frontend | React, TypeScript |
| Auth | JWT, custom middleware pipeline |
| Payments | Stripe (subscriptions, trials, webhooks) |
| File storage | Azure Blob Storage |
| AI agents | Anthropic Claude Sonnet (`claude-code-action`) |
| CI/CD | GitHub Actions |
| Orchestration | GitHub Issues + `workflow_dispatch` |

---

## Repository Structure

| Repo | Purpose |
|------|---------|
| [`orchestrator-mystore`](https://github.com/retrostoremanager/orchestrator-mystore) | Kanban board + orchestration scripts |
| [`fn-mystore`](https://github.com/retrostoremanager/fn-mystore) | Azure Functions backend |
| [`web-mystore`](https://github.com/retrostoremanager/web-mystore) | React frontend |
| [`dbproj-mystore`](https://github.com/retrostoremanager/dbproj-mystore) | PostgreSQL migrations (authoritative schema) |

---

## About

Built by [Samuel Branham](https://github.com/sbranham314) — software engineer with 13 years of experience, specializing in AI-augmented development workflows and Azure cloud architecture.

If you're exploring how to apply autonomous AI agents to your development process, feel free to reach out — [LinkedIn](https://www.linkedin.com/in/samuelbranham).
