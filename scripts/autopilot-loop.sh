#!/usr/bin/env bash
# Run $autopilot in fresh sessions until the requested Beads scope is done or an
# owner/environment prerequisite blocks all autonomous progress.
#
# Usage: scripts/autopilot-loop.sh <run-id>
#        DRY_RUN=1 scripts/autopilot-loop.sh <run-id>
#        ORCH=claude scripts/autopilot-loop.sh <run-id>   # Opus orchestrates
# Default orchestrator is Codex Sol 6.1 low. Stop with Ctrl-C; rerun with the
# same run id to continue.
set -euo pipefail

RUN_ID="${1:?usage: autopilot-loop.sh <run-id>}"
DRY_RUN="${DRY_RUN:-0}"
ORCH="${ORCH:-codex}"
LOG_DIR="${AUTOPILOT_LOG_DIR:-.autopilot-logs}"

cd "$(git rev-parse --show-toplevel)"
mkdir -p "$LOG_DIR"

branch="$(git branch --show-current)"
if [ "$branch" != "main" ]; then
  echo "refusing to start: on '$branch', expected main" >&2
  exit 1
fi
if [ -n "$(git status --porcelain --untracked-files=no | grep -v '^ M \.beads/' || true)" ]; then
  echo "refusing to start: working tree is dirty (beads bookkeeping excepted)" >&2
  git status --short >&2
  exit 1
fi

iteration=0
while [ -e "$LOG_DIR/${RUN_ID}-iter$((iteration + 1)).log" ] || \
    [ -e "$LOG_DIR/${RUN_ID}-iter$((iteration + 1)).txt" ]; do
  iteration=$((iteration + 1))
done
while :; do
  iteration=$((iteration + 1))
  out="$LOG_DIR/${RUN_ID}-iter${iteration}.txt"
  transcript="$LOG_DIR/${RUN_ID}-iter${iteration}.log"
  echo "=== iteration $iteration ($ORCH) -> $transcript ==="

  scope="Continue autonomous work until this fresh session reaches its natural context boundary; checkpoint every issue touched in Beads before ending."
  if [ "$DRY_RUN" = "1" ]; then
    scope="Dry run only: report the next issue and route; change nothing, publish nothing, then stop."
  fi

  prompt="Follow the autopilot skill at .agents/skills/autopilot/SKILL.md and resume run $RUN_ID (\$autopilot resume $RUN_ID). This is a fresh session: reconstruct owned work, branches, worktrees, PRs, reviewed SHAs and CI state from Beads and actual git/GitHub state, adopting existing work rather than restarting it. $scope Never push directly to main and never merge."

  case "$ORCH" in
    codex)
      if ! codex exec --dangerously-bypass-approvals-and-sandbox \
          -m "${SOL_MODEL:-gpt-6.1-sol}" -c model_reasoning_effort=low -o "$out" \
          "$prompt" </dev/null 2>&1 | tee "$transcript"; then
        echo "iteration $iteration exited non-zero; stopping. See $transcript" >&2
        exit 1
      fi
      ;;
    claude)
      if ! claude -p --model "${OPUS_MODEL:-opus}" --permission-mode acceptEdits \
          "$prompt" >"$out" 2>"$transcript"; then
        echo "iteration $iteration exited non-zero; stopping. See $transcript" >&2
        exit 1
      fi
      cat "$out"
      ;;
    *)
      echo "ORCH must be codex or claude" >&2
      exit 1
      ;;
  esac

  if [ "$DRY_RUN" = "1" ]; then
    exit 0
  fi
  if grep -qiE 'actionable work exhausted|no further autonomous work|no actionable work|scope remains blocked|nothing ready|backlog is blocked' "$out"; then
    echo "run reports no further autonomous work; stopping after iteration $iteration." >&2
    exit 0
  fi
done
