#!/usr/bin/env bash
# Pure bd reads; run from the repository root.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"

json() {
  local output
  if ! output=$(bd "$@" -n 0 --json 2>&1); then
    printf 'standup: Beads query failed: %s\n' "$output" >&2
    return 1
  fi
  printf '%s\n' "$output"
}

epics_json=$(json list --type=epic --status=open) || exit 1
open_json=$(json list --status=open --exclude-type=epic --exclude-label=autopilot) || exit 1
inprog_json=$(json list --status=in_progress --exclude-label=autopilot) || exit 1
ready_json=$(json ready --exclude-type=epic --exclude-label=autopilot) || exit 1
runs_json=$(json list --status=in_progress --label=autopilot) || exit 1

python3 - "$epics_json" "$open_json" "$inprog_json" "$ready_json" "$runs_json" <<'PY'
import json
import sys

epics, open_, inprog, ready, runs = (json.loads(a or "[]") for a in sys.argv[1:6])
ready_ids = {i["id"] for i in ready}
owner_labels = {"human", "needs-human", "owner-decision"}
owner = lambda i: bool(owner_labels.intersection(i.get("labels") or []))
agent = lambda i: next((l[6:] for l in i.get("labels") or [] if l.startswith("agent:")), "-")

def rank(issue):
    for label in issue.get("labels") or []:
        if label.startswith("rank-") and label[5:].isdigit():
            return int(label[5:])
    # This is the explicit fallback when this repository has no rank-NN labels.
    return int(issue.get("priority", 99))

epic_rank = {e["id"]: rank(e) for e in epics}
sort_key = lambda i: (epic_rank.get(i.get("parent"), rank(i)), i.get("priority", 99), i["id"])
children = {}
for i in open_ + inprog:
    children.setdefault(i.get("parent") or "", []).append(i)

def line(i):
    return f"  {i['id']:<32} P{i.get('priority', '?')} {i.get('issue_type', ''):<8} {agent(i):<16} {i['title'][:80]}"

recover = sorted((i for i in inprog if not owner(i) and not i.get("dependency_count")), key=sort_key)
blocked_claims = [i for i in inprog if not owner(i) and i.get("dependency_count")]
print(f"IN-PROGRESS RECOVERY  {len(inprog)} implementation issues; {len(recover)} without recorded dependencies, {len(blocked_claims)} with dependencies; {len(runs)} autopilot controls")
print("  Dependency-free is not proof of availability: check handoff, session liveness, PR/CI and live gates.")
for i in recover[:12]:
    print(line(i) + f"   updated={i.get('updated_at', '')[:10]}")
if len(recover) > 12:
    print(f"  ... {len(recover) - 12} more; inspect bd list --status=in_progress --limit=0")
if recover:
    print(f"  RECOVERY CANDIDATE: $work {recover[0]['id']} after ownership/artifact check")
print()

phase, gated = None, []
for e in sorted(epics, key=rank):
    kids = children.get(e["id"], [])
    agent_kids = [k for k in kids if not owner(k)]
    if not agent_kids:
        continue
    if any(k["id"] in ready_ids for k in agent_kids):
        phase = e
        break
    gated.append((e, [k["id"] for k in kids if owner(k)]))
if not phase:
    print("No epic has ready agent work. This does not establish completion.")
    print("Inspect standalone ready issues, in-progress work, dependencies and owner gates:")
    print("  bd ready --exclude-type=epic --exclude-label=human,needs-human,owner-decision,autopilot --limit=0")
    print("  bd list --status=in_progress --exclude-label=autopilot --limit=0")
    print("  bd blocked")
    print("Resume a verified recovery candidate before selecting new work.")
    sys.exit(0)

for e, owner_ids in gated:
    print(f"GATED  {e['id']}  rank {rank(e):02d}  {e['title'][:70]}   waits on: {', '.join(owner_ids) or 'blocked issues'}")
if gated:
    print()
kids = children.get(phase["id"], [])
print(f"CURRENT PHASE  {phase['id']}  rank {rank(phase):02d}  {phase['title']}")
print(f"  open children: {len(kids)}  (agent work {sum(not owner(k) for k in kids)}, owner items {sum(owner(k) for k in kids)})\n")

print("READY (agent work, this phase):")
for i in sorted((k for k in kids if k["id"] in ready_ids and not owner(k)), key=lambda k: (k.get("priority", 99), k["id"])):
    print(line(i))
print("\nIN PROGRESS (this phase; check `bd show` for the owner before touching):")
for i in (k for k in kids if k.get("status") == "in_progress"):
    print(line(i) + f"   assignee={i.get('assignee') or '-'}")
print("\nBLOCKED (this phase):")
for i in (k for k in kids if k["id"] not in ready_ids and k.get("status") != "in_progress"):
    print(line(i) + ("   [OWNER]" if owner(i) else ""))
print("\nWAITING ON THE OWNER (all phases):")
for i in sorted((k for k in open_ if owner(k)), key=lambda k: k["id"]):
    print(f"  {i['id']:<32} {i['title'][:90]}")
nxt = sorted((k for k in kids if k["id"] in ready_ids and not owner(k)), key=lambda k: (k.get("priority", 99), k["id"]))
if nxt:
    print(f"\nNEXT NEW ISSUE: $work {nxt[0]['id']}   (after recovery review; or $work {phase['id']} for the whole phase)")
PY
