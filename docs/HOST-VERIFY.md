# Host verification checklist

The agent that built devenv cannot run `sbx`, so these checks run on the host
(WSL2 today, native Linux later). Run them in order and paste each block's
output back into the PR. Commands marked **(in sandbox)** run inside the new
`dev` sandbox: open a shell pane in herdr (`ctrl+b`, then the new-pane key),
or run them from the host with `cd ~/devenv && sbx env exec -- bash -lc '…'`.

Where a check fails, its fallback is listed. Don't apply fallbacks yourself;
report the output and the agent will push the fix to this PR.

The old `claude-dev` sandbox keeps running alongside `dev` until the
switchover (spec §9, Phase 5). They no longer share a workspace: `claude-dev`
mounts `~/dev`, and `dev` mounts `~/devenv/dev`.

While this PR is open, the sandbox is built from its branch:
`--kit-arg ref=initial-setup` makes the kit clone that branch instead of
`main`. Drop the flag once the PR is merged.

---

## 0. Moving from the first layout (once)

The first version mounted `~/devenv` read-only and used `~/dev` as the
workspace. The `dev` sandbox built that way has to be removed before building
the new one (workspaces and kits only change at create):

```sh
cd ~/devenv && sbx env rm        # approve; deletes the sandbox and its scoped secrets, not ~/dev
git -C ~/devenv pull             # the branch with the new layout
```

What `dev` left in `~/dev` (`~/dev/firstmate`, `~/dev/.devenv-state`) is no
longer used; the new sandbox starts a fresh Firstmate home in
`~/devenv/dev/firstmate`. Leave the old folders for now (`claude-dev` still
mounts `~/dev`); they go in Phase 5.

## 1. Prerequisites

```sh
sbx version
sbx version --json | jq '{client: .client.version, server: .server.state}'
sbx ls
sbx policy ls
```

Expected: sbx **0.45.x** or newer; `server` is `running`; `sbx ls` lists
`claude-dev` (so you are logged in); `sbx policy ls` prints rules (the
`balanced` baseline). If `sbx ls` complains about login, run `sbx login`.
If the policy list is empty, run `sbx policy init balanced`.

## 2. Clone devenv

```sh
git clone -b initial-setup https://github.com/digigrant/devenv ~/devenv   # after merge: without -b
ls ~/devenv
```

Expected: the repo files in `~/devenv`, outside `~/dev`. (Skip if you already
have it; step 0 pulled it.)

## 3. Secrets

The secrets live in Infisical (README: Secrets). Once per machine, store its
Infisical login in the keyring. §8.1 lists where each of the three values is
on the Infisical website.

```sh
sudo apt-get install -y jq curl libsecret-tools
~/devenv/bin/devenv secrets-init
```

Expected: `✓ stored project-id`, `✓ stored client-id`, `✓ stored
client-secret` (or `kept the stored …` where you press Enter), then:

```text
Test fetch:
  GITHUB_GEJ_MACHINE_PAT: ok (40 chars, ghp_…)
  CLAUDE_CODE_OAUTH_TOKEN: ok (<n> chars, sk-ant-oat01-…)
devenv: ✓ done; the Infisical website tab can be closed
```

The github secret must be the **gej-machine** token (never your personal
one); `devenv host-prepare` turns the setup-token into a custom secret (see
V1). (Skip if already done.)

## 4. Doctor

```sh
~/devenv/bin/devenv doctor
```

Expected: every line `ok`, including `keyring entries present (service
devenv-infisical: project-id client-id client-secret)`,
`GITHUB_GEJ_MACHINE_PAT authenticates as gej-machine (HTTP 200; expires …)`,
`CLAUDE_CODE_OAUTH_TOKEN is a setup-token (sk-ant-oat01-…)` and
`not inside any sandbox workspace; only dev/ is shared with the sandbox`,
except warnings for "ANTHROPIC_TOKEN_EXPIRES is not set" and "on
initial-setup, not main" (while testing the PR branch); on WSL a note that the
Linux sbx is "best-effort" there; the operating rule at the end (it now names
`~/devenv/dev` and `git clean -x`). If GitHub rejects the github secret (HTTP
401), make a new classic `repo` token for gej-machine and paste it into
`GITHUB_GEJ_MACHINE_PAT` on the Infisical website. `devenv host-prepare`
refuses to create the sandbox until the secrets checks pass.

Also check that doctor refuses unsafe setups (AC13). Each must print a `FAIL`
line and exit 1:

```sh
# Pretend this machine has no Infisical login (the real entries stay untouched):
DEVENV_KEYRING_SERVICE=devenv-missing ~/devenv/bin/devenv doctor | grep FAIL; echo "exit=${PIPESTATUS[0]}"

# Pretend a sandbox mounts your whole home (which contains ~/devenv):
DEVENV_EXTRA_WORKSPACES=$HOME ~/devenv/bin/devenv doctor | grep FAIL; echo "exit=${PIPESTATUS[0]}"

# Pretend a sandbox mounts a folder of the checkout other than dev/:
DEVENV_EXTRA_WORKSPACES=$HOME/devenv/lib ~/devenv/bin/devenv doctor | grep FAIL; echo "exit=${PIPESTATUS[0]}"
```

Expected: `FAIL keyring entry missing: project-id client-id client-secret
(service devenv-missing); run: ~/devenv/bin/devenv secrets-init` with exit=1; then
`FAIL the devenv checkout (/home/<you>/devenv) is inside a sandbox workspace
(/home/<you>)` with exit=1; then `FAIL a sandbox workspace
(/home/<you>/devenv/lib) is inside the devenv checkout; only
/home/<you>/devenv/dev may be` with exit=1. (Nothing here writes to or runs
from a workspace.)

## 5. Plan and create

```sh
cd ~/devenv && sbx env plan --kit-arg ref=initial-setup
```

Paste the whole plan. It should show: sandbox `dev`; agent/kit `devenv` from
`./kits/devenv` extending `claude`, with kit arguments `ref=initial-setup`
(and `repo`); workspace `/home/<you>/devenv/dev` (read-write) and **no**
additional workspaces; env `DEVENV_ENTRY=herdr`; no secrets (`devenv
host-prepare` sets the `github` and Claude secrets itself, §9); a `github`
binding for `api.github.com` and `github.com`; skills `off`; the `devenv
host-prepare` lifecycle command.

Then:

```sh
cd ~/devenv && sbx env run --kit-arg ref=initial-setup
```

Save the whole create output. The `devenv host-prepare` part should include
`✓ Infisical secrets and checkout location look right`,
`created the workspace /home/<you>/devenv/dev` (first run only) and end with
`Claude setup-token available to sandbox dev as CLAUDE_CODE_OAUTH_TOKEN
(new placeholder, refresh 55m)` (`reused placeholder` when sbx already holds
one). If the keyring is locked (after a WSL restart), a pop-up
window asks for its password first, and host-prepare prints `✓ keyring
unlocked`. You should land in herdr, in a workspace named **firstmate**,
with Claude starting in `~/devenv/dev/firstmate`, already signed in.

