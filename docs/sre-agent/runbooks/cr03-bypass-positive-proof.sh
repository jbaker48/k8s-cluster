#!/usr/bin/env bash
#
# CR-03 POSITIVE PROOF — prove a legitimate bot-authored revert PR still bypasses
# the exclusion gate after commit 21c299d1 (05-REVIEW.md CR-03).
#
# Quick task 260812-oje. Replaces the deleted temp-cr03-bypass-positive-test.yaml
# workflow: workflow_dispatch only becomes available once a workflow file is on the
# default branch, so that harness could not run without first merging a throwaway
# test workflow into main. This script needs no merge at all.
#
# WHAT IT PROVES
#   exclusion-gate.yaml lines 46-52 require a bypass PR to be authored by
#   `k8s-cluster-revert-bot[bot]` with type `Bot`. Real revert PRs #1082-#1084 all
#   predate that requirement, so nothing yet proves a legitimate bot revert still
#   bypasses. If the check is wrong, the health-gate's own revert PRs get gated as
#   human-required and never self-merge — silently disabling auto-revert, the exact
#   safety net Phase 6 (auto-merge go-live) depends on.
#
#   Authorship is the whole point, so the PR MUST be created with a minted App
#   installation token via the REST API. Creating it with `gh` would attribute it to
#   your own human account and invalidate the test.
#
# SAFETY
#   Strictly non-destructive. It creates one branch and one PR and makes two commits
#   on that branch. It NEVER merges, NEVER deletes a branch, NEVER force-pushes, and
#   NEVER writes to main. Teardown is printed for you to run by hand, not automated.
#   The private key and the minted token are never echoed and never written outside a
#   0600 temp directory that is scrubbed on exit.
#
# USAGE
#   ./cr03-bypass-positive-proof.sh --dry-run     # print the plan, no writes
#   ./cr03-bypass-positive-proof.sh               # run the proof
#   ./cr03-bypass-positive-proof.sh --marker-only # resume at the final commit only
#
set -euo pipefail

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
REPO_OWNER="jbaker48"
REPO_NAME="k8s-cluster"
REPO="${REPO_OWNER}/${REPO_NAME}"
BRANCH="auto-revert/bypass-positive-test"
LABEL="automated-revert"

# Repo-root path: matches NONE of the three categories in .github/exclusion-gate.yaml
# (every glob there is under kubernetes/). Used for the clean baseline run.
BASELINE_PATH="BYPASS-POSITIVE-TEST.md"

# Matches BOTH `talos` (kubernetes/bootstrap/talos/**) and `kubernetes-core`
# (kubernetes/bootstrap/**). Committing this second is what makes the verdict run
# unambiguous: two independent exclusion reasons that the bypass must suppress.
# Inert by construction: talhelper reads only talconfig.yaml / talenv.yaml /
# talsecret*, and kubernetes/bootstrap/ is outside Flux's reconciled tree.
MARKER_PATH="kubernetes/bootstrap/talos/BYPASS-POSITIVE-TEST-MARKER.md"

# exclusion-gate.yaml hardcodes this login. If the App's slug differs, the gate can
# never recognise it and this script says so rather than producing a mystery FAIL.
EXPECTED_AUTHOR="k8s-cluster-revert-bot[bot]"

API="https://api.github.com"

DRY_RUN=false
MARKER_ONLY=false

# ---------------------------------------------------------------------------
# Output helpers
# ---------------------------------------------------------------------------
if [ -t 1 ]; then
    B=$'\033[1m'; R=$'\033[31m'; G=$'\033[32m'; Y=$'\033[33m'; C=$'\033[36m'; N=$'\033[0m'
else
    B=""; R=""; G=""; Y=""; C=""; N=""
fi

log()  { printf '%s\n' "$*"; }
info() { printf '%s\n' "${C}$*${N}"; }
ok()   { printf '%s\n' "${G}$*${N}"; }
warn() { printf '%s\n' "${Y}WARNING: $*${N}" >&2; }
die()  { printf '%s\n' "${R}ERROR: $*${N}" >&2; exit 1; }

hr() { printf '%s\n' "------------------------------------------------------------------"; }

banner() {
    printf '\n'
    hr
    printf '%s\n' "${B}$*${N}"
    hr
}

