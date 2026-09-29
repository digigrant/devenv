# Handoff: devenv implementation

Written 2026-09-26 at the end of the first implementation session; updated
the same day in session 2, which restructured the sbx layer to Docker's
layout, on 2026-09-27 when the Infisical secrets manager was built
(branch `fm/devenv-devenv-infisical-secrets-manager-df`), and on 2026-09-28
when sbx became the only record of the Claude placeholder and the secret
refresh became configurable (branch
`fm/devenv-design-host-prepare-anthropic-secret-col-14`), and again on
2026-09-28 when Tailscale moved onto the host (branch
`fm/devenv-tailscale-host`) and for the opt-in Android emulator (branch
`fm/devenv-android-emulator`). Read this, then [SPEC.md](SPEC.md), [README.md](../README.md) and
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
  now clones devenv from a git copy of the working tree). The secrets build
  added `tests/secrets.sh` (fakes) and `tests/keyring.sh` (a real
  gnome-keyring in a container); both pass.
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
| Secrets (D7) | files readable only by the owner in `~/.config/devenv/secrets/`, read by `cat` commands; "a secrets manager later" | Infisical ([SECRETS.md](SECRETS.md)): the host logs in as the machine identity `sbx-host` with the login kept in the Secret Service keyring (`devenv secrets-init`); sbx runs `devenv secret-get NAME` (REST with `curl`) for the `github` secret and the Claude custom secret; host-prepare unlocks the keyring and checks both fetches | Owner's design, approved 2026-09-27. No secret in a plain-text file, on a command line or in the sandbox. |
| `secret-get` transport (SECRETS.md S6) | the Infisical CLI if probe P2 showed it writes nothing, else `curl` | `curl`, always | P2 has no result (the owner couldn't find the three values at the time). The REST path meets S6 whatever P2 shows; Firstmate's brief said to build it. |
| Keyring unlock (SECRETS.md §6.6) | `host-prepare` reads the keyring password on the TTY | the Secret Service's own pop-up window: a `secret-tool lookup` opens it and host-prepare waits up to 3 minutes; devenv never sees the password. No display: stop with instructions | P1: under WSLg both the new-keyring prompt and the unlock prompt are pop-up windows. The hook's timeout is 5 minutes. |
| Locked-keyring check (SECRETS.md §6.4) | "if the keyring is locked, fail with one line; never prompt" (mechanism open) | the Secret Service's `SearchItems` over D-Bus (`busctl --user`), per entry: unlocked, locked or missing | Checked against gnome-keyring 50 in a container with `dbus-monitor`: `secret-tool lookup` on a locked keyring calls `Unlock` and `Prompt` (the window); `secret-tool search` calls `GetSecret` on every entry; `SearchItems` alone loads nothing and never prompts. `tests/keyring.sh` keeps checking it. |
| Firstmate's own registration of devenv | entered by hand in each running instance's `data/projects.md` | seeded automatically: `firstmate/data/projects.md` in this repo, copied into `$FM_HOME/data/` by `provision.sh` step 8 whenever the destination file is absent, same contract as the existing `firstmate/config/` seeding | Without this, a fresh sandbox or a wiped Firstmate home came up with devenv unregistered again, requiring the same manual step every time. |
| Claude placeholder and secret refresh | a random placeholder kept on the host (`~/.config/devenv/claude-oauth-placeholder`); `set-custom` "create-or-update"; sbx's refresh default | sbx is the only record of the placeholder: host-prepare reads it back with `sbx secret ls --sandbox dev --json`, reuses it, and makes one only when sbx has none; the host file is deleted. `CLAUDE_AUTH=login` removes the secret with `--sandbox dev --host … --env …`. `SECRET_REFRESH` (default `55m`) with per-secret `SECRET_REFRESH_CLAUDE` / `SECRET_REFRESH_GITHUB`, validated like sbx's `--refresh`. The GitHub secret moved out of `sbxenv.yaml`: host-prepare sets it (`sbx secret set github --sandbox dev --command … --refresh …`) and `sbxenv.yaml` keeps only `bindings.github` | sbx refuses a second placeholder for the same env var in a scope, so a host file that no longer matched sbx broke `sbx env run` (the owner hit it); login mode's `rm` lacked `--sandbox` and removed nothing; the custom secret's default refresh is `on-demand`, not the 55 minutes SECRETS.md S7 intended; `sbxenv.yaml` expands only `${{ env.* }}` references, so it can't take the refresh from `devenv.conf` (the owner chose moving the GitHub secret to host-prepare over a second copy of the setting). Owner's decisions, 2026-09-28. |
| Tailscale (D33, §6.14) | not in devenv; Tailscale ran on Windows | Tailscale runs in Linux on every host (the WSL 2 distro, or a Linux PC), off Windows. `devenv tailscale-setup` (host, interactive) adds Tailscale's apt repository as Tailscale documents, installs `tailscale` and `tailscale-archive-keyring`, enables tailscaled and, when needed, runs `sudo tailscale up` for the one browser sign-in; host `doctor` checks it all, including systemd in WSL and Tailscale on Windows. No auth key; nothing stored. `host-prepare` ignores Tailscale | Owner's decision, 2026-09-28 (option B), for the Magic Conch hub. Tailscale's WSL page says Tailscale on Windows and in WSL at once breaks WSL's Tailscale traffic, so the owner accepted uninstalling it on Windows. Install and sign-in are a new interactive command rather than part of `host-prepare`: the lifecycle hook can't answer sudo's password prompt or wait on a browser, and a sandbox mustn't depend on Tailscale. |
| GitHub CLI (§6.3 step 1) | Ubuntu's `gh` from apt in plain mode; the sandbox image's own (Ubuntu's 2.46) in sbx mode | GitHub's current release from GitHub's own apt repository (`cli.github.com`), set up as GitHub documents (keyring in `/etc/apt/keyrings`, a `signed-by` source), in both modes and unpinned; it replaces the image's Ubuntu `gh` at every create | Ubuntu's 2.46 rejects `gh api --slurp` ("unknown flag"), which Firstmate's PR comment and review monitor uses, so the monitor failed on every PR. Owner's decision, 2026-09-28. |
| Android emulator (D34, §6.15) | not in the spec | opt-in, one per host: `devenv emulator start\|stop\|status\|clean` runs a headless emulator in a Docker Engine container with `/dev/kvm`, adb published on the host's `127.0.0.1:15555`; sandboxes use it through one global rule the owner adds once (`sbx policy allow network localhost:15555`) with `devenv emulator connect\|run`; `adb` (Google's platform-tools, pinned) in every sandbox. devenv's own small image following Google's recipe, the SDK (5.1 GB) in a Docker volume, all from Google's zips pinned by sha256 | The owner wants workers to run emulator tests without leaving the sandbox (2026-09-28), and accepted the recommendation of an emulator on each Linux host reached through one firewall rule. The sandbox has no KVM and sbx's nested virtualization is macOS-only. See "Android emulator" below for the image choice. |

## Verification status

The host results below are from the first layout; HOST-VERIFY has to be
re-run with the new one.

| Item | Status |
|---|---|
| V1 | Resolved with the custom secret (probe passed on the host). Still to confirm in `dev` itself, including "still signed in after a second `sbx env run`" (the placeholder must stay stable; host-prepare now reuses the one sbx holds, HOST-VERIFY §8.3). **Reopened 2026-09-29:** after a rebuild the first mate said "Not logged in": sbx's `claude` kit seeded a stored login, and Claude's daemon then drops the token. `devenv start`/`entry` now move it aside and doctor checks it; the old V1 check also passed while the host's global `anthropic` OAuth masked the setup-token, so it now includes an unauthenticated-request probe (expect 401). Removing that global secret is the owner's host action. |
| V2 | Plan accepted `agent: devenv`; `extends: claude` resolved (claude template image, inherited credential). Detach/re-attach and herdr-server survival still to check on the host. In the sandbox, a second `devenv entry` re-attached with one `firstmate` workspace (AC3). |
| V3, V8, V9 | Done in the sandbox (see decisions). |
| V4 | Changed: skills are linked (see decisions). The sbx simulation checks the links; the host check is HOST-VERIFY V4 and AC7. |
| V5 | Relative paths resolved in the plan (first layout). The new layout's single mount is HOST-VERIFY V5. |
| V6, V10, V11, V12 | Host checks pending. In the sandbox: memory written by Claude lands in the state folder through the symlink; Firstmate's detect-only bootstrap reports nothing missing except the optional `PRESENTATION_UNAVAILABLE: lavish-axi`. |
| V7 | Replaced by the clone at create (HOST-VERIFY V7). The first layout's check passed on the host. |
| AC5, AC8, AC9, AC12, AC13–AC16 | Checked in the sandbox (AC13 on a simulated host, including the new "workspace inside the checkout" case). |
| V14, AC18 (Android emulator) | In the sandbox: raw TCP through the proxy, the real image and SDK volume (`tests/emulator-image.sh`), the command against fakes (`tests/emulator.sh`), and the live policy diagnosis. Everything on a host is pending: HOST-VERIFY §11. |

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

devenv's own registration is no longer manual: `firstmate/data/projects.md`
seeds `$FM_HOME/data/projects.md` on any fresh Firstmate home, the same way
`firstmate/config/` seeds `$FM_HOME/config/` (see decisions table). For every
other project, the owner still tells the first mate about it once (name, URL,
delivery mode). Firstmate's home survives rebuilds; project clones don't, and
it re-clones when a task needs one.

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

### 4. Tailscale on the hosts (owner)

HOST-VERIFY §10 on the Windows PC (uninstall Tailscale on Windows first) and
on the Linux laptop, then the admin console's DNS page once (MagicDNS, Enable
HTTPS). Only the fakes in `tests/tailscale.sh` have run: `pkgs.tailscale.com`
is blocked in the sandbox. Things only the host can show:

