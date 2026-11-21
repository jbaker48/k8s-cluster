---
name: groom
description: Evidence-sweep and structurally groom the k8s-cluster Beads backlog without implementing it. Use when premises, blockers or decomposition need review.
---

# Groom

Read `docs/dynamic-workflow.md`. Stage A is a Luna `scout` evidence sweep: is each premise still true, is the work already done (check git log and the live cluster read-only), is each blocker real. Stage B uses Astra or Opus for structural decisions, dependency edits, decomposition and priorities.

Additive and ordering changes may be applied; never auto-apply `close`, `supersede`, `defer` or delete: label those for the owner. Keep `agent:<domain>` and owner labels accurate. End with what changed, what became ready and the owner decisions required.