# Announce the effect of every API write BEFORE it happens.
effect() { printf '%s\n' "  ${B}->${N} $*"; }

# ---------------------------------------------------------------------------
# Secure scratch space — key and token live here only, scrubbed on any exit
# ---------------------------------------------------------------------------
SECURE_DIR=""
cleanup() {
    if [ -n "${SECURE_DIR}" ] && [ -d "${SECURE_DIR}" ]; then
        find "${SECURE_DIR}" -type f -exec rm -f {} + 2>/dev/null || true
        rm -rf "${SECURE_DIR}" 2>/dev/null || true
    fi
}
trap cleanup EXIT INT TERM

make_secure_dir() {
    local old_umask
    old_umask=$(umask)
    umask 077
    SECURE_DIR=$(mktemp -d "${TMPDIR:-/tmp}/cr03-proof.XXXXXX")
    umask "${old_umask}"
    KEY_FILE="${SECURE_DIR}/app-key.pem"
    CURL_CFG="${SECURE_DIR}/curl.cfg"
}

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
while [ $# -gt 0 ]; do
    case "$1" in
        --dry-run)     DRY_RUN=true ;;
        --marker-only) MARKER_ONLY=true ;;
        -h|--help)
            sed -n '2,45p' "$0" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        *) die "Unknown argument: $1 (try --help)" ;;
    esac
    shift
done

# ---------------------------------------------------------------------------
# Preflight: tooling
# ---------------------------------------------------------------------------
banner "CR-03 positive proof — preflight"

for cmd in openssl curl jq; do
    command -v "${cmd}" >/dev/null 2>&1 || die "${cmd} is required but not installed."
done
ok "Tooling present: openssl, curl, jq"

# LibreSSL's dgst is fine for RSA-SHA256, but report which flavor is in use so a
# signature failure is diagnosable.
log "  openssl: $(openssl version)"

# ---------------------------------------------------------------------------
# Preflight: credentials
# ---------------------------------------------------------------------------
CREDS_MISSING_MSG=$(cat <<'CREDS'
Credentials not found in the environment.

This script needs the revert-bot GitHub App's ID and private key. They live in
Doppler (the same values the health-gate workflow reads as the REVERT_BOT_APP_ID
and REVERT_BOT_APP_PRIVATE_KEY secrets in the `health-gate` environment). They are
NOT in the cluster - no ExternalSecret or Secret references REVERT_BOT - so they
must come from Doppler.

Option 1 - doppler CLI (not currently installed; `brew install dopplerhq/cli/doppler`):

    export REVERT_BOT_APP_ID="$(doppler secrets get REVERT_BOT_APP_ID --plain)"
    export REVERT_BOT_APP_PRIVATE_KEY="$(doppler secrets get REVERT_BOT_APP_PRIVATE_KEY --plain)"

Option 2 - one-time copy from the Doppler web UI (no CLI needed).
  Preferred, because it keeps the multi-line PEM out of your shell history:

    # Paste the PEM into a file, then:
    chmod 600 ~/revert-bot-key.pem
    export REVERT_BOT_APP_ID="123456"
    export REVERT_BOT_APP_PRIVATE_KEY_FILE="$HOME/revert-bot-key.pem"

  Or, if you must use the variable directly, use a quoted heredoc so newlines
  survive (leading space keeps it out of history in most shells):

     read -r -d '' REVERT_BOT_APP_PRIVATE_KEY <<'PEM'
    -----BEGIN RSA PRIVATE KEY-----
    ...
    -----END RSA PRIVATE KEY-----
    PEM
     export REVERT_BOT_APP_PRIVATE_KEY

Delete the key file when you are done. This script never writes it to disk itself.
CREDS
)

APP_ID="${REVERT_BOT_APP_ID:-}"
HAVE_CREDS=true
[ -n "${APP_ID}" ] || HAVE_CREDS=false
if [ -z "${REVERT_BOT_APP_PRIVATE_KEY:-}" ] && [ -z "${REVERT_BOT_APP_PRIVATE_KEY_FILE:-}" ]; then
    HAVE_CREDS=false
fi

if [ "${HAVE_CREDS}" = false ]; then
    if [ "${DRY_RUN}" = true ]; then
        warn "No credentials in the environment - dry-run will print the plan but cannot verify App identity."
        log ""
        log "${CREDS_MISSING_MSG}"
    else
        log ""
        die "${CREDS_MISSING_MSG}"
    fi