- the real `sc.exe query Tailscale` output through WSL's interop, which
  doctor parses;
- that Tailscale's `<codename>.tailscale-keyring.list` matches devenv's copy
  of it byte for byte (a machine set up by Tailscale's own installer then
  says "already installed");
- that tailscaled keeps working in WSL (the MTU fix is tailscaled's own), and
  a `tailscale ping` from WSL to the phone.

Later, with the Magic Conch hub: keeping the WSL distro running (WSL stops an
idle distro, and tailscaled with it), `tailscale serve`, and perhaps
`tailscale set --operator` so the hub needn't run as root.

### 5. Secrets manager (Infisical)

Designed with the owner on 2026-09-27 and built the same day on branch
`fm/devenv-devenv-infisical-secrets-manager-df`, PR
https://github.com/digigrant/devenv/pull/5 ([SECRETS.md](SECRETS.md) has
**As built** notes where the build differs from the design). Probes: P1 and P3
passed; P2 has no result and no longer decides anything (`secret-get` uses
`curl`). Next, on the host: HOST-VERIFY §8.3 (try the build), §8.4 (cleanup,
A2, A3, A6) and §8.5 (restart, A4). Things only the host can show:

- whether sbx expanded `${{ env.fileDir }}` in the `github` command
  (HOST-VERIFY §8.3 step 6; fallback `"$HOME/devenv/bin/devenv"`);
