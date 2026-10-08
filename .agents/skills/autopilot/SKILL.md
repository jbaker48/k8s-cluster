---
name: autopilot
description: Run or resume a foreground autonomous loop over ready non-owner k8s-cluster Beads work through Luna implementation, validation, fresh review and owner-ready PRs. Use for a queue run; not for status-only requests.
---

# Autopilot

Read `docs/dynamic-workflow.md` and `.agents/skills/work/SKILL.md`. This is a foreground run with durable Beads checkpoints, not a daemon. `scripts/autopilot-loop.sh <run-id>` starts fresh sessions (orchestrator Sol low by default, `ORCH=claude` for Opus); a stopped process does not wake itself.

Accept `all`, an epic ID, a positive count or `resume <run-id>`. Create or reuse one control issue labelled `autopilot`. Run standup read-only, reconcile in-progress handoffs, then select with:

```bash
bd ready --exclude-type=epic --exclude-label=human,needs-human,owner-decision,autopilot --limit=0 --json
```

Routing: Luna for every edit, research and ordinary review; Sol 6.1 high for hard diagnosis and ordinary design; Astra and Opus for high-risk design/review and adjudication. Overlapping writes are serial. Never poll with a model: one `wait_agent` with `timeout_ms` ≥ 1800000, or one `gh run watch --exit-status`.

One repair attempt per CI failure; two failures on an issue escalate to the owner. High-risk paths, missing credentials, unclear risk, false premises or unresolved review stop the issue at an owner PR. Autopilot opens PRs; it never merges, uses `--auto`/`--admin`, or reconciles Flux. Failure notification is a Beads comment plus the final report.

Each cycle records the durable handoff (run ID, issue, SHA, evidence, remaining clauses, actor/action, blocker, resume condition). Stop when the scope is done or a named owner/environment gate remains; list the owner steps and `$autopilot resume <run-id>`. When nothing is actionable, say "actionable work exhausted".