else
    make_secure_dir

    # Normalize the private key into a 0600 PEM file. Three accepted shapes:
    #   1. REVERT_BOT_APP_PRIVATE_KEY_FILE pointing at a PEM
    #   2. REVERT_BOT_APP_PRIVATE_KEY holding a PEM (real newlines OR literal \n)
    #   3. REVERT_BOT_APP_PRIVATE_KEY holding a base64-encoded PEM
    # Shape 2's literal-\n case and shape 3 are the formats that already bit this
    # project once (Plan 05-02 credential gap), so both are handled explicitly.
    if [ -n "${REVERT_BOT_APP_PRIVATE_KEY_FILE:-}" ]; then
        [ -r "${REVERT_BOT_APP_PRIVATE_KEY_FILE}" ] \
            || die "REVERT_BOT_APP_PRIVATE_KEY_FILE is set but not readable: ${REVERT_BOT_APP_PRIVATE_KEY_FILE}"
        cat -- "${REVERT_BOT_APP_PRIVATE_KEY_FILE}" > "${KEY_FILE}"
        KEY_SOURCE="file ${REVERT_BOT_APP_PRIVATE_KEY_FILE}"
    elif printf '%s' "${REVERT_BOT_APP_PRIVATE_KEY}" | grep -q 'PRIVATE KEY'; then
        # %b expands literal \n; PEM bodies contain no backslashes, so this is safe
        # whether the value arrived with real newlines or escaped ones.
        printf '%b\n' "${REVERT_BOT_APP_PRIVATE_KEY}" > "${KEY_FILE}"
        KEY_SOURCE="REVERT_BOT_APP_PRIVATE_KEY (PEM)"
    else
        if ! printf '%s' "${REVERT_BOT_APP_PRIVATE_KEY}" \
             | tr -d '\n' | openssl base64 -d -A > "${KEY_FILE}" 2>/dev/null; then
            die "REVERT_BOT_APP_PRIVATE_KEY is neither a PEM nor valid base64. Re-copy it from Doppler."
        fi
        KEY_SOURCE="REVERT_BOT_APP_PRIVATE_KEY (base64-encoded PEM)"
    fi
    chmod 600 "${KEY_FILE}"

    openssl pkey -in "${KEY_FILE}" -noout 2>/dev/null \
        || die "The private key could not be parsed by openssl. It is not a valid RSA private key.
Re-copy it from Doppler - the most common cause is a PEM whose newlines were
flattened into literal \\n or lost entirely when pasted into a variable."

    ok "App ID present; private key parsed OK (source: ${KEY_SOURCE})"
    log "  Key and token live only in ${SECURE_DIR} (0600) and are scrubbed on exit."
fi

# ---------------------------------------------------------------------------
# API plumbing
# ---------------------------------------------------------------------------
b64url() { openssl base64 -A | tr '+/' '-_' | tr -d '='; }

# RS256 JWT, signed with openssl - no pip/npm dependency.
mint_jwt() {
    local now iat exp header payload signing_input sig
    now=$(date +%s)
    # iat backdated 60s to tolerate clock skew; GitHub caps exp at 10 minutes.
    iat=$((now - 60))
    exp=$((now + 540))
    header='{"alg":"RS256","typ":"JWT"}'
    # A numeric App ID is emitted unquoted, matching GitHub's documented example.
    # A client id (e.g. Iv23xxxx) is not numeric and must stay a JSON string.
    if printf '%s' "${APP_ID}" | grep -qE '^[0-9]+$'; then
        payload=$(printf '{"iat":%s,"exp":%s,"iss":%s}' "${iat}" "${exp}" "${APP_ID}")
    else
        payload=$(printf '{"iat":%s,"exp":%s,"iss":"%s"}' "${iat}" "${exp}" "${APP_ID}")
    fi
    signing_input="$(printf '%s' "${header}" | b64url).$(printf '%s' "${payload}" | b64url)"
    sig=$(printf '%s' "${signing_input}" | openssl dgst -sha256 -sign "${KEY_FILE}" -binary | b64url)
    printf '%s.%s' "${signing_input}" "${sig}"
}

