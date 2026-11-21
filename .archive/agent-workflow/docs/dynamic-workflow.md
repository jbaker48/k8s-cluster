# Dynamic k8s-cluster workflow

Four model families delegate to each other. Beads (`bd`) is the only tracker. Active skills live in `.agents/skills/`; `.claude/` files are adapters. Adapted from `home-assistant-config`; see `docs/sre-agent/` for the auto-merge pipeline this workflow feeds.

## Roles

| Role | Model and effort | Transport | Output |
|---|---|---|---|
| Orchestrator (interactive) | Opus, Claude Code | main session | packets, decisions, gates, next actions |
| Orchestrator (headless/autopilot) | Sol `gpt-6.1-sol`, low | `codex exec` via `scripts/autopilot-loop.sh` (`ORCH=claude` swaps in Opus) | same |
| Implementation | Luna `gpt-6-luna`, max | `luna-impl` agent or `scripts/lane.sh luna` | bounded implementation, tests, docs |
| Ordinary review | fresh-context Luna, max | `reviewer` agent or `lane.sh review` | verdict JSON |
| Research | fresh-context Luna, max | `scout` or `lane.sh research` | read-only facts and options |
| Hard diagnosis, ordinary design | Sol `gpt-6.1-sol`, high | `sol-diagnose` or `lane.sh sol` | bounded packet |
| High-risk design and review | Astra `gpt-6-astra`, high **and** Opus (independent families) | `lane.sh astra[-review]`, `lane.sh opus[-review]` | packet or verdict from each |
| Adjudication | Astra xhigh (`ASTRA_EFFORT=xhigh`) with Opus as tie-break | `lane.sh astra-review` | final decision after two blocked reviews |
| Build, lint, render, CI status | normal tools | shell/CI | commands, exit status, evidence |

Luna performs every implementation edit. The orchestrator coordinates and validates; it never becomes the implementation worker. Reviewers get only the issue and the exact diff in a fresh context. Model IDs: Luna and Astra are `gpt-6-*`; Sol is `gpt-6.1-sol` (override with `SOL_MODEL`). Opus defaults to the `opus` alias (override `OPUS_MODEL`). A prompt that says "you are Luna" does not select a model; use the transport.

**Escalation:** one focused Luna diagnose/fix/validate cycle, then Sol, then Astra/Opus. High-risk work skips straight to Astra + Opus for design and review. Missing credentials, owner approval or runner capacity need that prerequisite, not a stronger model. Retry a transient tool failure once. Send the failing command, decisive output, attempted fix and exact unresolved question.

**High risk** is every path in `.github/exclusion-gate.yaml` (Talos, Flux root/bootstrap/components/templates, Cilium), rook-ceph, `*.sops.yaml`, and anything weakening exclusion-gate, health-gate, NetworkPolicy, CI or review. It needs Luna + Astra + Opus review and stops at an owner PR.

## Token budget

Measured on garmin-ai-coach and home-assistant-config: four fifths of spend is context resent around the work.

1. **Never poll with a model.** Wait once, blocking: `gh run watch <id> --exit-status`, `gh pr checks --watch`, one `wait_agent` with `timeout_ms` ≥ 1800000, or one `write_stdin` with `yield_time_ms` ≥ 300000. No status loops, sleep ladders or heartbeats.
2. **Keep threads short.** Finish one unit, write the Beads handoff, start a fresh thread. A worker gets one issue.
3. **Batch and narrow.** Batch independent commands; `git diff --stat`, `-q`, `tail`, `sed -n`. Never dump large files; find the section by issue id.
4. **Dispatch by reference.** Packets name issue, worktree, base SHA, branch, files, validation. Domain rules live in the agent TOML/MD and `workflow-specialists.md`.
5. **Parallelise work, not waiting.** Up to four disjoint Luna workers; overlapping writes are serial.
6. **Review incrementally.** Whole diff once; after a fixup review only the diff from the previously reviewed SHA.
7. **Verdicts go to a file.** `lane.sh` writes full verdicts to `.lane-out/<issue>/`; the orchestrator reads `verdict` plus `severity | confidence | title` per finding and opens a body only to act on it. Never read a subagent's raw transcript.

