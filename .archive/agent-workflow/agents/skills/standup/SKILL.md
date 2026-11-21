---
name: standup
description: Report outstanding k8s-cluster Beads work. Use at session start or after several issues close; do not begin implementation.
---

# Standup

Run `bash .agents/skills/standup/scripts/standup.sh` from the repository root. It is a read-only inventory aid, not a completion verdict.

Inspect in-progress recovery candidates with `bd show` and `bd comments`, plus run, worktree, PR/CI and cluster gates, before adopting anything. Do not infer abandonment from age or the shared assignee. Exclude `human`, `needs-human` and `owner-decision` work from agent selection. An empty ready list does not establish completion. End with the exact invocation and prerequisite (`$work <id>` or `$autopilot resume <run-id>`). Do not claim, change or close an issue.