# Auth header goes in a 0600 curl config file, never on the command line - argv is
# world-readable via ps, so a token passed as an argument would leak to any local
# process.
write_auth_cfg() {
    local old_umask
    old_umask=$(umask)
    umask 077
    printf 'header = "Authorization: Bearer %s"\n' "$1" > "${CURL_CFG}"
    umask "${old_umask}"
}

HTTP_CODE=""
API_BODY=""
api() {
    local method="$1" path="$2" body="${3:-}"
    local raw
    if [ -n "${body}" ]; then
        raw=$(curl -sS -X "${method}" -K "${CURL_CFG}" \
            -H 'Accept: application/vnd.github+json' \
            -H 'X-GitHub-Api-Version: 2022-11-28' \
            -H 'Content-Type: application/json' \
            --data-binary "${body}" \
            -w '\n%{http_code}' "${API}${path}")
    else
        raw=$(curl -sS -X "${method}" -K "${CURL_CFG}" \
            -H 'Accept: application/vnd.github+json' \
            -H 'X-GitHub-Api-Version: 2022-11-28' \
            -w '\n%{http_code}' "${API}${path}")
    fi
    HTTP_CODE=$(printf '%s' "${raw}" | tail -n1)
    API_BODY=$(printf '%s' "${raw}" | sed '$d')
}

api_err() {
    printf '%s' "${API_BODY}" | jq -r '.message // "no message"' 2>/dev/null || echo "unparseable response"
}

expect_2xx() {
    case "${HTTP_CODE}" in
        2*) return 0 ;;
        *)  die "$1 (HTTP ${HTTP_CODE}: $(api_err))" ;;
    esac
}

json_b64_file() { openssl base64 -A; }

# ---------------------------------------------------------------------------
# Dry run without credentials: print the plan and stop
# ---------------------------------------------------------------------------
print_plan() {
    banner "PLAN (no writes performed)"
    log "Repository: ${REPO}"
    log "Branch:     ${BRANCH}"
    log ""
    log "1. GET  /repos/${REPO}/installation                 - resolve installation id"
    log "2. POST /app/installations/{id}/access_tokens        - mint installation token"
    log "3. GET  /repos/${REPO}/git/ref/heads/${BRANCH}"
    log "                                                     - must 404 (refuse to reuse)"
    log "4. GET  /repos/${REPO}/git/ref/heads/main            - resolve main tip sha"
    log "5. POST /repos/${REPO}/git/refs                      - create ${BRANCH}"
    log "6. PUT  /repos/${REPO}/contents/${BASELINE_PATH}"
    log "                                                     - commit NON-excluded file"
    log "7. POST /repos/${REPO}/pulls                         - open PR (as the App)"
    log "         => RUN 1 fires: clean baseline, NOT the verdict"
    log "8. GET  /repos/${REPO}/pulls/{n}                     - assert author is ${EXPECTED_AUTHOR} / Bot"
    log "9. POST /repos/${REPO}/issues/{n}/labels             - add '${LABEL}'"
    log "         (no retrigger: bare pull_request_target does not include 'labeled')"
    log "10. PUT /repos/${REPO}/contents/${MARKER_PATH}"
    log "                                                     - commit EXCLUDED file"
    log "         => RUN 2 fires via synchronize: THIS IS THE VERDICT"
    log ""
    log "Then the script prints teardown commands. It does NOT merge, delete, or"
    log "force-push anything, and never writes to main."
}

if [ "${DRY_RUN}" = true ] && [ "${HAVE_CREDS}" = false ]; then
    print_plan
    banner "DRY RUN COMPLETE (credentials not verified)"
    exit 0
fi

# ---------------------------------------------------------------------------
# Mint the installation token
# ---------------------------------------------------------------------------
banner "Minting the revert-bot App installation token"

JWT=$(mint_jwt)
write_auth_cfg "${JWT}"
unset JWT

effect "GET /app - confirm which App these credentials belong to"
api GET "/app"
# GitHub returns the same generic "A JSON web token could not be decoded" for a
# wrong App ID, a mismatched key, and a rotated key - verified empirically - so the
# message below enumerates all three rather than guessing.
expect_2xx "Could not authenticate as the App.
GitHub's message is generic here; it means one of:
  - REVERT_BOT_APP_ID is not this App's id
  - the private key does not belong to that App
  - the key was rotated in Doppler and your copy is stale
  - your system clock is far enough off that the JWT's iat/exp are invalid