## Dispatch contract

Issue ids are `k8s-<id>`. Every implementation packet includes: issue ID, objective, acceptance criteria and agreed design; absolute worktree path, base SHA, branch, run id and domain label; Files/Steps/Verify; scope exclusions and safety constraints; exact validation commands and required evidence; the worker's authority boundary and stop conditions. Dispatch `luna-impl` with `fork_turns="none"`. Reviewers and scouts run fresh and never edit the reviewed worktree or write Beads. Only the release coordinator publishes.

## Transport gotchas (codex exec)

- Pass `-c 'notify=[]'`, redirect `</dev/null`, put every flag before the prompt, and always pass `-s` explicitly (`danger-full-access` for Luna, `read-only` for others). `lane.sh` does all of this.
- `codex exec resume` loses the original flags; re-pin model, effort, sandbox and `notify=[]`.
- Do not orchestrate through `/codex:rescue`; it loses the synchronous result.
- Luna runs unsandboxed with the owner's gh and kubeconfig, so the contract in `luna-impl.toml` is the only guard against merge, `gh workflow run` and mutating `kubectl`. Keep it strict.
- Claude lanes (`opus*`) are read-only by tool allowlist: no Edit/Write, kubectl limited to get/describe/logs/top.

## Completion and authority

1. **No agent merges** until Beads epic `k8s-zdb.6` (auto-merge go-live) ships. Agents open PRs; the owner merges. After that epic, the pipeline's own gates (exclusion-gate, AI review, health-gate) govern merging; this workflow does not bypass them.
2. **Admission gate for an owner-ready PR:** CI green (`validate`, `flux-diff`, exclusion-gate), fresh-context Luna approval on the exact head SHA, and for high-risk also Astra + Opus approval. Any new head SHA needs fresh CI and review.
3. **Merged is not deployed.** Close an issue only after Flux has reconciled the merge (`flux get ks/hr` Ready) and the Health Gate run for the merge commit passed. If the health-gate reverts, treat the issue as unfinished.
4. **Never** push to `main`, use `--admin`/`--auto`, dispatch workflows, reconcile/suspend Flux, or mutate Talos from a worker lane.
5. **Failure handling:** a failed Flux reconcile or health-gate revert freezes further PRs from the run and is reported as a Beads comment plus the final report. Prepare a revert PR; the owner merges it. No speculative reverts for ambiguous infrastructure failures: diagnose.
6. **Owner-only decisions:** credentials, spend, risk acceptance, Talos/Kubernetes upgrades, rook-ceph changes, and anything touching the revert-bot App.
7. Stop on: unhealthy baseline, changed/unreviewed SHA, unresolved findings, unclear risk classification, or missing access. Allow one CI repair attempt; two failures on an issue escalate to the owner.

## Durable handoff

`in_progress` means unfinished and assigned, not that a process runs. Beads is the record. At every transition and before handoff, post a Beads comment in this exact format with real values:

```text
Run/session: <identifier>; issue: <id>; state: <designing|implementing|validating|reviewing|awaiting-ci|awaiting-owner|awaiting-environment|ready-to-merge|done>
Location: <absolute worktree>; branch/base/head: <refs and SHAs>; PR: <URL or none>
Finished: <concrete delivered behavior>
Evidence: <commands, exit status, results, reviewed SHA, CI/cluster status>
Remaining: <unmet acceptance clauses; never just 'finish up'>
Next: <actor/model, exact action/command, working directory, prerequisite>
Blocker: <evidence and source of requirement, or none>
Resume when: <observable condition>; resume with: <$work id or $autopilot resume run-id>
```

For credentials or live operations, give the owner an action packet: exact commands, where to run them, expected output, and the `$work <id>` / `$autopilot resume <run-id>` to continue.
