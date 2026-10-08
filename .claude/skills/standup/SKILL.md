---
name: standup
description: Report outstanding k8s-cluster Beads work; do not implement.
---

Read and follow `.agents/skills/standup/SKILL.md` and `docs/dynamic-workflow.md`.

Compatibility mapping (Claude Code as Opus orchestrator): implementation → `scripts/lane.sh luna <worktree> <packet-file>`; ordinary review → `scripts/lane.sh review <worktree> <base> <head> <issue-id>`; high-risk review → `astra-review` then `opus-review`; diagnosis → `sol` then `astra`/`opus`; research → `research`. Block with one `gh run watch --exit-status` or `gh pr checks --watch`; never a Monitor/ScheduleWakeup poll loop.