Re-copy BOTH values from Doppler and retry"
APP_SLUG=$(printf '%s' "${API_BODY}" | jq -r '.slug')
APP_NAME=$(printf '%s' "${API_BODY}" | jq -r '.name')
ok "Authenticated as App: ${APP_NAME} (slug: ${APP_SLUG})"

DERIVED_AUTHOR="${APP_SLUG}[bot]"
if [ "${DERIVED_AUTHOR}" != "${EXPECTED_AUTHOR}" ]; then
    warn "This App's PR author would be '${DERIVED_AUTHOR}', but exclusion-gate.yaml line 50"
    warn "hardcodes '${EXPECTED_AUTHOR}'. The bypass CANNOT match, so any FAIL you see would"
    warn "be a credential mismatch, not a CR-03 regression. Confirm you are using the"
    warn "revert-bot App's credentials before continuing."
fi

effect "GET /repos/${REPO}/installation - resolve the installation id"
api GET "/repos/${REPO}/installation"
expect_2xx "Could not resolve the App's installation on ${REPO}. The App may not be installed on this repository"
INSTALL_ID=$(printf '%s' "${API_BODY}" | jq -r '.id')
ok "Installation id: ${INSTALL_ID}"

effect "POST /app/installations/${INSTALL_ID}/access_tokens - mint installation token"
api POST "/app/installations/${INSTALL_ID}/access_tokens"
expect_2xx "Could not mint an installation token"
TOKEN=$(printf '%s' "${API_BODY}" | jq -r '.token')
[ -n "${TOKEN}" ] && [ "${TOKEN}" != "null" ] || die "Installation token response contained no token."
write_auth_cfg "${TOKEN}"
unset TOKEN
ok "Installation token minted (never printed; held in ${CURL_CFG}, mode 0600)"

# ---------------------------------------------------------------------------
# Preflight: refuse to reuse leftovers
# ---------------------------------------------------------------------------
banner "Preflight — refuse to reuse leftover state"

if [ "${MARKER_ONLY}" = false ]; then
    effect "GET /repos/${REPO}/git/ref/heads/${BRANCH} - expect 404"
    api GET "/repos/${REPO}/git/ref/heads/${BRANCH}"
    if [ "${HTTP_CODE}" = "200" ]; then
        die "Branch ${BRANCH} already exists on the remote.
A previous run left it behind. Delete it first, then re-run:
    git push origin --delete ${BRANCH}
This script will not force-push or reuse an existing branch.
(If the branch AND its PR AND the label are all already in place and you only
need the final commit, re-run with --marker-only.)"
    fi
    ok "No leftover branch."
fi

effect "GET /repos/${REPO}/pulls?head=${REPO_OWNER}:${BRANCH}&state=open"
api GET "/repos/${REPO}/pulls?head=${REPO_OWNER}:${BRANCH}&state=open"
expect_2xx "Could not list PRs"
OPEN_COUNT=$(printf '%s' "${API_BODY}" | jq 'length')

if [ "${MARKER_ONLY}" = true ]; then
    [ "${OPEN_COUNT}" = "1" ] || die "--marker-only needs exactly one open PR from ${BRANCH}; found ${OPEN_COUNT}."
    PR_NUMBER=$(printf '%s' "${API_BODY}" | jq -r '.[0].number')
    PR_URL=$(printf '%s' "${API_BODY}" | jq -r '.[0].html_url')
    ok "Resuming with PR #${PR_NUMBER}"
else
    [ "${OPEN_COUNT}" = "0" ] || die "An open PR from ${BRANCH} already exists. Close it (WITHOUT merging) and delete the branch, then re-run."
    ok "No leftover open PR."
fi

if [ "${DRY_RUN}" = true ]; then
    print_plan
    banner "DRY RUN COMPLETE — credentials and preflight verified, no writes performed"
    exit 0
fi

