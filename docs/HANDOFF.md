# Handoff: devenv implementation, session 1 → session 2

Written 2026-09-26 at the end of the first implementation session. Read this,
then [SPEC.md](SPEC.md) (the approved design), [README.md](../README.md) and
[HOST-VERIFY.md](HOST-VERIFY.md). This file records what the code alone
doesn't: decisions made with the owner after the spec, what is verified, and
what is still open.

## Working rules (from the owner and the spec)

- The owner is `digigrant` (Firstmate calls them "the captain"). Agents act as
  the machine account `gej-machine` (git identity
  `gej-machine <318032932+gej-machine@users.noreply.github.com>`).
- Never work on `main`. Work on a branch, commit and push at sensible
  intervals, deliver by PR. **Never merge**; the owner reviews and merges.
- If something is unclear, or a V-item's documented fallback also fails,
  stop and ask the owner. When stopping to ask, explain the issue in plain
  terms and give options with a recommendation; the owner has asked for that.
- The Firstmate fork (`digigrant/firstmate`) may be modified, **minimally**,
  and only after showing that unmodified Firstmate doesn't work.
- Treat `~/dev` as belonging to the sandbox: never run git, scripts or build
  tools in it on the host (D28). Never allow `herdr.dev`. No secrets in the
  repo. Never add shell-completion scripts to `/etc/sandbox-persistent.sh`.
- Don't touch the owner's old `/home/gejoy/dev/.claude/` files until Phase 5,
  and only with the owner's confirmation.

## Where things stand

- **PR:** https://github.com/digigrant/devenv/pull/1, branch `initial-setup`,
  open, head `bca4ee5`. Its description lists V-item results, spec
  differences and known risks. Keep it current. Note that `gh pr edit` fails
  because the gej-machine token lacks `read:org`, so edit it with the REST
  API: `gh api -X PATCH repos/digigrant/devenv/pulls/1 -F body=@file.md`.
- **Commits on the branch:**

  | Commit | What |
  |---|---|
  | `3cd88ee` | spec added as `docs/SPEC.md` |
  | `bfa6528` | provisioning, CLI, kit, tests (the bulk of the implementation) |
  | `3af324c` | fix: settings merge dropped other tools' hooks (jq filter-parameter scoping) |
  | `c41060e` | README, HOST-VERIFY, sbx simulation test; write files in place to keep owners |
  | `92edd86` | `github` binding in sbxenv.yaml; host-side check of the github secret; failed clone no longer tears down the create |
  | `4168f37` | V1 `/login` fallback (superseded by `e5cb8b9`) |
  | `e5cb8b9` | Claude signs in with the setup-token as an sbx custom secret (`CLAUDE_AUTH=token`) |
  | `67d285d` | Firstmate from the owner's fork `digigrant/firstmate` |
  | `bca4ee5` | automatic Firstmate updates at every first-mate start; the Firstmate pin removed |

- **Tests:** `devenv test` passes at `bca4ee5`: status line byte-identity,
  shellcheck, `provision.sh --plain` twice in `ubuntu:24.04` and
  `ubuntu:26.04`, and the simulated sbx create (`tests/sbx-sim.sh`).
- **Host (owner, WSL2, sbx 0.45.1):** HOST-VERIFY steps 1–4 passed. The first
  real create exposed three problems, all fixed on the branch: a rejected
  GitHub token, V1, and a missing `github` binding. The owner is re-running
  HOST-VERIFY from step 5 with the current branch. Their latest results are
  not recorded here, so ask for them.

## Decisions made after the spec

