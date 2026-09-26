# Handoff: devenv implementation

Written 2026-09-26 at the end of the first implementation session; updated
the same day in session 2, which restructured the sbx layer to Docker's
layout. Read this, then [SPEC.md](SPEC.md), [README.md](../README.md) and
[HOST-VERIFY.md](HOST-VERIFY.md).

**SPEC.md is current:** session 2 revised it to the design as built, including
every decision below. This file records what the spec doesn't: why things
changed from the originally approved spec (commit `3cd88ee`), what is
verified, what is still open, and traps learned along the way.

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
- Treat the workspaces as belonging to the sandboxes (`~/devenv/dev` for `dev`,
  `~/dev` for the old `claude-dev`): never run git, scripts or build tools in
  them on the host (D28). Never allow `herdr.dev`. No secrets in the repo.
  Never add shell-completion scripts to `/etc/sandbox-persistent.sh`.
- Don't touch the owner's old `/home/gejoy/dev/.claude/` files until Phase 5,
  and only with the owner's confirmation.

## Where things stand

- **PR:** https://github.com/digigrant/devenv/pull/1, branch `initial-setup`,
  open. Its description lists V-item results, spec differences and known
  risks. Keep it current. Note that `gh pr edit` fails because the
  gej-machine token lacks `read:org`, so edit it with the REST API:
  `gh api -X PATCH repos/digigrant/devenv/pulls/1 -F body=@file.md`.
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
  | `ec8f3b3` | this handoff |
  | `2fd9ec6` | Docker's layout: workspace `./dev` in the checkout, no devenv mount, devenv cloned into the sandbox at create, skills linked |

- **Tests:** `devenv test` passes after the restructure: status line
  byte-identity, shellcheck, `provision.sh --plain` twice in `ubuntu:24.04`
  and `ubuntu:26.04`, and the simulated sbx create (`tests/sbx-sim.sh`, which
  now clones devenv from a git copy of the working tree).
- **Host (owner, WSL2, sbx 0.45.1):** HOST-VERIFY steps 1–5 passed with the
  first layout; some V-checks were run too. The owner confirmed that the first
  mate saw no skills there although `sbx skills ls` listed them. The new
  layout needs HOST-VERIFY again from step 0 (remove the old `dev`, pull).