- that the unlock pop-up opens from the lifecycle hook, and that
  `secret-get` run by sandboxd fails at once, without a window, while the
  keyring is locked (§8.3 step 8, §8.5);
- the real setup-token's length, for the docs' `<n> chars`.

Out of scope, unchanged: typesafe wiring (S10), SECRETS.md §11's exclusions
and §12's later items. A host with no display can't show the unlock window;
host-prepare stops with instructions (no such host today).

### 6. Android emulator

Built on 2026-09-28 (branch `fm/devenv-android-emulator`); nothing has run on
a host yet. HOST-VERIFY §11, on both hosts, answers what only a host can
show: that Android boots in the container (under WSL2 that needs nested
virtualization for Docker's containers, as it already does for sbx), how much
memory and time it takes, that the sandbox's adb reaches it through
`host.docker.internal` once the rule is added, and that a test runs. Also to
confirm there: whether the emulator is happy with its SDK in a volume it can
write (it is mounted read-write), and `sbx policy check`'s real output (devenv
reads `Allowed…`/`Denied…` from its first line).

Choosing the emulator image (the brief asked for an evaluation):

| Option | License | Maintenance | Headless fit | Verdict |
|---|---|---|---|---|
| google/android-emulator-container-scripts | Apache-2.0 | Google's emulator team; commits in July 2026 | built for it: `-no-window`, adb on 5555, gRPC | the recipe devenv follows. Its hosted images stop at API 30 with a 2020 emulator; newer ones need its Python tool (`emu-docker`), which downloads unpinned and adds WebRTC and PulseAudio |
| budtmo/docker-android | Apache-2.0 **with amendments**: using it agrees to usage data collection (city, region, country via ipinfo.io, and more) | very active (releases every few weeks) | built around noVNC, Appium, video recording and a web UI | not used: the data collection, and far more than a test device needs |
| HQarroum/docker-android | MIT | one maintainer; last change May 2026 | headless, but the image carries Xvfb, x11vnc and virt-manager | not used: installs the SDK unpinned with `sdkmanager`, sporadic upkeep |