# ---------------------------------------------------------------------------
# Steps 1-3: branch, baseline commit, PR  (skipped by --marker-only)
# ---------------------------------------------------------------------------
if [ "${MARKER_ONLY}" = false ]; then

    banner "Step 1 — create branch ${BRANCH} from main"

    effect "GET /repos/${REPO}/git/ref/heads/main - resolve tip"
    api GET "/repos/${REPO}/git/ref/heads/main"
    expect_2xx "Could not read main's ref"
    MAIN_SHA=$(printf '%s' "${API_BODY}" | jq -r '.object.sha')
    ok "main tip: ${MAIN_SHA}"

    effect "POST /repos/${REPO}/git/refs - create refs/heads/${BRANCH} at ${MAIN_SHA}"
    api POST "/repos/${REPO}/git/refs" \
        "$(jq -nc --arg ref "refs/heads/${BRANCH}" --arg sha "${MAIN_SHA}" '{ref:$ref, sha:$sha}')"
    expect_2xx "Could not create the branch"
    ok "Branch created."

    banner "Step 2 — commit a NON-excluded file (clean baseline)"

    BASELINE_BODY=$(cat <<'EOF'
# CR-03 bypass positive-proof — baseline file — DO NOT MERGE

Temporary test artifact (GSD quick task 260812-oje).

This file sits at the repository root, which matches NONE of the exclusion
categories in `.github/exclusion-gate.yaml` (every glob there is under
`kubernetes/`). Its only job is to open a PR whose first exclusion-gate run is a
clean baseline, so that the later run against an excluded path is an unambiguous
verdict on the bypass.

Never merge this. Close the PR and delete the branch.
EOF
)
    effect "PUT /repos/${REPO}/contents/${BASELINE_PATH} on ${BRANCH} (non-excluded path)"
    api PUT "/repos/${REPO}/contents/${BASELINE_PATH}" \
        "$(jq -nc \
            --arg message "test: CR-03 positive-proof baseline (do not merge)" \
            --arg content "$(printf '%s\n' "${BASELINE_BODY}" | json_b64_file)" \
            --arg branch "${BRANCH}" \
            '{message:$message, content:$content, branch:$branch}')"
    expect_2xx "Could not commit ${BASELINE_PATH}"
    ok "Committed ${BASELINE_PATH}"

    banner "Step 3 — open the PR AS THE APP"

    PR_BODY=$(cat <<'EOF'
**TEST ARTIFACT - DO NOT MERGE. Close without merging once verified.**

CR-03 positive proof (GSD quick task 260812-oje): confirms that a legitimate
`k8s-cluster-revert-bot[bot]`-authored revert PR still bypasses the exclusion gate
after commit 21c299d1 added the PR-author identity check (05-REVIEW.md CR-03).

Real revert PRs #1082-#1084 all predate that commit, so nothing yet proved the
positive path still works. If it does not, the health-gate's own revert PRs would be
gated as human-required and never self-merge, silently disabling auto-revert.

Sequence: this PR's FIRST exclusion-gate run is a clean baseline (root-level file,
no exclusion category, unpaused circuit breaker). The `automated-revert` label is
then applied, and a second commit touching `kubernetes/bootstrap/talos/` fires
`synchronize` - that run is the verdict.
EOF
)
    effect "POST /repos/${REPO}/pulls - open PR ${BRANCH} -> main (authored by the App)"
    api POST "/repos/${REPO}/pulls" \
        "$(jq -nc \
            --arg title "TEST ARTIFACT - DO NOT MERGE: CR-03 bypass positive proof" \
            --arg head "${BRANCH}" \
            --arg base "main" \
            --arg body "${PR_BODY}" \
            '{title:$title, head:$head, base:$base, body:$body, draft:false}')"
    expect_2xx "Could not open the PR"
    PR_NUMBER=$(printf '%s' "${API_BODY}" | jq -r '.number')
    PR_URL=$(printf '%s' "${API_BODY}" | jq -r '.html_url')
    PR_AUTHOR=$(printf '%s' "${API_BODY}" | jq -r '.user.login')
    PR_AUTHOR_TYPE=$(printf '%s' "${API_BODY}" | jq -r '.user.type')
    ok "Opened PR #${PR_NUMBER}: ${PR_URL}"

    # The single most important assertion in this script. If authorship is wrong the
    # entire test is meaningless, and a later "FAIL" would be a false alarm.
    log ""
    log "${B}PR authorship (this is what exclusion-gate.yaml:49-50 asserts on):${N}"
    log "  user.login = ${PR_AUTHOR}"
    log "  user.type  = ${PR_AUTHOR_TYPE}"
    if [ "${PR_AUTHOR}" != "${EXPECTED_AUTHOR}" ] || [ "${PR_AUTHOR_TYPE}" != "Bot" ]; then
        die "PR authorship is NOT the revert bot (expected ${EXPECTED_AUTHOR} / Bot).
