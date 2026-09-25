# Host verification checklist

The agent that built devenv cannot run `sbx`, so these checks run on the host
(WSL2 today, native Linux later). Run them in order and paste each block's
output back into the PR. Commands marked **(in sandbox)** run inside the new
`dev` sandbox: open a shell pane in herdr (`ctrl+b`, then the new-pane key),
or run them from the host with `cd ~/devenv && sbx env exec -- bash -lc '…'`.

Where a check fails, its fallback is listed. Don't apply fallbacks yourself;
report the output and the agent will push the fix to this PR.

The old `claude-dev` sandbox keeps running alongside `dev` until the
switchover (spec §9, Phase 5). Both mount `~/dev`.

---

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

## 2. Clone devenv next to the workspace

```sh
git clone -b initial-setup https://github.com/digigrant/devenv ~/devenv   # after merge: without -b
ls ~/devenv
```

Expected: the repo files, in `~/devenv`, beside (not inside) `~/dev`.

## 3. Secrets

```sh
install -d -m 700 ~/.config/devenv/secrets
(umask 077; cat > ~/.config/devenv/secrets/anthropic)   # paste the `claude setup-token` token, Enter, Ctrl-D
(umask 077; cat > ~/.config/devenv/secrets/github)      # paste the gej-machine token, Enter, Ctrl-D
ls -l ~/.config/devenv/secrets
```

Expected: two files, `-rw-------`, owned by you. The github secret must be
the **gej-machine** token (never your personal one).

If you know when the setup-token expires, put the date (YYYY-MM-DD) in your
report: the agent will set `ANTHROPIC_TOKEN_EXPIRES` in `devenv.conf` in this
PR, so the checkout stays clean.

## 4. Doctor

```sh
~/devenv/bin/devenv doctor
```

Expected: every line `ok`, except warnings for "ANTHROPIC_TOKEN_EXPIRES is not
set" and "on initial-setup, not main" (while testing the PR branch); on WSL a
note that the Linux sbx is "best-effort" there; the operating rule at the end.

Also check that doctor refuses unsafe setups (AC13). Each must print a `FAIL`
line and exit 1:

```sh
chmod 644 ~/.config/devenv/secrets/github
~/devenv/bin/devenv doctor | grep FAIL; echo "exit=${PIPESTATUS[0]}"
chmod 600 ~/.config/devenv/secrets/github

# Pretend a sandbox mounts your whole home (which contains ~/devenv):
DEVENV_EXTRA_WORKSPACES=$HOME ~/devenv/bin/devenv doctor | grep FAIL; echo "exit=${PIPESTATUS[0]}"
```

Expected: `FAIL … secrets/github is mode 644` with exit=1, then
`FAIL the devenv checkout overlaps a sandbox workspace (/home/<you>)` with
exit=1. (Nothing here writes to or runs from `~/dev`.)

## 5. Plan and create

```sh
cd ~/devenv && sbx env plan
```

Paste the whole plan. It should show: sandbox `dev`; agent/kit `devenv` from
`./kits/devenv` extending `claude`; workspace `/home/<you>/dev` (read-write);
additional workspace `/home/<you>/devenv` (read-only); env `DEVENV_ENTRY=herdr`;
secrets `anthropic` and `github` from commands; skills `readonly`; the
`devenv host-prepare` lifecycle command.

If the plan rejects `agent: devenv` (V2), try the spec's original form: in
`sbxenv.yaml` replace the `agent:` and `kits:` lines with
`agent: ./kits/devenv`, re-run `sbx env plan`, and report which form worked.

Then:

```sh
sbx kit inspect ./kits/devenv      # if this subcommand exists: shows the resolved kit
cd ~/devenv && sbx env run
```