devenv's image is about 40 lines (`android/emulator/`): Ubuntu pinned by
digest, the emulator's runtime libraries, and `launch.sh`, which writes the
AVD and starts the emulator the way Google's launch script does. The
emulator, system image and platform-tools come from Google's own repository,
pinned by sha256 in `versions.env` and moved with `devenv bump`, like every
other download.

Possible next steps, not built: a JDK and SDK packages in the sandbox for
building apps (today only `adb`); more than one emulator (API levels,
parallel runs); a lighter device (the API 36 image needs 4 GB of guest RAM).

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
  --placeholder … --command …`. A scope holds one custom secret per env var,
  keyed by its placeholder: the same placeholder updates it, a different one
  fails with `custom secret env "…" already exists in scope "dev" with
  placeholder "…"` (checked against sbx 0.45.1 with a throwaway store). That
  is the error the owner hit when the old host placeholder file and sbx
  disagreed; since then sbx is the only record and host-prepare reads the
  placeholder back (`sbx secret ls --sandbox dev --json`). Remove one with
  `sbx secret rm --sandbox dev --host … --env … -f`; without `--sandbox`, rm
  looks only at global secrets and still exits 0. `sbxenv.yaml` can't declare
  them. Command sources run from a temp directory on the host, so they need
  absolute paths.
- `--refresh`: a custom secret's default is `on-demand` (resolve on every
  use), a service secret's is `55m`. It takes `on-demand` or a Go duration;
  `SECRET_REFRESH*` in `devenv.conf` sets it (validated the same way).
- `sbxenv.yaml` expands only `${{ env.fileDir }}`, `${{ env.projectDir }}` and
  `${{ env.args.NAME }}` (from `args:` defaults, `--env-arg` or
  `--env-args-file`); host environment variables aren't expanded, and argument
  values aren't passed to lifecycle commands.
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

**sbx networking (0.45.1; checked in a sandbox on 2026-09-28)**
- Every outbound TCP connection goes through the host-side proxy: HTTP(S)
  clients through the forward proxy (`HTTP_PROXY`), everything else
  transparently. The transparent proxy accepts the connection at once and
  applies the policy afterwards, so a blocked or dead destination looks like a
  connection that opens and then closes, never a refused connect. Probe with a
  protocol message and wait for an answer: devenv's `adb_hello` sends adb's
  `CNXN`.
- Non-HTTP TCP to an allowed host works: SSH to `ssh.github.com:443` (allowed
  by `balanced`) returns the server's banner; `github.com:22` (not allowed) is
  closed.
- `host.docker.internal` is 169.254.1.1 (and fe80::1) in the sandbox. The
  policy resource for it is `localhost:<port>`: the forward proxy answers a
  blocked one with `403 Blocked by network policy: domain localhost:<port>`.
  Raw TCP to it follows a `localhost:<port>` rule since sbx 0.30
  (docker/sbx-releases#211); a server that speaks first works since 0.40
  (#411). `sbx policy check` matches the literal name, so check
  `localhost:<port>`, not `host.docker.internal:<port>` (#546).
- `adb connect` to a destination the proxy closes waits 10 seconds, prints
  `failed to connect to …` with exit status 0, and leaves an `offline` entry
  in `adb devices`: `devenv emulator connect` probes first and disconnects
  stale entries.
- The sandbox's own Docker has a 10 GB disk. BuildKit keeps a build's context
  in its cache (a 2 GB context stayed after `docker builder prune -af`), which
  is one reason the emulator's SDK is a volume and not part of the image. When
  that disk fills, BuildKit can't even prune (its metadata can't be written):
  truncating a file in a cache-only snapshot freed enough to prune.

**Android emulator (37.1.11, API 36 google_apis x86_64)**
- It raises the guest RAM to 4096 MB whatever `hw.ramSize` or the screen
  says, and checks for free disk space where the AVD lives before starting
  (about 1.4 GB free was too little).
- `emulator -accel-check` exits 0 even without KVM; its second line is the
  status (0 means usable), the third the message.
- The emulator's adb port listens on loopback only, hence socat in the
  container. adb's scan for local emulators covers ports 5555 to 5585, so the
  forward listens on 6555, or the container's own adb server finds the
  emulator twice.
- Google's SDK repository index (`repository2-3.xml`,
  `sys-img/<tag>/sys-img2-3.xml`) gives SHA-1s only; the archive names encode
  the emulator's build number and the image's revision.
- `adb --version` prints the protocol version (1.0.41) before the release
  (`Version 37.0.1-…`).

**Secrets (Infisical, gnome-keyring)**
- Infisical Universal Auth: the Client ID is in the Universal Auth section of
  the identity's page; the Identity ID (Options, Copy Machine Identity ID) is
  a different value. **Add Client Secret** shows the secret once. Lockout
  defaults: 3 failures, 5 minutes, counter reset 30 seconds after the last
  failure; **Reset All Lockouts** ends one. The project ID is under Project
  Settings, **Copy Project ID**.
- The v4 single-secret read is `GET /api/v4/secrets/{name}?projectId=…&environment=…&secretPath=…`;
  the value is `.secret.secretValue`.
- `secret-tool store` reads the value from stdin when stdin isn't a
  terminal. `secret-tool` prints `search` attributes on stderr and secrets on
  stdout. With no default keyring, the first store makes gnome-keyring prompt
  for a new keyring password (a window).
- gnome-keyring matches attributes on a locked collection: `SearchItems`
  returns the entries in its second ("locked") array. `Lock` over D-Bus needs
  no prompt. Without a display, the prompter (`gcr-prompter`) exits at once
  and a lookup on a locked keyring fails immediately rather than hanging.
- `busctl --user` honours `DBUS_SESSION_BUS_ADDRESS` (and otherwise uses
  `$XDG_RUNTIME_DIR/bus`); `--json=short` makes its output easy to parse with
  jq.
- To watch for prompts in a test, run `dbus-monitor --session
  "type='method_call',destination='org.freedesktop.secrets'"` and look for
  `Unlock` and `Prompt`. `script -E never -qefc CMD /dev/null` gives a command
  a pseudo-terminal for `read -s` prompts fed from a pipe.
- Never handle a real secret, not even in a test: the tests use dummy values
  and assert that none appears in a command's arguments or output
  (`tests/secrets.sh`).

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
- shellcheck: `. ./versions.env; docker run --rm -v "$PWD:/mnt:ro" -w /mnt "$TEST_SHELLCHECK_IMAGE" -x provision.sh bin/devenv bin/devenv-entry agents/claude/statusline.sh agents/claude/hooks/memory-link.sh tests/*.sh tests/fakes/*`
- Host secrets code: `tests/secrets.sh` runs it against fakes in seconds;
  `tests/keyring.sh` runs it against a real gnome-keyring in a container
  (about a minute). Neither touches a real keyring, Infisical or sbx.
- To exercise sbx-mode provisioning in `claude-dev` without touching live
  files, point `HOME`, `WORKSPACE_DIR`, `DEVENV_ENV_FILE`,
  `DEVENV_SYSTEM_PREFIX` and `NPM_CONFIG_PREFIX` at scratch paths. Step 1
  still uses the live apt: it installs missing packages, and it replaces a
  `gh` that isn't GitHub's current release from `cli.github.com`. Test apt
  changes in a container (`tests/sbx-sim.sh`) instead.
- To exercise host commands, use a scratch `HOME` with a copy of the checkout
  at `$HOME/devenv`, a fake `sbx` on `PATH` that logs its arguments, and
  `env -u IS_SANDBOX -u SANDBOX_NAME -u WORKSPACE_DIR` (otherwise they detect
  the sandbox). `DEVENV_EXTRA_WORKSPACES` simulates overlapping workspaces for
  the checkout-location check.
- Keep the PR description, README and HOST-VERIFY in step with the code.