The test cannot be valid - any result would be meaningless. This usually means the
PR was created with a user token rather than the App installation token.
Close PR #${PR_NUMBER} without merging and delete ${BRANCH} before retrying."
    fi
    ok "Authorship correct: a genuine bot-authored PR."

    banner "RUN 1 — clean baseline. THIS IS NOT THE VERDICT."
    log "The exclusion-gate run now firing on PR #${PR_NUMBER} (event: opened) should show:"
    log "  - NOT excluded: ${BASELINE_PATH} matches no exclusion category"
    log "  - buckets resolve to [\"unscoped\"] (zero kubernetes/apps/** paths touched)"
    log "  - circuit breaker NOT paused (state on main is {})"
    log "  => expect NO 'gate/human-required' label and NO exclusion comment."
    log ""
    log "Its purpose is to establish that this PR is unremarkable BEFORE the label and"
    log "the excluded path are introduced. If this baseline is already labelled,"
    log "something unrelated is wrong - investigate before trusting run 2."
    log ""
    log "Let it finish, then continue:"
    log "  ${C}gh pr checks --repo ${REPO} ${PR_NUMBER}${N}"
fi

# ---------------------------------------------------------------------------
# Step 4: label
# ---------------------------------------------------------------------------
banner "Step 4 — apply the '${LABEL}' label"

log "Adding the label does NOT retrigger the gate: exclusion-gate.yaml's trigger is a"
log "bare 'pull_request_target', whose default activity types are opened/reopened/"
log "synchronize - 'labeled' is not among them. The next commit is what retriggers."
log ""

effect "POST /repos/${REPO}/issues/${PR_NUMBER}/labels - add '${LABEL}'"
api POST "/repos/${REPO}/issues/${PR_NUMBER}/labels" \
    "$(jq -nc --arg l "${LABEL}" '{labels:[$l]}')"
if ! case "${HTTP_CODE}" in 2*) true ;; *) false ;; esac; then
    warn "Could not add the label as the App (HTTP ${HTTP_CODE}: $(api_err))."
    log ""
    log "The label's applier is irrelevant to the gate - only its presence is checked."
    log "Apply it yourself, then resume at the final commit:"
    log "  ${C}gh pr edit --repo ${REPO} ${PR_NUMBER} --add-label ${LABEL}${N}"
    log "  ${C}$0 --marker-only${N}"
    exit 1
fi

# Verify presence rather than trusting the POST: a missing label would make the
# bypass legitimately decline, producing a false FAIL on the verdict run.
effect "GET /repos/${REPO}/pulls/${PR_NUMBER} - verify the label is really present"
api GET "/repos/${REPO}/pulls/${PR_NUMBER}"
expect_2xx "Could not re-read the PR"
if ! printf '%s' "${API_BODY}" | jq -e --arg l "${LABEL}" '.labels | map(.name) | index($l)' >/dev/null; then
    die "The '${LABEL}' label is not present on PR #${PR_NUMBER} after the add call.
Without it the bypass would correctly decline and the verdict run would be a false FAIL.
Apply it manually, then re-run: $0 --marker-only"
fi
ok "Label '${LABEL}' confirmed present."

# ---------------------------------------------------------------------------
# Step 5: the verdict commit
# ---------------------------------------------------------------------------
banner "Step 5 — commit an EXCLUDED file to fire the verdict run"

MARKER_BODY=$(cat <<'EOF'
# CR-03 bypass positive-proof marker — DO NOT MERGE

Temporary test artifact (GSD quick task 260812-oje).

This path matches BOTH the `talos` and `kubernetes-core` categories in
`.github/exclusion-gate.yaml`. If the automated-revert bypass engages as it should,
the exclusion gate skips path evaluation entirely and says nothing about these two
categories. If the bypass is broken, the gate emits an unmistakable comment listing
both reasons - which is the FAIL signal this test is looking for.

Inert by construction: talhelper reads only `talconfig.yaml`, `talenv.yaml` and
`talsecret*`, and `kubernetes/bootstrap/` sits outside Flux's reconciled tree.

Never merge this. Close the PR and delete the branch.
EOF
)