Save the whole create output (it includes `devenv: install sees …` and
`devenv: provisioning from …` lines from the kit's install step). You should
land in herdr, in a workspace named **firstmate**, with Claude starting in
`~/dev/firstmate`.

---

## 6. Verification items

### V1: subscription token as the `anthropic` secret

**(in sandbox)**
```sh
echo "$SBX_CRED_ANTHROPIC_MODE"
claude -p "reply with the single word ok"
```

Expected: `oauth`, then `ok`, with no `/login`.
Fallback if not: drop the `anthropic` secret; you run `/login` once per rebuild.

### V2: local sandbox kit as the agent; herdr across detach

1. You landed in herdr (step 5) rather than plain Claude.
2. Detach with `ctrl+b q`. Then from the host:
   ```sh
   cd ~/devenv && sbx env exec -- bash -lc 'herdr status server --json; herdr workspace list'
   ```
   Report whether the server is still `running` and the `firstmate` workspace
   still exists after the detach.
3. Re-attach: `cd ~/devenv && sbx env run`. Expected: back in the same
   workspace, still exactly **one** `firstmate` workspace (AC3).

**(in sandbox)** — check whether inherited claude flags reach the entrypoint:
```sh
cat /proc/1/cmdline 2>/dev/null | tr '\0' ' '; echo; ps -eo pid,args | grep -E 'devenv-entry|devenv entry' | grep -v grep
```

Fallback if the kit can't be used as the agent: the mixin form described at
the top of `kits/devenv/spec.yaml`.

### V4: skills in sbx's shared store

```sh
sbx skills ls
```

Expected: `grill-me` and `grilling`. The `devenv host-prepare` output (during
`sbx env run`) says `skills in the sbx store (import)` or `(copy)`; report
which. **(in sandbox)** `ls -la ~/.claude/skills` lists both.

Removal check (runs a throwaway copy, not your checkout):
```sh
rm -rf /tmp/devenv-skills-test && cp -r ~/devenv /tmp/devenv-skills-test
mkdir -p /tmp/devenv-skills-test/skills/zz-devenv-test && printf -- '---\nname: zz-devenv-test\ndescription: test\n---\ntest\n' > /tmp/devenv-skills-test/skills/zz-devenv-test/SKILL.md
/tmp/devenv-skills-test/bin/devenv skills-sync && sbx skills ls
rm -rf /tmp/devenv-skills-test/skills/zz-devenv-test && /tmp/devenv-skills-test/bin/devenv skills-sync && sbx skills ls
rm -rf /tmp/devenv-skills-test; ~/devenv/bin/devenv skills-sync
```

Expected: `zz-devenv-test` appears after the first sync and is gone after the
second. Fallback if the store can't be filled: `sandboxOptions.skills: off`
plus `DEVENV_SKILLS=link` (skills linked by `devenv start`).

### V5: relative paths and mounts

**(in sandbox)**
```sh
echo "WORKSPACE_DIR=$WORKSPACE_DIR DEVENV_DIR=$DEVENV_DIR"
mount | grep -E ' /home/[^ ]*/(dev|devenv) ' ; touch "$DEVENV_DIR/x" 2>&1 | head -1
```

Expected: `/home/<you>/dev` is read-write, `/home/<you>/devenv` is read-only
(`touch` fails with "Read-only file system"), and only one mount for devenv
(report any second mount sbx makes for the `sbxenv.yaml` folder itself).
Fallback: `${{ env.fileDir }}` paths, then `~/devenv/bin/devenv up`.

### V6 and AC10: persistence across `sbx rm`

**(in sandbox)** ask the first mate: *"Save to your memory: the devenv V6
check word is lighthouse."* Then:
```sh
ls ~/dev/.devenv-state/claude-memory/*/          # (in sandbox) the memory file is here
ls ~/dev/firstmate/config ~/dev/firstmate/state ~/dev/firstmate/data 2>&1 | head
```

Remove and rebuild from the host:
```sh
cd ~/devenv && sbx env rm        # approve; this deletes the sandbox, not ~/dev
cd ~/devenv && sbx env run
```

**(in sandbox)** after the rebuild:
```sh
ls -la ~/.claude/projects/*/memory                 # symlinks into ~/dev/.devenv-state/claude-memory
grep -rl lighthouse ~/dev/.devenv-state/claude-memory
ls ~/dev/firstmate/config; ls ~/fm-projects ~/.treehouse 2>&1 | head -3
```

Expected: the memory is still there and linked; Firstmate's `config/`,
`data/`, `state/` survived; `~/fm-projects` and `~/.treehouse` are gone or
empty. Ask the first mate *"What is the devenv V6 check word?"*: it should
answer lighthouse. Fallback: a `lifecycle.preRemove` hook.

### V7: devenv mount during `setup.install`

From the create output saved in step 5:
```text
devenv: install sees WORKSPACE_DIR=/home/<you>/dev; checkout mount /home/<you>/devenv: README.md bin ...
devenv: provisioning from /home/<you>/devenv
```

Expected: the file list is not empty. Fallback: `DEVENV_STAGE_PAYLOAD=on`.

### V10: settings survive a restart

```sh
sbx stop dev && cd ~/devenv && sbx env run
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
scope and Firstmate says non-visual work proceeds without it).

---

## 7. Acceptance checks

| AC | How | Expected |
|---|---|---|
| AC1 | steps 5 and V6 | `sbx env run` builds `dev` with no manual steps (plus `/login` only if V1 fell back) |
| AC2 | the first-mate pane | Claude banner "Opus 5.5 with xhigh effort", status line `effort:xhigh`, cwd `~/dev/firstmate`; V12 clean |
| AC3 | V2 step 3 | one `firstmate` workspace after re-running `sbx env run` |
| AC4 | edit `env.DEVENV_ENTRY` in `~/devenv/sbxenv.yaml` to `claude`, `sbx env run`; then `shell`; then back to `herdr` | plain Claude in `~/dev`; then a bash prompt; no recreate. (Don't commit the edit.) Note: until the Phase 5 cleanup, Claude in `~/dev` uses the old project-level status line |
| AC5 | **(in sandbox)** `bash "$DEVENV_DIR/tests/statusline-identity.sh"` | `statusline identity: PASS (5 fixtures)` |
| AC6 | V10, and again after the V6 recreate | as in V10 |
| AC7 | **(in sandbox)** type `/gril` in the first-mate pane; then `mkdir -p ~/.treehouse/skilltest && cd ~/.treehouse/skilltest && claude` and type `/gril` | `/grill-me` and `/grilling` listed in both |
| AC8 | **(in sandbox)** `WARN_DAYS=60 devenv check`; `git -C ~/dev/firstmate commit --allow-empty -m test && devenv check`; `DEVENV_ENTRY=shell devenv entry` | token expiry warning (bot token expires 2026-10-25), "firstmate 1 commits ahead of pin", warnings printed in yellow, `⚠ devenv:N` in Claude's status line. Undo with `git -C ~/dev/firstmate reset --hard HEAD~1 && devenv check` |
| AC9 | already verified in the sandbox by the agent (PR description) | — |
| AC10 | V6 | as in V6 |
| AC11 | **(in sandbox)** `git config --global user.name; git config --global user.email; gh api user --jq .login` | `gej-machine`, `318032932+gej-machine@users.noreply.github.com`, `gej-machine`. Optionally ask the first mate for a throwaway draft PR to confirm push and `gh pr create`, then close it |