- `~/dev/firstmate` (the first layout's Firstmate home, still on the disk)
  had its `origin` set to `digigrant/firstmate` in session 2. The new layout
  doesn't use it.

## Decisions made after the original spec

All of these are now in SPEC.md; the "Spec said" column is the original.


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
| Layout (D2, D6, §4) | `~/devenv` beside the workspace `~/dev`; `workspace: ../dev`; devenv mounted read-only as an additional workspace | Docker's environment-file layout: `sbxenv.yaml` beside `workspace: ./dev`, a gitignored folder inside the checkout that `host-prepare` creates; the checkout itself is never mounted | Owner's decision, session 2. Docker's docs keep the environment file outside every mounted folder, and the read-only mount contained it. `doctor`/`host-prepare` allow only the checkout's own `dev/` as a workspace. New host rules: don't `cd` into `dev/` with a git-aware prompt or open it in an editor; never `git clean -x` in the checkout. |
| devenv inside the sandbox (§6.3, V7) | the read-only mount of the host checkout | a writable clone at `~/fm-projects/devenv`, made by the kit's install step (kit args `repo`, `ref`; default `main`; `sbx env run --kit-arg ref=<branch>` to test a branch). It is also Firstmate's project clone of devenv | Owner: one writable copy that the sandbox runs from and agents change (in worktrees, by PR). Firstmate's fleet sync fast-forwards it while it is a clean `main`. The host still runs only `~/devenv`. |
| Skills (D21, V4) | sbx's shared store, filled by `host-prepare` | linked into `~/.claude/skills` from the clone by `devenv start` and `provision.sh`; `sandboxOptions.skills: "off"`; the store sync (`skills-sync`, `DEVENV_SKILLS`) is gone | sbx mounts the store only for "a supported agent" (its built-ins); `dev` runs the custom kit `devenv`, so its first mate saw no skills. `claude-dev` (built-in `claude`) has the store with both skills. Following Docker's example fully (`agent: claude` + a mixin) would fix the store but a mixin can't set the entrypoint; the owner chose landing in herdr plus links (option C). v3 kits can declare the skills path (`agent-skills@1`), but the built-in claude is v2. |
| Projects (D1, `repos.txt`) | optional `repos.txt` cloned into the workspace | removed. A new sandbox clones nothing but devenv; the owner tells the first mate project names and URLs once, and Firstmate clones on demand into `~/fm-projects` | Owner, session 2. Firstmate's registry holds no URLs and drops entries whose clone is gone, so the names and URLs live in what the first mate remembers (its home persists). |
| Fallbacks removed | V5 `devenv up`, V7 `DEVENV_STAGE_PAYLOAD` | gone | Obsolete with the new layout. |
| Agents off `main` | owner sets branch rules by hand (D9) | `digigrant/devenv` has an active ruleset (PR with one approval, no force-push or deletion). Not enforced for the fork `digigrant/firstmate`: its ruleset stays disabled so the in-sandbox sync (as gej-machine) works | Owner, session 2: the owner has no `gh` login on the host and doesn't want one; not worth it for the fork. |
| Setup-token expiry | owner fills in `ANTHROPIC_TOKEN_EXPIRES` | left empty | Owner, session 2: tokens will move to a secrets manager soon. |

## Verification status

The host results below are from the first layout; HOST-VERIFY has to be
re-run with the new one.

| Item | Status |
|---|---|
| V1 | Resolved with the custom secret (probe passed on the host). Still to confirm in `dev` itself, including "still signed in after a second `sbx env run`" (the placeholder must stay stable). |
| V2 | Plan accepted `agent: devenv`; `extends: claude` resolved (claude template image, inherited credential). Detach/re-attach and herdr-server survival still to check on the host. In the sandbox, a second `devenv entry` re-attached with one `firstmate` workspace (AC3). |
| V3, V8, V9 | Done in the sandbox (see decisions). |
| V4 | Changed: skills are linked (see decisions). The sbx simulation checks the links; the host check is HOST-VERIFY V4 and AC7. |
| V5 | Relative paths resolved in the plan (first layout). The new layout's single mount is HOST-VERIFY V5. |
| V6, V10, V11, V12 | Host checks pending. In the sandbox: memory written by Claude lands in the state folder through the symlink; Firstmate's detect-only bootstrap reports nothing missing except the optional `PRESENTATION_UNAVAILABLE: lavish-axi`. |
| V7 | Replaced by the clone at create (HOST-VERIFY V7). The first layout's check passed on the host. |
| AC5, AC8, AC9, AC12, AC13–AC16 | Checked in the sandbox (AC13 on a simulated host, including the new "workspace inside the checkout" case). |

## Open work

### 1. Host verification of the new layout (owner)

HOST-VERIFY from step 0: `sbx env rm` the old `dev`, pull, then
`sbx env run --kit-arg ref=initial-setup`. Apply fixes per the owner's reports
and push them to PR #1. Things only the host can show:

- whether a later `sbx env run` without `--kit-arg` complains or wants a
  recreate (kit arguments apply at create);
- what sbx puts next to the workspace inside the sandbox
  (`/home/<you>/devenv`: the read-only `sbxenv.yaml`, sbx's `CLAUDE.md`);
- the kit's clone and provisioning in a real create (V7), and the skill links
  in the first mate and a worktree (V4, AC7);
- Firstmate registering the existing `~/fm-projects/devenv` clone when told
  about the project, rather than cloning it again.

### 2. Firstmate projects

Nothing to build. The owner tells the first mate about each project once (name,
URL, delivery mode; devenv: direct-PR). Firstmate's home survives rebuilds;
project clones don't, and it re-clones when a task needs one.

### 3. Smaller items

- The fork sync's fast-forward path hasn't run for real yet. The fork was 6
  commits behind upstream in session 2 (none touch workflows), so the next
  first-mate start will exercise it: look for
  `firstmate sync: fast-forwarded …` in `devenv check`.
- A sync whose upstream commits change `.github/workflows/` stalls with a
  `devenv check` warning: gej-machine's token has only `repo`. The owner then
  clicks Sync fork on GitHub (or grants `workflow`, which also lets agents run
  workflows from branches they push; undecided).
- Phase 5, after merge (owner): drop `--kit-arg ref=initial-setup`,
  `sbx rm claude-dev`, then, with confirmation, remove the first layout's and
  the old sandbox's leftovers in `/home/gejoy/dev`: `firstmate/`,
  `.devenv-state/`, and `.claude/settings.json` (project-level statusLine),
  `.claude/statusline-command.sh`, `.claude/skills/`.
- herdr switches to "working" about 3 s after a turn starts. That looks like
  herdr's own debounce; informational.
- Newer upstream versions exist but aren't adopted: herdr 0.9.1 (Firstmate
  has verified ≤ 0.8.0) and treehouse 3.0.0 (major bump). `devenv bump --list`
  shows them.

## Facts and traps learned

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
- The shared skills store is mounted only for sbx's built-in agents ("a
  supported agent"; `content/manuals/ai/sandboxes/workflows/agent-skills.md`),
  at `/home/agent/.claude/skills`, never into a workspace. v2 kits can't
  declare a skills path; v3 kits can (`agent-skills@1`), but the built-in
  agents are v2 and v2 and v3 kits don't mix.
- In `sbxenv.yaml`, quote `skills: "off"`: a bare `off` is a YAML 1.1 boolean.
- Kit arguments: `${{ kit.args.X }}` is substituted in `spec.yaml` before YAML
  decoding; pass values with `--kit-arg X=…` (`sbx env plan|run|create`).
- `sbx env run -d` creates/starts without attaching; `sbx env exec -it -- …`
  runs an interactive command in the environment's sandbox.
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

**git**
- git refuses a repository owned by another user ("dubious ownership"). The
  kit's install step runs as root on the agent's clone, so it passes
  `-c safe.directory=<dir>`; `tar` into a root-run test needs
  `--no-same-owner`.

**Firstmate**
- `bin/fm-fleet-sync.sh` fast-forwards a project clone's default branch when
  it is clean and on it, and reports any other state as `STUCK` without
  touching it. The project registry (`data/projects.md`) has no URLs, and a
  stale entry (no clone) is dropped.
- A first mate running outside herdr is supported with the herdr backend (its
  workers get the home's own herdr workspace); devenv doesn't use that.
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

- Clone to the sandbox disk (e.g. `~/src/devenv`), never under a workspace.
  Set the bot identity locally: `git config user.name gej-machine` and
  `user.email 318032932+gej-machine@users.noreply.github.com`.
- `./bin/devenv test` runs everything (~10 min; Docker in the sandbox; test
  containers use `--network host` and the proxy CA).
  `./bin/devenv test --no-containers` takes seconds.
- shellcheck: `. ./versions.env; docker run --rm -v "$PWD:/mnt:ro" -w /mnt "$TEST_SHELLCHECK_IMAGE" -x provision.sh bin/devenv bin/devenv-entry agents/claude/statusline.sh agents/claude/hooks/memory-link.sh tests/*.sh`
- To exercise sbx-mode provisioning in `claude-dev` without touching live
  files, point `HOME`, `WORKSPACE_DIR`, `DEVENV_ENV_FILE`,
  `DEVENV_SYSTEM_PREFIX` and `NPM_CONFIG_PREFIX` at scratch paths.
- To exercise host commands, use a scratch `HOME` with a copy of the checkout
  at `$HOME/devenv`, a fake `sbx` on `PATH` that logs its arguments, and
  `env -u IS_SANDBOX -u SANDBOX_NAME -u WORKSPACE_DIR` (otherwise they detect
  the sandbox). `DEVENV_EXTRA_WORKSPACES` simulates overlapping workspaces for
  the checkout-location check.
- Keep the PR description, README and HOST-VERIFY in step with the code.
