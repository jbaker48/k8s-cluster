---
name: decide
description: Facilitate a human or owner-decision k8s-cluster Beads issue with read-only research and a recorded decision. Use only for issues labelled human, needs-human or owner-decision.
---

# Decide

Read `docs/dynamic-workflow.md`, the issue and the cited files. Luna gathers facts through `scripts/lane.sh research <packet-file>`; Astra or Opus (`lane.sh opus`) handles unclear architecture trade-offs. The owner decides credentials, spend, risk acceptance, merge/deploy authority and recovery.

Separate verified facts, assumptions and owner-only choices. Ask only the currently unblocked question, with a recommendation and evidence. Record the answer and rejected options in Beads, then create or reuse one scoped follow-up per implementation action with concrete Files/Steps/Verify. Do not implement it. Additive and ordering changes only; subtractive changes need the owner. End with the exact `$work <id>` or `$autopilot resume <run-id>`.