If it fails with `failed to apply kit to sandbox`, sbx doesn't print the
kit's install output, but the daemon log has it (tokens masked):

```sh
grep -h 'create sandbox failed' ~/.local/state/sandboxes/sandboxes/sandboxd/daemon.log | tail -n 1 \
  | sed -E 's/\\n/\n/g; s/(sk-ant-[a-z0-9]+-)[A-Za-z0-9_-]+/\1<redacted>/g; s/(gh[opsu]_)[A-Za-z0-9]+/\1<redacted>/g'
cd ~/devenv && sbx env rm        # clean up the failed create before retrying
```

If sbx rejects `--kit-arg` on a later `sbx env run` without it, or asks to
recreate because the kit argument changed, report it; keep passing the flag
until the PR is merged.

---

## 6. Verification items

### V1: Claude login

**History (2026-09-25).** The spec's design, the setup-token as the sbx
`anthropic` secret, failed: sbx set `SBX_CRED_ANTHROPIC_MODE=apikey` and
Claude got HTTP 401. The token as a **custom secret** (`CLAUDE_CODE_OAUTH_TOKEN`
placeholder, swapped for `api.anthropic.com`) passed in a throwaway sandbox:
`authMethod: oauth_token`, `claude -p` answered, and `quota-axi` read the
subscription's windows. devenv now does that (`CLAUDE_AUTH=token`).

**Masking (2026-09-29).** `authMethod: oauth_token` and a `claude -p` answer
only show that Claude *chose* the variable. If the host holds a global
`anthropic` OAuth secret (`sbx secret ls` says `(oauth configured)`), the
proxy signs **every** request to `api.anthropic.com` with it, even one with no
credential, so the setup-token may never be used and this check passes
anyway. That OAuth also makes sbx's `claude` kit seed a stored login, and
Claude's daemon drops `CLAUDE_CODE_OAUTH_TOKEN` while one exists (background
sessions, including the first mate's, then say "Not logged in"). The checks
below fail under either condition.

Check it in `dev` **(in sandbox)**:
```sh
echo "mode=$SBX_CRED_ANTHROPIC_MODE var=${CLAUDE_CODE_OAUTH_TOKEN:0:7}"   # mode=none var=sbx-cs-
claude auth status | head -n 4                    # "loggedIn": true, "authMethod": "oauth_token"
claude -p "reply with the single word ok" < /dev/null   # ok
# Masking: a request with no credential must NOT be answered. 200 means the
# proxy injects sbx's OAuth login, so V1 FAILS (see the host fix below).
curl -s -o /dev/null -w '%{http_code}\n' -H 'anthropic-beta: oauth-2025-04-20' https://api.anthropic.com/api/oauth/profile   # 401 (not 200)
# No stored login, and a running daemon keeps the variable:
jq -e '.claudeAiOauth.refreshToken' ~/.claude/.credentials.json >/dev/null 2>&1 && echo "STORED LOGIN" || echo none   # none
for p in $(pgrep -f 'daemon run'); do tr '\0' '\n' < /proc/$p/environ | grep -c '^CLAUDE_CODE_OAUTH_TOKEN=' ; done   # 1 per daemon
devenv doctor | sed -n '/^accounts/,/^herdr/p'    # all ok, including the two token-mode lines
```

If the profile request returns 200, V1 **fails**: the setup-token is not what
signs requests. On the host, remove the global OAuth secret, then recreate
`dev` (`sbx env rm`, `sbx env run`) and check again. This also signs
`claude-dev` and any other sandbox out of that subscription login, so it is
the owner's call:
```sh
sbx secret ls                                       # find: anthropic (oauth configured)
sbx secret rm anthropic -f                          # global; without --sandbox it acts on global secrets
```

Also after `sbx stop dev` + `sbx env run` (V10) and after a recreate (V6):
still signed in, no `/login`. Fallback: `CLAUDE_AUTH=login` in `devenv.conf`
and `/login` once per rebuild.

### V2: local sandbox kit as the agent; herdr across detach

1. You landed in herdr (step 5) rather than plain Claude.
2. Detach with `ctrl+b q`. Then from the host:
   ```sh
   cd ~/devenv && sbx env exec -- bash -lc 'herdr status server --json; herdr workspace list'
   ```
   Report whether the server is still `running` and the `firstmate` workspace
   still exists after the detach.
3. Re-attach: `cd ~/devenv && sbx env run --kit-arg ref=initial-setup`.
   Expected: back in the same workspace, still exactly **one** `firstmate`
   workspace (AC3).

**(in sandbox)** — check whether inherited claude flags reach the entrypoint:
```sh
cat /proc/1/cmdline 2>/dev/null | tr '\0' ' '; echo; ps -eo pid,args | grep -E 'devenv-entry|devenv entry' | grep -v grep
```

Fallback if the kit can't be used as the agent: the mixin form described at
the top of `kits/devenv/spec.yaml`.

### V4: skills

sbx's shared skills store is off for `dev` (it is only mounted for sbx's
built-in agents); `devenv start` links devenv's skills from the clone instead.

**(in sandbox)**
```sh
ls -la ~/.claude/skills
mount | grep -c '/.claude/skills'
```

Expected: `grill-me` and `grilling` are symlinks to
`/home/agent/fm-projects/devenv/skills/…`, and the mount count is `0`. Then
type `/gril` in the first-mate pane: both are listed (AC7 has the worktree
half).

### V5: mounts

**(in sandbox)**
```sh
echo "WORKSPACE_DIR=$WORKSPACE_DIR DEVENV_DIR=$DEVENV_DIR"
mount | grep -E ' /home/[^ ]*/devenv' ; ls -la "$(dirname "$WORKSPACE_DIR")"
```

Expected: `WORKSPACE_DIR=/home/<you>/devenv/dev`,
`DEVENV_DIR=/home/agent/fm-projects/devenv`; one read-write mount for
`/home/<you>/devenv/dev`, and nothing else of the checkout. Report what
`ls` shows next to `dev` (sbx mounts `sbxenv.yaml` read-only and writes its
`CLAUDE.md` there).

### V6 and AC10: persistence across `sbx rm`

**(in sandbox)** ask the first mate: *"Save to your memory: the devenv V6
check word is lighthouse."* Then:
```sh
ls "$WORKSPACE_DIR"/.devenv-state/claude-memory/*/          # (in sandbox) the memory file is here
ls "$FM_HOME"/config "$FM_HOME"/state "$FM_HOME"/data 2>&1 | head
```

Remove and rebuild from the host:
```sh
cd ~/devenv && sbx env rm        # approve; this deletes the sandbox, not ~/devenv/dev
cd ~/devenv && sbx env run --kit-arg ref=initial-setup
```

