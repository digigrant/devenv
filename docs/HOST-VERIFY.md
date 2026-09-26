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

```sh
install -d -m 700 ~/.config/devenv/secrets
(umask 077; cat > ~/.config/devenv/secrets/anthropic)   # paste the `claude setup-token` token, Enter, Ctrl-D
(umask 077; cat > ~/.config/devenv/secrets/github)      # paste the gej-machine token, Enter, Ctrl-D
ls -l ~/.config/devenv/secrets
```

Expected: two files, `-rw-------`, owned by you. The github secret must be the
**gej-machine** token (never your personal one). The anthropic file holds the
setup-token (`sk-ant-oat01-…`); `devenv host-prepare` turns it into a custom
secret (see V1). (Skip if already done.)

## 4. Doctor

```sh
~/devenv/bin/devenv doctor
```

Expected: every line `ok`, including `…/secrets/anthropic (0600, a
setup-token)`, `github secret authenticates as gej-machine (… expires …)` and
`not inside any sandbox workspace; only dev/ is shared with the sandbox`,
except warnings for "ANTHROPIC_TOKEN_EXPIRES is not set" and "on
initial-setup, not main" (while testing the PR branch); on WSL a note that the
Linux sbx is "best-effort" there; the operating rule at the end (it now names
`~/devenv/dev` and `git clean -x`). If GitHub rejects the github secret (HTTP
401), make a new classic `repo` token for gej-machine and write it to the file
again. `devenv host-prepare` refuses to create the sandbox until it passes.

Also check that doctor refuses unsafe setups (AC13). Each must print a `FAIL`
line and exit 1:

```sh
chmod 644 ~/.config/devenv/secrets/github
~/devenv/bin/devenv doctor | grep FAIL; echo "exit=${PIPESTATUS[0]}"
chmod 600 ~/.config/devenv/secrets/github

# Pretend a sandbox mounts your whole home (which contains ~/devenv):
DEVENV_EXTRA_WORKSPACES=$HOME ~/devenv/bin/devenv doctor | grep FAIL; echo "exit=${PIPESTATUS[0]}"

# Pretend a sandbox mounts a folder of the checkout other than dev/:
DEVENV_EXTRA_WORKSPACES=$HOME/devenv/lib ~/devenv/bin/devenv doctor | grep FAIL; echo "exit=${PIPESTATUS[0]}"
```

Expected: `FAIL … secrets/github is mode 644` with exit=1; then
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
additional workspaces; env `DEVENV_ENTRY=herdr`; the `github` secret from a
command (no `anthropic` secret); a `github` binding for `api.github.com` and
`github.com`; skills `off`; the `devenv host-prepare` lifecycle command.

Then:

```sh
cd ~/devenv && sbx env run --kit-arg ref=initial-setup
```

Save the whole create output. The `devenv host-prepare` part should include
`created the workspace /home/<you>/devenv/dev` (first run only) and end with
`Claude setup-token available to sandbox dev as CLAUDE_CODE_OAUTH_TOKEN
(placeholder)`. You should land in herdr, in a workspace named **firstmate**,
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

Check it in `dev` **(in sandbox)**:
```sh
echo "mode=$SBX_CRED_ANTHROPIC_MODE var=${CLAUDE_CODE_OAUTH_TOKEN:0:7}"   # mode=none var=sbx-cs-
claude auth status | head -n 4                    # "loggedIn": true, "authMethod": "oauth_token"
claude -p "reply with the single word ok" < /dev/null   # ok
devenv doctor | sed -n '/^accounts/,/^herdr/p'    # all ok
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
```

Expected: `## initial-setup...origin/initial-setup`, the branch's head commit,
and `devenv runs from /home/agent/fm-projects/devenv, on initial-setup at …`.

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
         release-assets.githubusercontent.com raw.githubusercontent.com registry.npmjs.org nodejs.org herdr.dev; do
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
