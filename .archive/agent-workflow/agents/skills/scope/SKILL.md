---
name: scope
description: Turn a k8s-cluster feature idea into a reviewed Beads epic and issue set without editing implementation files. Use when a feature needs decomposition and owner approval.
---

# Scope

Read `docs/dynamic-workflow.md`; inspect the repository, Beads and safe read-only cluster state before asking questions. The terminus is an approved design plus additive Beads issues; no branch, no code.

Ask one question at a time, propose alternatives with a recommendation, get owner approval. Luna does read-only research; Astra/Opus handle structural design. Put the approved design, rejected alternatives, fallback and exclusions in one epic. Children use Why/What/Verify with acceptance criteria, real dependencies and `agent:<domain>` labels. Label credential/spend/risk-acceptance work `needs-human` or `owner-decision`. Never close, supersede, defer or delete existing Beads here.
