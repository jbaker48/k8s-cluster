---
description: Turn a feature idea into a k8s-cluster Beads epic after owner approval. No code, branch or PR.
argument-hint: '<feature idea>'
allowed-tools: Bash, Read, Glob, Grep, Skill, Agent, AskUserQuestion, WebSearch, WebFetch, mcp__context7__*
---

Read and follow `.agents/skills/scope/SKILL.md` and `docs/dynamic-workflow.md`.

Idea: $ARGUMENTS

Ask one question at a time, present the design and wait for approval before creating anything. After approval use Beads only: epic, children, real dependencies and `agent:<domain>` labels, then stop. Never edit implementation files, branch, commit, push or open a PR.