| Topic | Spec said | Now | Why |
|---|---|---|---|
| herdr Claude detection (V3) | bundled rules | herdr's own published `distribution/agent-detection/claude.toml` (herdr `a05c403`, v2026.09.11.1), sha256-pinned, installed as `~/.config/herdr/agent-detection/claude.toml` | herdr 0.8.0's bundled rules predate Claude Code 2.1.228's title spinner (◐◑), so herdr never showed Claude as "working". Owner chose this ("option A"). `devenv bump herdr-manifest latest` refreshes it. |
| Claude sign-in (V1) | setup-token as the sbx `anthropic` secret | setup-token as an sbx **custom secret**: `CLAUDE_CODE_OAUTH_TOKEN` holds a placeholder, and the proxy swaps in the real token for `api.anthropic.com`. `devenv host-prepare` sets it up (`CLAUDE_AUTH=token`); `CLAUDE_AUTH=login` is the `/login` fallback | As the `anthropic` secret, sbx treated it as an API key (`SBX_CRED_ANTHROPIC_MODE=apikey`) → HTTP 401. A host probe of the custom secret passed: `authMethod: oauth_token`, `claude -p` works, and `quota-axi` reads the Pro windows. Unmodified Firstmate works with it; the fork needed no change. The token is inference-only: no claude.ai connectors, Remote Control, Claude in Chrome or plugin sync. |
| Effort default (V9) | model-independent key if one exists | `modelSettings.<model>.effortLevel` for the models in `CLAUDE_EFFORT_MODELS` | Claude Code 2.1.x treats a top-level `effortLevel` in user settings as legacy and ignores it for `claude-opus-5-5`. |
| Node floor | ≥ 20 | ≥ 22.19 (`NODE_MIN_VERSION`); plain mode pins 24.21.0 | `quota-axi@0.1.54` declares `engines.node >=22.19`. |
| sbxenv agent | `agent: ./kits/devenv` | `agent: devenv` + `kits: [./kits/devenv]` | Docker's current sbxenv reference. `sbx env plan` on the host accepted it. |
| GitHub credential | secret only | secret plus `bindings.github` (api.github.com, github.com) | Docker requires a binding for a third-party kit to use a stored credential. |
| Firstmate source | `kunchenguid/firstmate` pinned at a commit, `devenv bump firstmate` | the owner's fork `digigrant/firstmate`, **not pinned**, updated automatically (see below) | Owner's decision (replaces D15). |
| Firstmate updates | manual (`/updatefirstmate`, then `devenv bump`) | whenever `devenv entry` starts a first mate: fast-forward the fork from upstream with GitHub's Sync fork (only when strictly behind), then Firstmate's own `bin/fm-update.sh`. `FIRSTMATE_AUTO_UPDATE=off` pauses both | Owner's decision: automatic fast-forward, no review. Upstream ships ~100 commits a week. |
| Memory location (§6.11) | symlinks, or a setting if one exists | symlinks (`devenv start` and a `SessionStart` hook) | Claude's `autoMemoryDirectory` is one fixed folder for all projects. |

## Verification status

| Item | Status |
|---|---|
| V1 | Resolved with the custom secret (probe passed on the host). Still to confirm in `dev` itself: HOST-VERIFY V1, including "still signed in after a second `sbx env run`" (the placeholder must stay stable). |
| V2 | Plan accepted `agent: devenv`; `extends: claude` resolved (claude template image, inherited credential). Detach/re-attach and herdr-server survival still to check on the host. In the sandbox, a second `devenv entry` re-attached with one `firstmate` workspace (AC3). |
| V3, V8, V9 | Done in the sandbox (see decisions). |
| V4 | Host-prepare reported `skills in the sbx store (import): grill-me grilling`, but see **issue 1** below. |
| V5 | Relative paths resolved in the plan; the install step saw the read-only mount. Mount details (rw workspace, ro devenv) still to check. |
| V6, V10, V11, V12 | Host checks pending. In the sandbox: memory written by Claude lands in the state folder through the symlink; Firstmate's detect-only bootstrap reports nothing missing except the optional `PRESENTATION_UNAVAILABLE: lavish-axi`. |
| V7 | **Passed on the host.** |
| AC5, AC8, AC9, AC12, AC13–AC16 | Checked in the sandbox (AC13 on a simulated host). |

## Open work

### 1. Firstmate doesn't see `/grill-me` or `/grilling` (reported by the owner)

Not investigated yet. What is known:

- Delivery is `DEVENV_SKILLS=store`: `devenv host-prepare` runs
  `sbx skills import` with a staging `HOME`, and sbx should mount its shared
  store read-only at `~/.claude/skills` in the sandbox. Host-prepare reported
  success.
- Likely cause, unconfirmed: Docker's docs say the store is mounted for
  sandboxes "created for a supported agent". Our agent is the third-party kit
  `devenv` (extends `claude`), which may not qualify. The 0.45 release notes
  mention that *v3* kits can declare where an agent reads shared skills,
  which suggests v2 third-party kits may not get the mount.
- Other candidates: the import landed in a different store (the staging
  `HOME` trick), or `~/.claude/skills` is mounted but empty.
- The owner's old project-level copies in `~/dev/.claude/skills` are only
  seen by sessions whose project root is `~/dev`. `~/dev/firstmate` is its
  own git root, so the first mate doesn't see them.
- First checks: in the sandbox, `mount | grep -i skill` and
  `ls -la ~/.claude/skills`; on the host, `sbx skills ls`.
- The documented fallback (V4) is `sandboxOptions.skills: off` in
  `sbxenv.yaml` plus `DEVENV_SKILLS=link` in `devenv.conf`. `devenv start`
  then symlinks `~/.claude/skills/<name>` to `$DEVENV_DIR/skills/<name>`,
  which is code that already exists. This needs a recreate. In session 1,
  symlinked skills were listed by Claude (tested in a scratch `HOME`).
  `grill-me` has `disable-model-invocation: true`: it appears as a slash
  command but is never auto-invoked.