effect "PUT /repos/${REPO}/contents/${MARKER_PATH} on ${BRANCH} (EXCLUDED path -> fires synchronize)"
api PUT "/repos/${REPO}/contents/${MARKER_PATH}" \
    "$(jq -nc \
        --arg message "test: CR-03 positive-proof marker on an excluded path (do not merge)" \
        --arg content "$(printf '%s\n' "${MARKER_BODY}" | json_b64_file)" \
        --arg branch "${BRANCH}" \
        '{message:$message, content:$content, branch:$branch}')"
expect_2xx "Could not commit ${MARKER_PATH}"
ok "Committed ${MARKER_PATH} - 'synchronize' fired."

# ---------------------------------------------------------------------------
# Verdict + teardown
# ---------------------------------------------------------------------------
banner "RUN 2 — THIS IS THE VERDICT"

log "PR: ${PR_URL}"
log ""
log "Watch the exclusion-gate run for the LATEST commit (event: synchronize), not the"
log "baseline run:"
log "  ${C}gh run list --repo ${REPO} --workflow 'Exclusion Gate' --limit 3${N}"
log "  ${C}gh pr view --repo ${REPO} ${PR_NUMBER} --json labels,comments \\
    --jq '{labels: [.labels[].name], comments: [.comments[].body]}'${N}"
log ""
log "${G}${B}PASS - the identity check is correct, a real bot revert still bypasses${N}"
log "  - Comment present: \"Automated health-gate revert recognized\""
log "  - NO comment \"Human merge required - this PR touches cluster-critical"
log "    infrastructure\", even though the PR now touches two excluded categories"
log "  - NO new 'gate/human-required' label"
log "  - Post-bypass steps all SKIPPED: Fetch exclusion config from base branch,"
log "    Build paths-filter map, Evaluate path filters, Compute excluded flag and"
log "    reasons, Fetch circuit-breaker state from base branch, Resolve touched app"
log "    buckets, Evaluate circuit-breaker pause state"
log ""
log "${R}${B}FAIL - regression; auto-revert is silently broken and Phase 6 must not proceed${N}"
log "  - The \"Human merge required\" exclusion comment appears listing the 'talos'"
log "    and 'kubernetes-core' reasons, and/or"
log "  - 'gate/human-required' is applied, and/or"
log "  - the post-bypass steps show as EXECUTED rather than skipped"
log ""
log "  A FAIL means the PR_AUTHOR_LOGIN/PR_AUTHOR_TYPE check added in 21c299d1 is"
log "  rejecting a legitimately bot-authored PR, so the health-gate's own revert PRs"
log "  would be gated as human-required and never self-merge."

banner "TEARDOWN — run these yourself (this script deliberately does not)"

log "Close WITHOUT merging, then delete the branch:"
log "  ${C}gh pr close --repo ${REPO} ${PR_NUMBER} --delete-branch${N}"
log ""
log "Confirm it was never merged:"
log "  ${C}gh pr view --repo ${REPO} ${PR_NUMBER} --json state,mergedAt${N}"
log ""
log "Confirm neither marker file ever reached main (both must be 404 / 'Not Found'):"
log "  ${C}gh api repos/${REPO}/contents/${BASELINE_PATH}?ref=main${N}"
log "  ${C}gh api repos/${REPO}/contents/${MARKER_PATH}?ref=main${N}"
log ""
log "Confirm the branch is gone:"
log "  ${C}git ls-remote --heads origin ${BRANCH}${N}   # must print nothing"
log ""
log "Then record the outcome in:"
log "  docs/sre-agent/runbooks/live-verification-2026-10.md  (section 2)"
log "  docs/sre-agent/WINDOWS.md  (entry #8)"
log ""
log "Finally, unset the credentials from your shell and delete any key file you created:"
log "  ${C}unset REVERT_BOT_APP_ID REVERT_BOT_APP_PRIVATE_KEY REVERT_BOT_APP_PRIVATE_KEY_FILE${N}"

banner "DONE — nothing was merged, deleted, force-pushed, or written to main"