**(in sandbox)** after the rebuild:
```sh
ls -la ~/.claude/projects/*/memory                 # symlinks into $WORKSPACE_DIR/.devenv-state/claude-memory
grep -rl lighthouse "$WORKSPACE_DIR"/.devenv-state/claude-memory
ls "$FM_HOME"/config; ls ~/fm-projects ~/.treehouse 2>&1 | head -3
```

Expected: the memory is still there and linked; Firstmate's `config/`,
`data/`, `state/` survived; `~/fm-projects` holds only the freshly cloned
`devenv`, and `~/.treehouse` is gone or empty. Ask the first mate *"What is
the devenv V6 check word?"*: it should answer lighthouse. Fallback: a
`lifecycle.preRemove` hook.

### V7: the devenv clone at create

(Replaces the first layout's "read-only mount during install".) From the
create output or the daemon log:
```text
devenv: cloning https://github.com/digigrant/devenv (initial-setup) into /home/agent/fm-projects/devenv
devenv: provisioning from /home/agent/fm-projects/devenv at <commit> <subject>
```

**(in sandbox)**
```sh
git -C "$DEVENV_DIR" status -sb | head -n 1; git -C "$DEVENV_DIR" log --oneline -1
devenv check | grep 'devenv runs from'
gh --version | head -n 1; apt-cache policy gh | head -n 6
```

Expected: `## initial-setup...origin/initial-setup`, the branch's head commit,
and `devenv runs from /home/agent/fm-projects/devenv, on initial-setup at …`.
`gh` is GitHub's current release (no `Ubuntu` in its version line): apt's
`Installed` and `Candidate` match, and the `***` version comes from
`https://cli.github.com/packages`.

### V10: settings survive a restart

```sh
sbx stop dev && cd ~/devenv && sbx env run --kit-arg ref=initial-setup
```

**(in sandbox)**
```sh
jq '{statusLine, modelSettings, themeId, alwaysThinkingEnabled, permissions, apiKeyHelper, hooks: [.hooks.SessionStart[].hooks[].command]}' ~/.claude/settings.json
stat -c '%y %n' ~/.claude/settings.json ~/.cache/devenv/warnings
tail -n 15 /var/log/sbx-kit-startup.log; tail -n 5 ~/.cache/devenv/start.log
```

Expected: `statusLine` is `bash "$HOME/.claude/statusline.sh"`,
`modelSettings["claude-opus-5-5"].effortLevel` is `high`, sbx's keys are
present, and four SessionStart hooks (herdr, gh-axi, chrome-devtools-axi,
devenv memory link). This is also AC6 for a restart; repeat after the
recreate in V6.

### V11: network

```sh
for h in github.com api.github.com codeload.github.com objects.githubusercontent.com \
         release-assets.githubusercontent.com raw.githubusercontent.com cli.github.com registry.npmjs.org nodejs.org herdr.dev; do
  printf '%-40s ' "$h"; sbx policy check network --sandbox dev "$h" 2>&1 | tail -n 1
done
sbx policy log | tail -n 40
```

Expected: all allowed except `herdr.dev`, which must stay blocked. Report any
other blocked host; only those get added to the kit's `permissions.network.allow`.

### V12: Firstmate bootstrap

In the first-mate pane, say *"hi"* and paste its startup report. **(in sandbox)** also:
```sh
devenv doctor
```

Expected: no `MISSING:` lines and no `NEEDS_GH_AUTH`. A
`PRESENTATION_UNAVAILABLE: lavish-axi` note is expected (Lavish is out of
scope and Firstmate says non-visual work proceeds without it). While the
sandbox is built from `initial-setup`, Firstmate may report its devenv
project clone as off the default branch; that is expected until the merge.

### Automatic Firstmate updates

**(in sandbox)** after a create or `sbx stop dev` + `sbx env run`:
```sh
git -C "$FM_HOME" remote get-url origin           # https://github.com/digigrant/firstmate
devenv check | grep -i firstmate                  # "last firstmate sync: …" and "last firstmate update: …" notes, no ⚠
git -C "$FM_HOME" log --oneline -1                # the fork's main (also on GitHub)
```

Expected sync notes: `… is up to date with kunchenguid/firstmate` or
`fast-forwarded digigrant/firstmate by N commits`. A `failed:` warning that
names the `workflow` scope means upstream changed workflow files (see README,
Firstmate updates).

### Projects

Tell the first mate: *"devenv is https://github.com/digigrant/devenv; its
clone is ~/fm-projects/devenv; ship it direct-PR."* It should register the
existing clone rather than clone it again. AC11 then exercises a PR.

---

## 7. Acceptance checks

| AC | How | Expected |
|---|---|---|
| AC1 | steps 5 and V6 | `sbx env run` builds `dev` with no manual steps (Claude signs in with the setup-token) |
| AC2 | the first-mate pane | Claude banner "Opus 5.5 with xhigh effort", status line `effort:xhigh`, cwd `~/devenv/dev/firstmate`; V12 clean |
| AC3 | V2 step 3 | one `firstmate` workspace after re-running `sbx env run` |
| AC4 | edit `env.DEVENV_ENTRY` in `~/devenv/sbxenv.yaml` to `claude`, `sbx env run`; then `shell`; then back to `herdr` | plain Claude in `~/devenv/dev`; then a bash prompt; no recreate. (Don't commit the edit.) |
| AC5 | **(in sandbox)** `bash "$DEVENV_DIR/tests/statusline-identity.sh"` | `statusline identity: PASS (5 fixtures)` |
| AC6 | V10, and again after the V6 recreate | as in V10 |
| AC7 | **(in sandbox)** type `/gril` in the first-mate pane; then `mkdir -p ~/.treehouse/skilltest && cd ~/.treehouse/skilltest && claude` and type `/gril` | `/grill-me` and `/grilling` listed in both |
| AC8 | **(in sandbox)** `WARN_DAYS=90 devenv check`; `git -C "$FM_HOME" commit --allow-empty -m test && devenv check`; `DEVENV_ENTRY=shell devenv entry` | token expiry warning (the current bot token expires 2026-12-24), "firstmate has 1 commits that your fork's main doesn't", warnings printed in yellow, `⚠ devenv:N` in Claude's status line. Undo with `git -C "$FM_HOME" reset --hard HEAD~1 && devenv check` |
| AC9 | already verified in the sandbox by the agent (PR description) | — |
| AC10 | V6 | as in V6 |
| AC11 | **(in sandbox)** `git config --global user.name; git config --global user.email; gh api user --jq .login` | `gej-machine`, `318032932+gej-machine@users.noreply.github.com`, `gej-machine`. Optionally ask the first mate for a throwaway draft PR on devenv (after "Projects" above) to confirm a worker's push and `gh pr create`, then close it |

---


## 8. Secrets manager (Infisical)

The design is [SECRETS.md](SECRETS.md); this branch builds it. The order
follows SECRETS.md §8: the website setup and the probes (done), then trying
the build, the cleanup, and a restart. Never paste a secret value, a client
ID, a client secret or a project ID into a PR: every command here prints only
lengths, shapes, file names or exit codes.

While the build's PR is open, check out its branch on the host and build the
sandbox from it: `git -C ~/devenv fetch && git -C ~/devenv checkout
fm/devenv-devenv-infisical-secrets-manager-df`, and
`--kit-arg ref=fm/devenv-devenv-infisical-secrets-manager-df` below.

### 8.1 Infisical setup (website, once)

1. **Create the machine identity.** In the organization, **Access Control**,
   then **Machine Identities**, then **Create**: `sbx-host`, with the most
   limited organization role (its access comes from the project role in
   step 2). Add **Universal Auth**: in its Configuration tab set Access Token
   TTL and Access Token Max TTL to `300`; leave the Lockout tab on (3 failed
   logins lock it for 5 minutes).
2. **Grant it one project.** Open the agent project (the one holding
   `CLAUDE_CODE_OAUTH_TOKEN` and `GITHUB_GEJ_MACHINE_PAT`), **Access
   Control**, then **Machine Identities**, then **Add Machine Identity to
   Project**, **Assign Existing**, `sbx-host`, role **Viewer**. Add it to no
   other project.
3. **Create this machine's client secret:** on `sbx-host`'s page, in the
   **Universal Auth** section, **Add Client Secret**, named after the machine
   (e.g. `wsl-desktop`), TTL `0` (no expiry). Infisical shows it only once, so
   keep the tab open until `devenv secrets-init` has stored it.
4. **Delete `TEST`.**
5. **Replace both tokens in Infisical,** not on disk (SECRETS.md §8 step 2):
   paste a new `claude setup-token` token into `CLAUDE_CODE_OAUTH_TOKEN` (then
   run `clear` in that terminal) and a new `gej-machine` classic PAT (`repo`,
   90 days) into `GITHUB_GEJ_MACHINE_PAT`. Keep the old files and the old PAT
   until 8.4.

**The three values `devenv secrets-init` asks for:**

| Value | Where on the website |
|---|---|
| Project ID | the agent project, **Project Settings**, **Copy Project ID** |
| Client ID | `sbx-host`'s page (organization, **Access Control**, **Machine Identities**), **Universal Auth** section, **Client ID**. Not the Identity ID, which is under **Options**, **Copy Machine Identity ID** |
| Client secret | the same Universal Auth section, **Add Client Secret** (step 3); shown only once |

A wrong value fails the login, and **3 failed logins lock `sbx-host` for 5
minutes** (the count starts again after 30 seconds without a failure).
During a lockout even the right values fail, so after a failure fix the value,
wait 5 minutes, then retry; or end the lockout at once with **Reset All
Lockouts** in `sbx-host`'s Universal Auth section.

### 8.2 Probes (before the build)

Results, from the owner on 2026-09-27 (SECRETS.md §5):
- **P1 passed.** The first `secret-tool store` asked for the new keyring's
  password in a pop-up window, not the terminal. After `wsl --shutdown` the
  keyring is locked, and the next lookup opened a pop-up asking to unlock it.
- **P3 passed** as is, without setting `DBUS_SESSION_BUS_ADDRESS`.
- **P2 has no result.** `secret-get` uses `curl` instead of the Infisical CLI,
  which meets SECRETS.md S6 whatever P2 shows. A later run is informational:
  after 8.3 step 2 has stored the keyring entries,

  ```sh
  m=$(mktemp)
  (
    INFISICAL_UNIVERSAL_AUTH_CLIENT_ID=$(secret-tool lookup service devenv-infisical key client-id)
    INFISICAL_UNIVERSAL_AUTH_CLIENT_SECRET=$(secret-tool lookup service devenv-infisical key client-secret)
    export INFISICAL_UNIVERSAL_AUTH_CLIENT_ID INFISICAL_UNIVERSAL_AUTH_CLIENT_SECRET
    INFISICAL_TOKEN=$(infisical login --method=universal-auth --silent --plain) || { echo "sbx-host login failed"; exit 1; }
    export INFISICAL_TOKEN
    infisical secrets get GITHUB_GEJ_MACHINE_PAT --silent --plain --env dev --path / \
      --projectId "$(secret-tool lookup service devenv-infisical key project-id)" | wc -c
  )
  find ~ /tmp -xdev -newer "$m" -type f 2>/dev/null \
    | grep -vE "^$HOME/(devenv/dev|\.local/state/sandboxes)/|^/tmp/(tmp\.|claude-)" | head -n 30
  rm -f "$m"
  ```

  Report the count (41) and whether the `find` list shows anything under
  `~/.infisical/` or `~/infisical-keyring/`.

### 8.3 Try the build

1. **Prerequisites:**
   ```sh
   sudo apt-get install -y jq curl libsecret-tools
   command -v secret-tool busctl jq curl
   ```
   Expected: four paths (`busctl` comes with systemd).

2. **Store the keyring entries** (8.1 lists where each value is):
   ```sh
   ~/devenv/bin/devenv secrets-init
   ```
   Expected, with values you paste (Enter keeps an entry that already exists,
   e.g. from P2):
   ```text
   devenv: storing this machine's Infisical login in the keyring (service devenv-infisical)
   devenv: paste each value from the Infisical website; nothing is shown as you paste
   Project ID (the agent project: Project Settings):
   devenv: ✓ stored project-id
   Client ID (sbx-host identity, Universal Auth; not the Identity ID):
   devenv: ✓ stored client-id
   Client secret (sbx-host identity, Universal Auth, Add Client Secret):
   devenv: ✓ stored client-secret
   Test fetch:
     GITHUB_GEJ_MACHINE_PAT: ok (40 chars, ghp_…)
     CLAUDE_CODE_OAUTH_TOKEN: ok (<n> chars, sk-ant-oat01-…)
   devenv: ✓ done; the Infisical website tab can be closed
   ```
   A failure prints `FAILED:` with the reason (e.g. `Infisical rejected the
   sbx-host login (HTTP 401): …`) and stops after that one login. Mind the
   lockout (8.1) before retrying.

3. **Doctor** (A5):
   ```sh
   ~/devenv/bin/devenv doctor | sed -n '/^secrets/,/^devenv checkout/p'
   DEVENV_KEYRING_SERVICE=devenv-missing ~/devenv/bin/devenv doctor | grep FAIL; echo "exit=${PIPESTATUS[0]}"
   ```
   Expected, first command:
   ```text
   secrets (Infisical, keyring service devenv-infisical)
     ok    refresh: CLAUDE_CODE_OAUTH_TOKEN 55m, GITHUB_GEJ_MACHINE_PAT 55m (devenv.conf)
     ok    keyring entries present (service devenv-infisical: project-id client-id client-secret)
     ok    GITHUB_GEJ_MACHINE_PAT authenticates as gej-machine (HTTP 200; expires …)
     ok    CLAUDE_CODE_OAUTH_TOKEN is a setup-token (sk-ant-oat01-…)
     warn  plain-text secret files left over in /home/<you>/.config/devenv/secrets; delete them (docs/SECRETS.md S13)
     warn  Infisical CLI backups left over in /home/<you>/.infisical/secrets-backup; delete them and run infisical logout (docs/SECRETS.md S13)
     warn  ANTHROPIC_TOKEN_EXPIRES is not set in devenv.conf (setup-token expiry unknown)
   ```
   (The leftover warnings, where they show, go away in 8.4.) Second command:
   `FAIL  keyring entry missing: project-id client-id client-secret (service
   devenv-missing); run: ~/devenv/bin/devenv secrets-init` and `exit=1`.

4. **`secret-get`'s contract**, showing only lengths and exit codes:
   ```sh
   ~/devenv/bin/devenv secret-get GITHUB_GEJ_MACHINE_PAT | wc -c
   ~/devenv/bin/devenv secret-get TEST; echo "exit=$?"
   ```
   Expected: `41` (the token and a newline); then `devenv: error:
   secret-get fetches only GITHUB_GEJ_MACHINE_PAT and CLAUDE_CODE_OAUTH_TOKEN
   (devenv.conf), not 'TEST'` and `exit=1`.

5. **Rebuild with the branch** (the `github` command only changes at create):
   ```sh
   cd ~/devenv && sbx env rm
   cd ~/devenv && sbx env run --kit-arg ref=fm/devenv-devenv-infisical-secrets-manager-df
   ```
   Expected in the `devenv host-prepare` part: the leftover warnings,
   `✓ Infisical secrets and checkout location look right`, and
   `✓ Claude setup-token available to sandbox dev as CLAUDE_CODE_OAUTH_TOKEN
   (… placeholder, refresh 55m)`. You land in herdr as before.

6. **What sbx stored** (SPEC §10 invariant 12; since §9, `host-prepare`
   registers the `github` command, so the source is an absolute path without
   quotes and `${{ env.fileDir }}` no longer applies):
   ```sh
   jq -c '.. | objects | select(.type? == "command") | {source, refresh}' \
     ~/.local/state/sandboxes/sandboxes/sandboxd/runtimes/dev.json
   ```
   Expected: `{"source":"\"/home/<you>/devenv/bin/devenv\" secret-get
   GITHUB_GEJ_MACHINE_PAT","refresh":"55m"}` (and, if sbx records it there,
   the Claude custom secret with `…/devenv/bin/devenv secret-get
   CLAUDE_CODE_OAUTH_TOKEN`). Only paths and names, never a value. If the
   source still contains the literal `${{ env.fileDir }}`, report it: the
   fallback is `"$HOME/devenv/bin/devenv"` in `sbxenv.yaml` (SECRETS.md §6.5).

7. **A1: the sandbox holds only placeholders** **(in sandbox)**:
   ```sh
   for v in GH_TOKEN GITHUB_TOKEN CLAUDE_CODE_OAUTH_TOKEN; do printf '%s=%s…\n' "$v" "$(printenv "$v" | cut -c1-8)"; done
   gh api user --jq .login                           # gej-machine
   claude auth status | head -n 4                    # "authMethod": "oauth_token"
   claude -p "reply with the single word ok" < /dev/null   # ok
   curl -s -o /dev/null -w '%{http_code}\n' -H 'anthropic-beta: oauth-2025-04-20' https://api.anthropic.com/api/oauth/profile   # 401
   ```
   Expected: sbx placeholders (`gho_sbxp…` or similar for GitHub,
   `sbx-cs-d…` for Claude), never a real `ghp_` or `sk-ant-oat01-` value;
   `gej-machine`; `oauth_token`; `ok`; and **401** from the last command. A
   200 means the proxy injects sbx's OAuth login and masks the setup-token:
   A1 fails (see V1). `devenv doctor` must also show no stored login and a
   daemon with the variable.

8. **A locked keyring, without a restart** (the pop-up and the never-prompt
   rule). Lock the default keyring, then fetch:
   ```sh
   kr=$(busctl --user --json=short call org.freedesktop.secrets /org/freedesktop/secrets \
          org.freedesktop.Secret.Service ReadAlias s default | jq -r '.data[0]')
   busctl --user call org.freedesktop.secrets /org/freedesktop/secrets org.freedesktop.Secret.Service Lock ao 1 "$kr"
   time ~/devenv/bin/devenv secret-get GITHUB_GEJ_MACHINE_PAT; echo "exit=$?"
   ```
   Expected: `devenv: error: keyring locked; run sbx env run (host-prepare
   unlocks it)` and `exit=1` within a second, and **no pop-up window**. Then:
   ```sh
   cd ~/devenv && sbx env run --kit-arg ref=fm/devenv-devenv-infisical-secrets-manager-df
   ```
   Expected: `devenv: the keyring is locked (as after every restart): a window
   asks for the keyring password now`, a pop-up asking for the keyring
   password; after you type it, `✓ keyring unlocked`, the other host-prepare
   lines, and herdr. Report where the window appeared.

### 8.4 Clean up (SECRETS.md §8 step 6)

Once 8.3 passes:

```sh
rm -rf ~/.config/devenv/secrets
rm -rf ~/.infisical/secrets-backup && infisical logout   # skip `infisical logout` if the CLI isn't installed
~/devenv/bin/devenv doctor | grep -iE 'left over|FAIL'; echo "(end)"
```

Also revoke the old `gej-machine` PAT in gej-machine's GitHub settings
(Developer settings, Personal access tokens). Expected: only `(end)`.

**A3: a rebuild needs only the keyring:**
```sh
cd ~/devenv && sbx env rm && sbx env run --kit-arg ref=fm/devenv-devenv-infisical-secrets-manager-df
```
Expected: a working `dev` as in 8.3 step 5, then A1 (8.3 step 7) again.

**A2: no plain-text copy.** Each value goes to `grep` on stdin, and only file
names print (this reads a lot of files and can take a few minutes):

```sh
for n in GITHUB_GEJ_MACHINE_PAT CLAUDE_CODE_OAUTH_TOKEN; do
  printf '%s: ' "$n"
  ~/devenv/bin/devenv secret-get "$n" | grep -rlF -f - ~/.config ~/.local ~/.cache ~/.infisical ~/devenv /tmp 2>/dev/null | head -n 3 | tr '\n' ' '
  echo "(end)"
done
```

Expected: `(end)` right after each name.

**A6: the identity details aren't in the repo:**

```sh
for k in project-id client-id; do secret-tool lookup service devenv-infisical key "$k" | git -C ~/devenv grep -qF -f -; echo "$k in repo: exit=$? (1 = not found)"; done
```

Expected: `exit=1` for both.

### 8.5 After a WSL restart, and past the refresh (A4)

1. `wsl --shutdown` in PowerShell, then open a new WSL terminal.
2. Doctor never prompts:
   ```sh
   ~/devenv/bin/devenv doctor | grep -i keyring
   ```
   Expected: `FAIL  keyring locked; run sbx env run (host-prepare unlocks it)`
   and no window.
3. `cd ~/devenv && sbx env run --kit-arg ref=fm/devenv-devenv-infisical-secrets-manager-df`:
   one pop-up asks for the keyring password; then `✓ keyring unlocked`, and
   you land in herdr.
4. More than an hour later (past sbx's 55-minute refresh), **(in sandbox)**
   `gh api user --jq .login` answers `gej-machine` and
   `claude -p "reply with the single word ok" < /dev/null` answers `ok`.

### 8.6 Acceptance (SECRETS.md §9)

| Item | Where | Expected |
|---|---|---|
| A1 | 8.3 step 7 | placeholders only; `gej-machine`; `oauth_token`; unauthenticated profile request is 401, not 200 |
| A2 | 8.4 | `(end)` after each name |
| A3 | 8.4 | the rebuild works with no secret files |
| A4 | 8.5 | one keyring prompt after a restart; fetches still work after an hour |
| A5 | 8.3 step 3, 8.4 | all `ok` with no leftover warnings; FAIL and exit 1 with `DEVENV_KEYRING_SERVICE=devenv-missing` |
| A6 | 8.4 | `exit=1` for both |
| A7 | the PR (code review) | no secret or identity detail as an argument in `secret-get`, `secrets-init`, `host-prepare` or `doctor` |

## 9. Secrets set by host-prepare: Claude placeholder, GitHub, refresh

`devenv host-prepare` now gives the sandbox both secrets itself, each with the
refresh set in `devenv.conf` (`SECRET_REFRESH`, default `55m`; per-secret
`SECRET_REFRESH_CLAUDE` / `SECRET_REFRESH_GITHUB`):

- the `github` service secret (`sbx secret set github --sandbox dev
  --command … --refresh …`); `sbxenv.yaml` has no `secrets:` block any more
  and only keeps `bindings.github`;
- the Claude custom secret, whose placeholder sbx alone keeps: host-prepare
  reuses the one sbx holds for `dev`. `CLAUDE_AUTH=login` removes the
  sandbox-scoped secret.

This changes `devenv host-prepare` and `sbxenv.yaml`, which run on the host,
so the host checkout must be on the branch:

```sh
git -C ~/devenv fetch origin
git -C ~/devenv switch fm/devenv-design-host-prepare-anthropic-secret-col-14
```

Switch back to `main` once the PR is merged. Placeholders aren't secret; the
commands below still print only their first 14 characters.

1. **Doctor** reads the new settings:
   ```sh
   ~/devenv/bin/devenv doctor | grep refresh
   ```
   Expected: `ok    refresh: CLAUDE_CODE_OAUTH_TOKEN 55m, GITHUB_GEJ_MACHINE_PAT 55m (devenv.conf)`.

2. **A run that only attaches keeps both working.** With `dev` running
   (created before this change, from an `sbxenv.yaml` that still declared
   `secrets.github`):
   ```sh
   cd ~/devenv && sbx env run
   ```
   Paste the plan: the `github` secret is no longer declared (sbx may mark it
   `!` to forget). Expected in the `devenv host-prepare` part:
   `✓ gej-machine token (GITHUB_GEJ_MACHINE_PAT) available to sandbox dev as
   the github secret (refresh 55m)`, `removed
   ~/.config/devenv/claude-oauth-placeholder (sbx keeps the placeholder now)`
   (first run only) and `✓ Claude setup-token available to sandbox dev as
   CLAUDE_CODE_OAUTH_TOKEN (reused placeholder, refresh 55m)`. Then **(in
   sandbox)**:
   ```sh
   gh api user --jq .login                                  # gej-machine
   claude -p "reply with the single word ok" < /dev/null    # ok
   ```

3. **What sbx stored.** The Claude custom secret:
   ```sh
   sbx secret ls --sandbox dev --json | jq -c '.custom_secrets[] | {env, placeholder: (.placeholder[0:14] + "…"), refresh, source}'
   ```
   Expected: exactly one line, `{"env":"CLAUDE_CODE_OAUTH_TOKEN",
   "placeholder":"sbx-cs-devenv-…","refresh":"55m","source":"/home/<you>/devenv/bin/devenv
   secret-get CLAUDE_CODE_OAUTH_TOKEN"}` (before this change it said
   `on-demand`). `sbx secret ls` doesn't show a service secret's command or
   refresh; the sandbox's runtime file does:
   ```sh
   jq -c '.. | objects | select(.type? == "command") | {source, refresh}' \
     ~/.local/state/sandboxes/sandboxes/sandboxd/runtimes/dev.json
   ```
   Expected: the `github` command,
   `/home/<you>/devenv/bin/devenv secret-get GITHUB_GEJ_MACHINE_PAT`, with
   `"refresh":"55m"` (report it if sbx doesn't record the secret there, or
   still shows the old `"${{ env.fileDir }}…"` source after step 2).

4. **A second attach-only run** changes nothing: `cd ~/devenv && sbx env run`
   again prints `(reused placeholder, refresh 55m)`, step 3 prints the same
   placeholder, and `gh api user` and `claude -p` still answer.

5. **Per-secret overrides**, without editing `devenv.conf` (sbx passes its
   environment to host-prepare):
   ```sh
   cd ~/devenv && SECRET_REFRESH_CLAUDE=10m SECRET_REFRESH_GITHUB=30m sbx env run
   ```
   Expected: `(refresh 30m)` for the github secret and `(reused placeholder,
   refresh 10m)` for Claude; step 3 shows `10m` and, if the runtime file
   records it, `30m`. Then plain `cd ~/devenv && sbx env run` puts both back
   to `55m`.

6. **An invalid value is refused before anything runs:**
   ```sh
   SECRET_REFRESH_GITHUB=5d ~/devenv/bin/devenv host-prepare; echo "exit=$?"
   ```
   Expected: `devenv: error: SECRET_REFRESH_GITHUB in devenv.conf must be
   on-demand or a duration such as 55m or 10m, not '5d'` and `exit=1`.

7. **GitHub through the binding alone, in a new sandbox** (Docker's docs say
   a binding only approves a stored credential, so `sbxenv.yaml` needs no
   `secrets:`; this checks it on a live sandbox):
   ```sh
   cd ~/devenv && sbx env rm
   cd ~/devenv && sbx env run
   ```
   Expected: the plan lists no secrets and the `github` binding; host-prepare
   prints the github line and `(new placeholder, refresh 55m)`. Then **(in
   sandbox)** `gh api user --jq .login` answers `gej-machine`,
   `git ls-remote https://github.com/digigrant/devenv HEAD` prints a commit,
   `claude -p "reply with the single word ok" < /dev/null` answers `ok`, and
   `devenv doctor` passes its accounts checks. If GitHub fails here (401, or
   `gh` not logged in), report it with `sbx secret ls --sandbox dev` and the
   daemon log's last lines about github.

8. **Optional, only right before a planned recreate** (it signs the running
   sandbox out of Claude): `CLAUDE_AUTH=login ~/devenv/bin/devenv
   host-prepare` prints `removed the Claude setup-token custom secret from
   sandbox dev (CLAUDE_AUTH=login)`, and the first command of step 3 then
   prints nothing. Plain `~/devenv/bin/devenv host-prepare` makes a new
   placeholder (`new placeholder`); recreate `dev` (`sbx env rm`,
   `sbx env run`) so the sandbox gets it.

## 10. Tailscale on the host

devenv now installs Tailscale on each host and signs it in (README:
Tailscale; spec D33, §6.14), and host `doctor` checks it. This adds a host
command (`devenv tailscale-setup`) and changes `devenv doctor`, which run on
the host, so the host checkout must be on the branch:

```sh
git -C ~/devenv fetch origin
git -C ~/devenv switch fm/devenv-tailscale-host
```

Switch back to `main` once the PR is merged. The agent could only test this
against fakes: `pkgs.tailscale.com` is blocked in the sandbox, and it can't run
anything on the host. Nothing here touches a sandbox; `host-prepare` doesn't
look at Tailscale.

### 10.1 The Windows PC (WSL 2)

1. **Tailscale off Windows.** Uninstall it on Windows (Settings > Apps >
   Installed apps > Tailscale > Uninstall), unless you rely on it there; then
   keep it stopped instead (administrator PowerShell:
   `Set-Service Tailscale -StartupType Disabled; Stop-Service Tailscale`).
   From WSL:
   ```sh
   sc.exe query Tailscale | tr -d '\r' | grep -E 'FAILED|STATE'
   ```
   Expected: `[SC] EnumQueryServicesStatus:OpenService FAILED 1060:`
   (uninstalled) or `STATE : 1  STOPPED`. Paste it either way, since devenv
   reads this output.

2. **systemd in the distro.**
   ```sh
   ls -d /run/systemd/system; cat /etc/wsl.conf
   ```
   Expected: `/run/systemd/system`, and `systemd=true` under `[boot]`. If it
   is missing, step 3 prints the fix.

3. **Doctor before setup:**
   ```sh
   ~/devenv/bin/devenv doctor | sed -n '/^Tailscale$/,/^secrets/p'
   ```
   Expected:
   ```text
   Tailscale
     ok    systemd is running in this WSL distro
     ok    Tailscale is not installed on Windows
     FAIL  Tailscale is not installed; run: ~/devenv/bin/devenv tailscale-setup
   ```
   (`warn  Tailscale is installed on Windows but stopped…` if you kept it
   installed.)

4. **Set up** (sudo asks for your password; have a browser ready):
   ```sh
   ~/devenv/bin/devenv tailscale-setup
   ```
   Expected, in order:
   ```text
   devenv: ✓ Tailscale is not installed on Windows
   devenv: adding Tailscale's apt repository (https://pkgs.tailscale.com/stable/ubuntu <codename>) and installing tailscale; sudo may ask for your password
   devenv: ✓ Tailscale apt source /etc/apt/sources.list.d/tailscale.list (changed), key /usr/share/keyrings/tailscale-archive-keyring.gpg (changed)
   devenv: ✓ tailscale <version> installed from Tailscale's apt repository
   devenv: ✓ tailscaled is running and starts at boot
   devenv: this machine isn't signed in to Tailscale yet: a one-time sign-in in a browser
   devenv: running: sudo tailscale up
   devenv: open the link it prints, sign in, and it carries on

   To authenticate, visit:

           https://login.tailscale.com/a/…
   ```
   Open the link in your Windows browser and sign in to your tailnet. It then
   prints `Success.` and:
   ```text
   devenv: ✓ signed in: <machine>.<tailnet>.ts.net (100.x.y.z) on tailnet <tailnet>; key expires <date>
   ```
   followed by `✓` or a warning each for MagicDNS and HTTPS certificates. (If
   the package didn't start tailscaled itself, the daemon line reads
   `tailscaled started, and starts at boot`.)

5. **Run it again:**
   ```sh
   ~/devenv/bin/devenv tailscale-setup
   ```
   Expected: no sudo prompt and no sign-in; `✓ tailscale <version>, from
   Tailscale's apt repository (already installed)`, `✓ tailscaled is running
   and starts at boot`, then the same `signed in` line.

6. **What it installed:**
   ```sh
   cat /etc/apt/sources.list.d/tailscale.list
   apt-cache policy tailscale | head -n 3
   systemctl is-enabled tailscaled; systemctl is-active tailscaled
   ```
   Expected: `# Tailscale packages for ubuntu <codename>` and
   `deb [signed-by=/usr/share/keyrings/tailscale-archive-keyring.gpg] https://pkgs.tailscale.com/stable/ubuntu <codename> main`;
   `Installed:` equal to `Candidate:`; `enabled`, `active`.

7. **Admin console, once per tailnet.** On the
   [Machines](https://console.tailscale.com/admin/machines) page, check the
   new WSL machine; if the Windows PC was listed before, remove its old entry
   (and rename the WSL one if you like). On the
   [DNS](https://console.tailscale.com/admin/dns) page, turn on MagicDNS if it
   is off, and under HTTPS Certificates select Enable HTTPS. Then:
   ```sh
   ~/devenv/bin/devenv doctor | sed -n '/^Tailscale$/,/^secrets/p'
   ```
   Expected: every line `ok`: systemd, not on Windows, `tailscale <version>,
   from Tailscale's apt repository`, `tailscaled is running and starts at
   boot`, `signed in: …`, `MagicDNS is on for the tailnet`, `HTTPS
   certificates are on for the tailnet`.

8. **Traffic from WSL works** (the reason Tailscale is off Windows). With the
   Tailscale app signed in on your phone:
   ```sh
   tailscale status
   tailscale ping <phone's machine name>
   ```
   Expected: the phone listed, and `pong from <phone> (100.x.y.z) via …`.

9. **Doctor fails with the fix** when the daemon is down (this only stops
   Tailscale for a moment):
   ```sh
   sudo systemctl stop tailscaled
   ~/devenv/bin/devenv doctor | grep 'tailscaled is not running'; echo "exit=${PIPESTATUS[0]}"
   sudo systemctl start tailscaled
   ```
   Expected: `FAIL  tailscaled is not running; run: sudo systemctl enable
   --now tailscaled` and `exit=1`.

10. **The sandbox is unaffected:** `cd ~/devenv && sbx env run` behaves as
    before (host-prepare prints nothing about Tailscale).

### 10.2 The Linux laptop (native)

The same as 10.1 without steps 1 and 2 (native Linux has no Windows side,
and Ubuntu runs systemd): step 3 shows only the `FAIL  Tailscale is not
installed` line, step 4 starts at `adding Tailscale's apt repository`, and
the rest is identical. If this laptop already runs Tailscale from
Tailscale's own installer, step 3 starts past the install, and step 4 either
prints `(already installed)` straight away or, where Tailscale's source file
differs from devenv's copy of it, rewrites the source once and runs apt; its
sign-in step is skipped when the laptop is already signed in. Paste what it
prints, and `cat /etc/apt/sources.list.d/tailscale.list` from before step 4.

## 11. Android emulator (opt-in, D34)

`devenv emulator` runs an Android emulator on the host, in a Docker Engine
container with `/dev/kvm`, and sandboxes drive it with `adb` through one
network policy rule (README: "Android emulator"). The agent built and tested
everything it could in a sandbox (no KVM there): the image builds, the SDK
volume unpacks, and the emulator gets as far as its hardware checks. Nothing
below has run on a host yet. `devenv emulator` is host code, so the host
checkout must be on the branch while the PR is open:

```sh
git -C ~/devenv fetch origin
git -C ~/devenv switch fm/devenv-android-emulator
```

Run this on each host (WSL2 and the native Linux laptop); report which one.

1. **Docker Engine** (skip what's already there). Docker's apt repository is
   set up for sbx:
   ```sh
   docker info --format '{{.OperatingSystem}}' 2>&1 | tail -n 1
   ```
   `Docker Desktop` there means the `docker` in this Linux talks to Docker
   Desktop, whose containers get no `/dev/kvm`: turn off Docker Desktop's WSL
   integration for this distro first. A missing `docker`, or `permission
   denied`:
   ```sh
   sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin
   sudo usermod -aG docker $USER      # then close the terminal and open a new one (on WSL: wsl --shutdown)
   docker run --rm hello-world | head -n 2
   ```
   Expected: `Hello from Docker!`.

2. **Doctor, before the first start:**
   ```sh
   ~/devenv/bin/devenv doctor | sed -n '/^Android emulator/,/^Operating rule/p'
   ```
   Expected: `ok    Docker Engine 29.…`, notes that the image and SDK volume
   aren't made yet and that it isn't running, and `warn  sandboxes can't reach
   it: allow it once with: sbx policy allow network localhost:15555`. Report
   the lines if any says `FAIL`, or if the policy line is missing (then paste
   `sbx policy check network --sandbox dev localhost:15555`).

3. **First start** (downloads 2.2 GB, then boots; 5 to 15 minutes):
   ```sh
   time ~/devenv/bin/devenv emulator start
   ```
   Expected, in order: `emulator image devenv-android-emulator:… built`,
   `downloads match versions.env`, `devenv: SDK unpacked (5.1G)`, `emulator
   started …`, `Android booted (…s)`, `adb answers on 127.0.0.1:15555`, the
   policy warning, and how to use and stop it. Paste the output and the time.
   If it stops with `the emulator stopped while booting`, paste its output and
   `docker logs devenv-android-emulator 2>&1 | tail -n 60`.
   `x86_64 emulation currently requires hardware acceleration` there means
   the container got no working KVM (on WSL: nested virtualization);
   `does not have enough disk space` means Docker's disk is too full
   (`df -h /var/lib/docker`).

4. **Cost**, while it runs:
   ```sh
   docker stats --no-stream devenv-android-emulator --format '{{.MemUsage}} {{.CPUPerc}}'
   docker system df -v | grep -E 'devenv-android|^VOLUME NAME|^REPOSITORY'
   free -g | head -n 2
   ```
   Paste it (the README says about 5 GB of memory, 5.1 GB of volume and under
   0.5 GB of image).

5. **The policy rule**, once (it covers every sandbox and survives rebuilds):
   ```sh
   sbx policy allow network localhost:15555
   ~/devenv/bin/devenv emulator status
   ```
   Expected: `ok    running; Android booted; adb answers on 127.0.0.1:15555`
   and `ok    sandbox dev may reach it (the network policy allows
   localhost:15555)`.

6. **From the sandbox.** A sandbox gets `adb` when it is created (the kit
   provisions it), and a merged PR reaches the running sandbox's devenv clone.
   Until then, **(in sandbox)** take the branch into a temporary worktree and
   install only `adb` from it (this leaves the environment block alone):
   ```sh
   git -C ~/fm-projects/devenv fetch -q origin fm/devenv-android-emulator
   git -C ~/fm-projects/devenv worktree add -f /tmp/devenv-emu FETCH_HEAD
   bash -c 'DEVENV_ROOT=/tmp/devenv-emu; . $DEVENV_ROOT/lib/common.sh; . $DEVENV_ROOT/lib/android.sh
     load_config; resolve_paths; install_platform_tools'
   ```
   Expected: `adb 37.0.1 installed in /home/agent/.local/share/android-sdk/platform-tools`.
   Then **(in sandbox)**:
   ```sh
   D=/tmp/devenv-emu/bin/devenv
   adb --version | sed -n 2p
   $D emulator status
   $D emulator connect
   $D emulator run -- adb shell getprop ro.build.version.sdk
   $D emulator run -- adb shell pm list packages | wc -l
   ```
   Expected: `Version 37.0.1-…`; `ok    adb 37.0.1` and `ok    an emulator
   answers at host.docker.internal:15555`; `connected to the emulator:
   host.docker.internal:15555 (Android 16, API 36)` and the serial; `36`; a
   package count in the hundreds. Before step 5's rule, `status` instead says
   `the network policy doesn't let this sandbox reach localhost:15555 …`.
   Paste everything. If `connect` fails after `status` said the emulator
   answers, paste `adb devices -l` and `adb connect host.docker.internal:15555`.
   Afterwards: `git -C ~/fm-projects/devenv worktree remove --force /tmp/devenv-emu`.

7. **A real test** (optional, if a phone-app project with instrumented tests
   is at hand): in its worktree **(in sandbox)**, `devenv emulator run --
   ./gradlew connectedDebugAndroidTest`. It needs a JDK and the project's SDK
   packages, which devenv doesn't install; report what was missing.

8. **Stop and clean:**
   ```sh
   ~/devenv/bin/devenv emulator stop
   free -g | head -n 2
   ~/devenv/bin/devenv emulator start     # a restart: no download, boot only
   ~/devenv/bin/devenv emulator stop
   ```
   Expected: `emulator stopped; its image and SDK volume stay…`, the memory
   back, and the second start going straight to `emulator started`. Keep the
   image and volume for later use; `~/devenv/bin/devenv emulator clean`
   removes them (about 5.5 GB).

9. **After a restart** (a WSL restart, or a reboot): nothing starts by itself.
   `docker ps -a --filter name=devenv-android-emulator` shows nothing, and
   `devenv emulator start` boots it again in 1 to 3 minutes.

Switch the checkout back to `main` once the PR is merged.