- Acceptance (AC7): both skills listed in a session in `~/dev/firstmate` and
  in a treehouse worktree.

### 2. Let Firstmate work in the devenv repo (owner's request)

The owner wants Firstmate (the first mate and its workers) to be able to change
devenv: branches, commits, pushes, PRs. Today the only copy in the sandbox is
the read-only mount of the owner's host checkout.

**Do not make that mount writable.** The owner's host runs code from
`~/devenv` on every `sbx env run`: the `lifecycle.initialize` hook
(`bin/devenv host-prepare`), the secret `command:`s, and the kit's install
step. A writable mount would let the sandbox change code that runs on the host
with the owner's privileges. That breaks security invariants 2 and 3 (SPEC
§10) and D3 (changes arrive only by PR, then the owner pulls).
`doctor`/`host-prepare` also refuse a checkout that overlaps a sandbox
workspace.

Recommended approach, consistent with D3 and how Firstmate already works:

- Register `digigrant/devenv` as a Firstmate **project**. Firstmate clones
  projects under `$FM_PROJECTS_OVERRIDE` (`~/fm-projects`, sandbox disk) and
  its workers use treehouse worktrees; delivery mode `direct-PR`.
  gej-machine already has write access (it pushed PR #1). Check Firstmate's
  own docs and `AGENTS.md` for the exact project-registration flow;
  `data/projects.md` holds the registry.
- The owner merges, then `git -C ~/devenv pull` on the host. Nothing changes
  on the host side.
- Optionally add a devenv `CLAUDE.md` or `AGENTS.md` for workers: the rules
  above, `devenv test` as the check, the pinned shellcheck image. And
  consider whether `repos.txt` should list it (that clones into `~/dev`,
  which the owner's host can see, so `~/fm-projects` is probably better).
- Confirm the plan with the owner before building. They said the next
  session would "adjust that", and may have the mount itself in mind.

### 3. Keep agents off `main` while syncing automatically (design agreed in part, not built)

The owner wants agents never to push to `main`, only branches and PRs. They
disabled the fork's ruleset because it blocked the automated sync: Sync fork
counts as a direct update to `main`, so it was refused with HTTP 422. GitHub
bypass lists work by role, not action, so gej-machine can't be allowed to sync
without also being allowed to push.

Proposed option, not built: re-enable a ruleset requiring PRs on the fork's
`main`, with **Repository admin** on its bypass list. Then move the sync from
`devenv entry` (sandbox, gej-machine) to `devenv host-prepare` (host, the
owner's own `gh` login), so only the owner's credential can fast-forward
`main`. It needs `gh` on the host, logged in as `digigrant`. The same kind of
ruleset (no bypass needed) would suit `digigrant/devenv`; whether it has one
wasn't checked. Get the owner's go-ahead first.

Related: a sync whose upstream commits change `.github/workflows/` needs the
`workflow` scope on whichever token syncs. gej-machine's token has only
`repo`, so such syncs currently stall with a `devenv check` warning. Granting
`workflow` to gej-machine also lets agents run workflows, with the repos'
Actions secrets, from any branch they push. That trade-off was explained to
the owner, who hasn't decided.

### 4. Host verification (owner)

Continue HOST-VERIFY from step 5 with the current branch. After pulling: if
`~/dev/firstmate` was cloned from `kunchenguid` earlier, run (in the sandbox)
`git -C "$FM_HOME" remote set-url origin https://github.com/digigrant/firstmate`;
`devenv check` warns until it's done. Apply fallbacks per the owner's
reports, and push fixes to PR #1.

### 5. Smaller items

- The setup-token's expiry date, for `ANTHROPIC_TOKEN_EXPIRES` in
  `devenv.conf`; ask the owner. The new GitHub token expires
  2026-12-24 21:55 UTC and is tracked automatically through the API.
- The fork sync's fast-forward path hasn't run for real yet (the fork was
  already current). The next first-mate start with upstream ahead will
  exercise it: look for `firstmate sync: fast-forwarded …` in
  `devenv check`.
- Phase 5, after merge (owner): `sbx rm claude-dev`, then, with confirmation,
  remove `/home/gejoy/dev/.claude/settings.json` (project-level statusLine),
  `statusline-command.sh` and `skills/`.
- herdr switches to "working" about 3 s after a turn starts. That looks like
  herdr's own debounce; informational.
- Newer upstream versions exist but aren't adopted: herdr 0.9.1 (Firstmate
  has verified ≤ 0.8.0) and treehouse 3.0.0 (major bump). `devenv bump --list`
  shows them.

## Facts and traps learned in session 1

**sbx (0.45.1)**
- A failed create only says `failed to apply kit to sandbox`. The real
  error, with the install step's output, is in
  `~/.local/state/sandboxes/sandboxes/sandboxd/daemon.log` on the host
  (`grep 'create sandbox failed'`; HOST-VERIFY shows a masked version). Clean
  up with `sbx env rm`.
- `setup.install` runs as root, synchronously, before the terminal attaches.
  `setup.startup` runs from a detached dispatcher
  (`/var/log/sbx-kit-startup.log`) and can race the session, so
  `devenv entry` re-applies the settings merge under a lock.
- The claude kit rewrites `~/.claude/settings.json` and `~/.claude.json` at
  every create.
- Sandbox-scoped secrets take precedence over global ones. `claude-dev`
  (this session's sandbox) has its own sandbox-scoped github secret, updated
  with `sbx secret set github --sandbox claude-dev -t …`. When GitHub returns
  401 from `claude-dev`, that's usually the cause.
- Custom secrets: `sbx secret set-custom --sandbox dev --host … --env …
  --placeholder … --command …` is create-or-update. Remove one with
  `sbx secret rm --placeholder <value> -f`. `sbxenv.yaml` can't declare them.
  Command sources run from a temp directory on the host, so they need
  absolute paths. The devenv placeholder lives in
  `~/.config/devenv/claude-oauth-placeholder` on the host.
- Docs source: `docker/docs` on GitHub, `content/manuals/ai/sandboxes/` and
  CLI reference YAML in `data/sbx_cli/`. The v2 kit validator is Go code in
  `docker/sbx-kits-contrib/spec` (`LoadFromDirectory` + `ValidateArtifact`);
  `kits/devenv` passes it.

**Claude Code (2.1.282)**
- Auth precedence: an `apiKeyHelper` or API key outranks
  `CLAUDE_CODE_OAUTH_TOKEN`, which outranks the stored `/login`.
- `$HOME` expands in the `statusLine` command.
- Inside `claude-dev`, the proxy swaps the sentinel `sk-ant-oat01-proxy-managed`
  for the real login. So a scratch `HOME` with
  `CLAUDE_CODE_OAUTH_TOKEN=sk-ant-oat01-proxy-managed` (or a copied
  `.credentials.json`) runs real Claude sessions without touching the live
  `~/.claude`. That's how herdr detection, entry, effort and memory were
  tested. Unset this session's `CLAUDE*` variables in such tests. Each test
  session draws on the owner's Pro quota; keep them short.

**herdr (0.8.0)**
- Local detection overrides are read from
  `~/.config/herdr/agent-detection/<agent>.toml`. Check which rules are
  active with `herdr server reload-agent-manifests` or
  `herdr agent explain <pane>`.
- A pane attached under `script` with no terminal size shrinks to 2 rows. Use
  `script -qfec "stty rows 40 cols 120; devenv entry" /dev/null`.

**Firstmate**
- Workers inherit the environment unless the opt-in
  `config/launch-env-allowlist` or `config/claude-account` exists (devenv
  creates neither).
- `FM_BOOTSTRAP_DETECT_ONLY=1 bin/fm-bootstrap.sh` is the read-only probe
  (`devenv doctor` uses it).
- `bin/fm-update.sh` is the fast-forward-only updater behind
  `/updatefirstmate`.

**GitHub**
- gej-machine's token has scope `repo` only. GraphQL calls that need
  `read:org` fail (e.g. `gh pr edit`); use REST.
- `gh repo view` misreports a fork's parent without `read:org`; use
  `gh api repos/<o>/<r>`.

## Working on this repo

- Clone to the sandbox disk (e.g. `~/src/devenv`), never under `~/dev`. Set
  the bot identity locally: `git config user.name gej-machine` and
  `user.email 318032932+gej-machine@users.noreply.github.com`.
- `./bin/devenv test` runs everything (~10 min; Docker in the sandbox; test
  containers use `--network host` and the proxy CA).
  `./bin/devenv test --no-containers` takes seconds.
- shellcheck: `. ./versions.env; docker run --rm -v "$PWD:/mnt:ro" -w /mnt "$TEST_SHELLCHECK_IMAGE" -x provision.sh bin/devenv bin/devenv-entry agents/claude/statusline.sh agents/claude/hooks/memory-link.sh tests/*.sh`
- To exercise sbx-mode provisioning in `claude-dev` without touching live
  files, point `HOME`, `WORKSPACE_DIR`, `DEVENV_ENV_FILE`,
  `DEVENV_SYSTEM_PREFIX` and `NPM_CONFIG_PREFIX` at scratch paths.
- To exercise host commands, use a scratch `HOME` and a fake `sbx` on `PATH`
  that logs its arguments. `DEVENV_EXTRA_WORKSPACES` simulates overlapping
  workspaces for the checkout-location check.
- Keep the PR description, README and HOST-VERIFY in step with the code.
