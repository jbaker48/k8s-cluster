# claude-code — persistent remote Claude Code workspace

An always-on Claude Code pod in the `tools` namespace. A 20Gi `ceph-block` PVC is mounted at
`/home/developer`, so `~/.claude` state, git checkouts and the tmux session survive restarts.
A Tailscale sidecar puts the pod directly on the tailnet.

> **This app cannot go green until the steps in sections 1 and 2 are done by hand.**
> The container image does not exist yet, and the Doppler keys it needs are not set.

Image source: [`jbaker48/containers`](https://github.com/jbaker48/containers) →
`containers/claude-code/`.

---

## 1. Prerequisites

### 1a. Doppler secrets

The `claude-code-secret` ExternalSecret pulls every key with the `CLAUDE_CODE_` prefix from the
`doppler-secrets` ClusterSecretStore. Create these three:

| Key | Required | Where it comes from |
| --- | --- | --- |
| `CLAUDE_CODE_GITHUB_TOKEN` | **yes** | GitHub → Settings → Developer settings → Personal access tokens. Scopes: `repo`, `read:packages`, `workflow`. |
| `CLAUDE_CODE_TS_AUTHKEY` | **yes** | Tailscale admin console → Settings → Keys → Generate auth key. Must be **reusable** and **tagged `tag:k8s`**. |
| `CLAUDE_CODE_SSH_AUTHORIZED_KEYS` | optional | Contents of your local `~/.ssh/id_ed25519.pub`. Omit it and sshd/mosh are skipped with a warning; `kubectl exec` still works. |

`CLAUDE_CODE_GITHUB_TOKEN` is used twice: as the file the pod reads for `gh auth login`, and as
the GHCR pull credential (hence `read:packages`).

The PAT is delivered as a **file** at `/var/run/secrets/claude-code/github-token`, never as an
environment variable. A missing or empty file makes the container exit with a named error
rather than starting unauthenticated.

### 1b. Tailscale ACL — this is greenfield

**There is no Tailscale anywhere else in this cluster today.** This pod is the first tailnet
node, so the ACL almost certainly needs editing before it is reachable. In
**Tailscale admin console → Access Controls**:

```jsonc
{
  "tagOwners": {
    "tag:k8s": ["autogroup:admin"],
  },
  "acls": [
    {
      "action": "accept",
      "src": ["autogroup:member"],
      "dst": [
        "tag:k8s:2222",          // sshd — NOT 22, see the note below
        "tag:k8s:60000-61000",   // mosh (UDP)
      ],
    },
  ],
}
```

> **sshd listens on port 2222, not 22.** The container runs unprivileged as uid 1000 and cannot
> bind a privileged port. Open `2222/tcp` in the ACL, and pass `-p 2222` to every `ssh` command.

Without a `tagOwners` entry for `tag:k8s` the auth key is rejected outright and the sidecar
never comes up.

---

## 2. Publishing the image

The container changes are committed but **deliberately unpushed** on the `feat/claude-code`
branch of the containers repo. Merging that branch to `main` is what triggers the real GHCR
build, so it is left as your call:

```bash
git -C /Users/jbaker/git/containers push -u origin feat/claude-code
gh pr create --repo jbaker48/containers --base main --head feat/claude-code \
  --title "feat(claude-code): add persistent remote Claude Code workspace image" \
  --fill
# review, then merge — the merge is what publishes to GHCR
```

Watch the build under the repo's **Actions → Build and Publish Containers**. The workflow
resolves a version per matrix container, so `claude-code` is tagged from the npm dist-tag of
`@anthropic-ai/claude-code` (e.g. `2.1.232-<sha>`) and never from the Home Assistant version.

## 3. Pin the tag, and check package visibility

`helmrelease.yaml` currently ships `image.tag: latest` because the image did not exist when the
app was written. After the first successful build:

1. Replace `tag: latest` with the published `<version>-<sha>` tag and commit.
2. Check visibility at **github.com/users/jbaker48/packages → claude-code → Package settings**.
   If you make the package **public**, both `app/pullsecret.yaml` and the `imagePullSecrets`
   entry in `helmrelease.yaml` can be deleted.

---

## 4. First run — manual steps inside the pod

These are one-time and interactive; they cannot be automated because `/login` is a browser flow.

```bash
kubectl -n tools exec -it deploy/claude-code -c app -- bash
```

Then, in order:

1. `claude` — start the CLI, run `/login` and complete the browser authentication.
2. Accept the **workspace trust prompt** for `~/workspace`.
3. `tmux attach -t claude` — attach to the session the entrypoint created.
   (If it is somehow missing: `tmux new -s claude`.)
4. `claude remote-control` — enable remote control.
5. `/config` — turn on push notifications.

Because `~/.claude` lives on the PVC, none of this has to be repeated after a restart.

---

## 5. Access

**Primary — kubectl:**

```bash
kubectl -n tools exec -it deploy/claude-code -c app -- tmux attach -t claude
```

**Tailnet (needs section 1b's ACL and the optional SSH key):**

```bash
ssh -p 2222 developer@claude-code
mosh --ssh="ssh -p 2222" developer@claude-code
```

The sshd host keys are generated once and persisted to `~/.ssh/host_keys`, so the fingerprint is
stable across restarts and you will not get host-key warnings after a redeploy.

---

## 6. Verification checklist

```bash
# 1. Secrets synced from Doppler
kubectl -n tools get externalsecret claude-code-secret
#    STATUS should read SecretSynced

# 2. Volume bound at the right size
kubectl -n tools get pvc claude-code
#    STATUS Bound, CAPACITY 20Gi, STORAGECLASS ceph-block

# 3. Both containers running
kubectl -n tools get pods -l app.kubernetes.io/name=claude-code
#    READY should be 2/2

# 4. Tailscale logged in
kubectl -n tools logs deploy/claude-code -c tailscale | tail -20
#    look for a successful login and an assigned 100.x.y.z address

# 5. App startup narrated its decisions
kubectl -n tools logs deploy/claude-code -c app | tail -20
#    expect "GitHub CLI authenticated", "sshd listening on port 2222",
#    "tmux session 'claude' created", "Startup complete"
```

Finally, confirm the node appears in the **Tailscale admin console** as `claude-code` with
`tag:k8s`.

---

## 7. Known gotchas

- **The PVC masks `/home/developer`.** Anything baked into the image under that path is invisible
  at runtime. This is exactly why the Claude CLI is installed to `/opt/claude` and exposed via
  `/usr/local/bin/claude` — a CLI installed into the home directory would vanish the moment the
  volume mounted.
- **`strategy: Recreate` is mandatory, not stylistic.** The PVC is ReadWriteOnce, so a
  RollingUpdate would deadlock forever on a Multi-Attach error. A restart is therefore a full
  stop-then-start with brief downtime.
- **The entrypoint never overwrites `~/.claude`.** That is deliberate — it protects your state.
  The flip side is that a genuinely corrupted state directory must be cleared by hand:
  `kubectl -n tools exec -it deploy/claude-code -c app -- rm -rf ~/.claude`, then restart.
- **The GSD install is best-effort.** It runs after tmux and sshd are already up and is bounded
  by a timeout, so a dead npm registry warns and moves on instead of crash-looping the pod.
  Re-run `npx --yes get-shit-done-cc --claude --global` inside the pod to retry.
- **Liveness is `tmux has-session -t claude`.** If you deliberately kill the tmux session, the
  kubelet will restart the container.
- **A missing `CLAUDE_CODE_SSH_AUTHORIZED_KEYS` is not fatal**, but it silently means no ssh and
  no mosh. Check the app logs for the warning if tailnet access does not work.
