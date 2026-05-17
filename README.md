# orchestrator-mystore

Autonomous agent orchestrator for RetroStoreManager. GitHub Issues are the Kanban.

## How it works

1. Create an issue using the **Agent Task** template
2. Add labels: the target repo (`repo:fn-mystore`) and `ready`
3. The orchestrator runs every 30 minutes, picks up `ready` issues, and dispatches them to the target repo's `claude-code-action`
4. Claude creates a feature branch, implements the task, and opens a PR
5. Review and merge the PR — that's your approval gate

## Issue labels

| Label | Meaning |
|-------|---------|
| `ready` | Task is queued and will be picked up next run |
| `in-progress` | Dispatched to an agent — work is running |
| `awaiting-review` | Agent opened a PR, waiting for your review |
| `done` | PR merged |
| `blocked` | Agent could not complete the task |
| `repo:fn-mystore` | Route this task to fn-mystore |
| `repo:web-mystore` | Route this task to web-mystore |

## Secrets required

| Secret | Purpose |
|--------|---------|
| `GH_DISPATCH_TOKEN` | PAT with `repo` scope on all target repos |

## Triggering manually

Run the **Orchestrator** workflow from the Actions tab to process ready tasks immediately without waiting for the schedule.
