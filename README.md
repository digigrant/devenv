# devenv

Rebuilds the agent dev environment in one command: a Docker Sandbox (`sbx`)
named `dev` that runs [Firstmate](https://github.com/digigrant/firstmate)
(the owner's fork of [kunchenguid/firstmate](https://github.com/kunchenguid/firstmate))
on the [herdr](https://github.com/herdrdev/herdr) backend, with Claude Code as
the agent. Every tool is pinned and checksum-verified, and the Claude
settings are reapplied on each start, including the owner's status line,
copied byte-for-byte. A portable layer (`provision.sh --plain`) sets up the
same tools on a plain Debian/Ubuntu machine without `sbx`.

```sh
cd ~/devenv && sbx env run
```

The design and every decision behind it are in [docs/SPEC.md](docs/SPEC.md);
status, open work, and why things changed from the original spec are in
[docs/HANDOFF.md](docs/HANDOFF.md). The host-side verification checklist is
[docs/HOST-VERIFY.md](docs/HOST-VERIFY.md).

## Layout

devenv follows Docker's layout for
[environment files](https://docs.docker.com/ai/sandboxes/configuration/environment-files/):
`sbxenv.yaml` sits beside the workspace, and the folder that holds it is never
mounted into the sandbox.

```
host                                  sandbox "dev"
~/devenv/          this repo          (not mounted)
├── sbxenv.yaml
├── kits/devenv/   the sandbox kit
└── dev/           the workspace ───► ~/devenv/dev, read-write
    ├── firstmate/       Firstmate's home
    └── .devenv-state/   Claude memory
                                      ~/fm-projects/devenv   devenv, cloned at create
```

- **`dev/`** is the only folder the sandbox shares with the host. It holds what
  survives a rebuild. It is gitignored and belongs to the sandbox (see
  [Operating rules](#operating-rules)).
- **Inside the sandbox, devenv is a writable clone** of this repo at
  `~/fm-projects/devenv`, made by the kit when the sandbox is created (branch
  `main`, or the `ref` kit argument). The sandbox runs devenv from that clone
  (`$DEVENV_DIR`: status line, `devenv start`, `devenv entry`), and it is also
  Firstmate's project clone of devenv, so agents can change devenv and open
  PRs. Firstmate keeps it fast-forwarded to `main` while it is clean.
- The host runs devenv only from `~/devenv` (`devenv host-prepare`, the secret
  commands, `devenv doctor`), so nothing the sandbox does changes code that
  runs on the host.

## Quick start (host)

1. Meet the [host prerequisites](#host-prerequisites).
2. Clone devenv (outside every sandbox workspace, e.g. not inside `~/dev`):
   ```sh
   git clone https://github.com/digigrant/devenv ~/devenv
   ```
3. Put the secrets in files only you can read:
   ```sh
   install -d -m 700 ~/.config/devenv/secrets
   (umask 077; cat > ~/.config/devenv/secrets/anthropic)   # `claude setup-token` token (sk-ant-oat01-…), then Ctrl-D
   (umask 077; cat > ~/.config/devenv/secrets/github)      # the gej-machine token, then Ctrl-D
   ```
   Put the setup-token's expiry date in `ANTHROPIC_TOKEN_EXPIRES` in
   `devenv.conf` (by PR), so `devenv check` can warn before it runs out.
4. Check the host: `~/devenv/bin/devenv doctor`
5. Build and enter the sandbox: `cd ~/devenv && sbx env run`

You land in herdr, in a workspace named `firstmate`, where the first mate
(Claude at `xhigh` effort) runs in `~/devenv/dev/firstmate`. No `/login` is
needed: see [Claude sign-in](#claude-sign-in). Detach with `ctrl+b q`;
panes keep running. Run `sbx env run` again to re-attach.

`sbx env run` shows a plan and asks for approval (`-y` skips the prompt). With
no path argument it also merges `~/.sbxenv.yaml` if you have one; use
`sbx env run .` to skip that file.

To build the sandbox from a devenv branch instead of `main` (for example to
try a PR before merging it), pass the kit argument when the sandbox is
created: `sbx env run --kit-arg ref=<branch>`. Check out the same branch in
`~/devenv`, since the host side runs from there.

## Host prerequisites

Linux `sbx` on WSL2 or native Linux (Ubuntu 24.04+ with KVM; nested
virtualization when the host is itself a VM). The Windows `sbx.exe` is not
supported. Install once:

```sh
curl -fsSL https://get.docker.com | sudo REPO_ONLY=1 sh
sudo apt install docker-sbx
sudo usermod -aG kvm $USER        # then log out and in again
sbx login                         # a Docker account is required
sbx policy init balanced
```

devenv's host commands also use `bash`, `git` and `jq`.

On WSL, Docker supports the Linux `sbx` only "best-effort"
(docker/sbx-releases#397); `devenv doctor` says so. The owner chose it so WSL
and native Linux behave the same.

## Operating rules

- **Treat `~/devenv/dev` as belonging to the sandbox.** Never run `git`,
  scripts or build tools in it from the host, don't `cd` into it with a
  git-aware shell prompt, and don't open it in an editor: agents can plant git
  hooks, git config or scripts there, and prompts and editors run `git` in the
  repositories they find. (`devenv doctor` prints this rule.)
- **Never run `git clean -x` (or `-X`) in `~/devenv`**: `dev/` is gitignored,
  so it would delete the workspace, including Firstmate's home and Claude's
  memory. `git clean` without `-x` leaves it alone.
- **devenv changes arrive only by PR.** Agents (as `gej-machine`) change
  devenv in a worktree of the sandbox's clone and open a PR; the owner merges,
  then runs `git -C ~/devenv pull`. Everything that runs on the host (the
  lifecycle hook, the secret commands, `bin/devenv` host commands, kit network
  rules) therefore comes only from reviewed code.
- Only the checkout's own `dev/` may be a sandbox workspace: the checkout must
  never be inside a folder a sandbox can write, and no other workspace may be
  inside it. `devenv doctor` and `devenv host-prepare` refuse to continue
  otherwise.
- Secrets never go in the repo. The `github` secret is the `gej-machine`
  token only, never a personal token.
- Never allow `herdr.dev`: herdr is pinned, and its update and manifest
  checks are off.
- Merges follow Firstmate's rule: never without the owner's explicit word.
  `yolo` stays off.

## Claude sign-in

With `CLAUDE_AUTH=token` (the default, in `devenv.conf`), Claude, the first
mate and every worker run on your Claude subscription through the long-lived
`claude setup-token` token:

- `devenv host-prepare` stores it in sbx as a **custom secret** for sandbox
  `dev` (`sbxenv.yaml` can't declare custom secrets). Inside the sandbox
  `CLAUDE_CODE_OAUTH_TOKEN` holds only a placeholder; the proxy swaps in the
  real token on requests to `api.anthropic.com`. The placeholder is random and
  kept on the host in `~/.config/devenv/claude-oauth-placeholder`.
- Firstmate needs no changes: workers inherit the variable, and `quota-axi`
  reads your subscription's usage windows with it.
- The token is inference-only by design: claude.ai connectors, Remote Control,
  Claude in Chrome and plugin sync don't work with it. Nothing in devenv or
  Firstmate uses them.
- Don't store the token with `sbx secret set anthropic` (or in `sbxenv.yaml`
  `secrets:`): sbx then treats it as a Console API key
  (`SBX_CRED_ANTHROPIC_MODE=apikey`), which outranks the subscription and is
  rejected with HTTP 401.

`CLAUDE_AUTH=login` instead uses no Claude secret: run `/login` once after
each rebuild (a full-scope login that survives `sbx stop`). Switching modes
takes a recreate.

## Choosing what the sandbox opens

`env.DEVENV_ENTRY` in `sbxenv.yaml`:

| Value | Opens |
|---|---|
| `herdr` (default) | herdr with the `firstmate` workspace, creating it (and starting the first mate) only if it doesn't exist |
| `claude` | plain Claude in the workspace (`~/devenv/dev`) |
| `shell` | a login shell |

Edit it and run `sbx env run` again; no recreate is needed.

## What persists

| Thing | Where | Survives `sbx rm`? |
|---|---|---|
| devenv (host) | `~/devenv`, never mounted | yes |
| devenv (sandbox) | `~/fm-projects/devenv`, cloned at create | no: cloned again at the next create |
| Secrets | host `~/.config/devenv/secrets/` (0600) | yes |
| Firstmate home (clone, `config/`, `data/`, `state/`) | `~/devenv/dev/firstmate` | yes |
| Claude memory | `~/devenv/dev/.devenv-state/claude-memory/<project>/`, linked from `~/.claude/projects/<project>/memory` | yes |
| Firstmate project clones | `~/fm-projects` (sandbox disk) | no: push your work |
| treehouse worktrees | `~/.treehouse` (sandbox disk) | no |
| herdr sessions, Claude transcripts | sandbox | no |

## Projects

A new sandbox clones no projects apart from devenv itself. Tell the first mate
about the projects you work on, once, with their GitHub URLs and how changes
should ship (for example: *"devenv is https://github.com/digigrant/devenv,
direct-PR"*). Firstmate keeps that in its home, which survives rebuilds, and
clones a project into `~/fm-projects` when a task needs it. Its workers work
in treehouse worktrees on branches and deliver by PR; merges wait for your
word.

devenv is already cloned at `~/fm-projects/devenv`, so Firstmate picks it up
as a project; tell it the delivery mode the first time.

## Skills

devenv's skills (`skills/`: `grill-me`, `grilling`) are linked into
`~/.claude/skills` from the devenv clone by `devenv start`, so every Claude
session sees them: the first mate, and workers in `~/.treehouse` worktrees.
sbx's shared skills store is off for this sandbox (`sandboxOptions.skills`):
sbx mounts it only for its built-in agents, not for a custom kit like
devenv's.

## Commands

`bin/devenv` (on `PATH` inside the sandbox):

| Command | Where | What |
|---|---|---|
| `devenv doctor` | host, sandbox, plain | Full health report. On the host: sbx, KVM, policy, secret files, checkout location, operating rule. Inside: pinned tools, GitHub identity, Claude login, herdr, Firstmate bootstrap, settings, skill links. |
| `devenv check [--quiet]` | sandbox, plain | Staleness warnings: Firstmate off your fork's `main` or a failed automatic update, uncommitted changes in the devenv clone the sandbox runs from, tool versions, GitHub token expiry (via the API), `ANTHROPIC_TOKEN_EXPIRES` (if set), Firstmate config drift, herdr detection override. Shown at entry and as `⚠ devenv:N` in Claude's status line. |
| `devenv bump …` | a writable clone | Update `versions.env`: `herdr <v>`, `herdr-manifest <commit\|latest>`, `treehouse\|no-mistakes <v\|latest>`, `npm <pkg> <v\|latest>`, `node <v\|latest-lts>`, `--list`. Prints the diff; never commits. |
| `devenv test` | sandbox or any Docker host | Status line byte-identity, shellcheck, `provision.sh --plain` in `ubuntu:24.04` and `ubuntu:26.04` containers (twice, to prove it's idempotent), and a simulated sbx create that runs the kit's own install and startup steps. |
| `devenv start` | sandbox | Run by the kit at every start: reapply Claude settings, status line, `CLAUDE.md`, herdr config, skill and memory links, warnings. |
| `devenv entry` | sandbox | The entrypoint (via `devenv-entry`). |
| `devenv host-prepare` | host | The `lifecycle.initialize` hook: checks secrets and the checkout location, creates `dev/`, sets up the Claude sign-in. |

### Updating versions

Pins live in `versions.env`, one tool per block, with a sha256 for every
download. To move one, bump it on a branch and open a PR. In the sandbox, use
a worktree of the devenv clone rather than the clone itself, which the sandbox
runs from:

```sh
git -C ~/fm-projects/devenv worktree add ~/devenv-bump -b bump-herdr
devenv bump --repo ~/devenv-bump --list
devenv bump --repo ~/devenv-bump herdr 0.9.1   # warns loudly: Firstmate has not verified 0.9.1
```

Claude Code and Firstmate are not pinned: Claude Code updates itself, and
Firstmate updates automatically (next section).

## Firstmate updates

Firstmate comes from the owner's fork, `digigrant/firstmate`
(`FIRSTMATE_REPO`), which follows `kunchenguid/firstmate`
(`FIRSTMATE_UPSTREAM`). Fresh setups clone the fork's `main`. Then, every time
`devenv entry` starts a first mate (a sandbox start or rebuild with
`DEVENV_ENTRY=herdr`; never under a running first mate):

1. **Fork sync.** When the fork's `main` is strictly behind upstream, GitHub's
   Sync fork fast-forwards it, as gej-machine. If the fork has commits of its
   own, the sync stops and `devenv check` warns; it never merges.
2. **Local update.** Firstmate's own `bin/fm-update.sh` fast-forwards
   `~/devenv/dev/firstmate` (and any secondmates) to the fork's `main`. A dirty or
   diverged clone is skipped, and `devenv check` warns.

Both results print at entry and show as notes in `devenv check`; a failure
is a warning, so it also appears in Claude's status line. During a long
session, `/updatefirstmate` in the first mate updates it on demand. Set
`FIRSTMATE_AUTO_UPDATE=off` in `devenv.conf` to pause both steps.

Upstream changes arrive unreviewed, including Firstmate's own rules in its
`AGENTS.md`. The sync needs:

- nothing on the fork's `main` that stops gej-machine from updating it (a
  ruleset that requires pull requests does, with HTTP 422);
- the `workflow` scope on the gej-machine token when the new upstream commits
  change `.github/workflows/` (otherwise the sync fails with a warning until
  you add the scope or click Sync fork on GitHub).

## Plain mode (no sbx)

On any Debian/Ubuntu machine:

```sh
git clone https://github.com/digigrant/devenv ~/devenv
~/devenv/provision.sh --plain            # add --yes to skip the apt prompt
```

It installs the same pinned tools into `~/.local`, installs Node
`NODE_VERSION` if node is missing or older than `NODE_MIN_VERSION`, installs
Claude Code with its official installer if missing (the one documented
exception to checksum pinning), clones Firstmate to `~/dev/firstmate`, links
the skills into `~/.claude/skills`, and writes `~/.config/devenv/env.sh`,
sourced from `~/.bashrc`. Git identity is left alone unless you pass
`--git-identity bot`. In plain mode devenv runs from the checkout itself, and
the workspace is `~/dev` (`PLAIN_WORKSPACE_DIR`).

## Layout

```
sbxenv.yaml            sbx layer: kit, workspace, env, secrets, lifecycle
kits/devenv/           v2 sandbox kit (extends claude; clones devenv; entrypoint devenv-entry)
dev/                   the sandbox workspace (gitignored; created by host-prepare)
provision.sh           portable installer: --sbx | --plain
devenv.conf            non-secret settings
versions.env           every pin and sha256
bin/                   devenv CLI and the entrypoint shim
lib/                   shared shell code; lib/cmd/ has one file per subcommand
agents/claude/         everything Claude-specific (status line, overlay, CLAUDE.md, hooks)
firstmate/config/      starting copy of Firstmate's config
herdr/                 herdr config, and its Claude detection rules (see below)
skills/                grill-me and grilling, verbatim
tests/                 container smoke test, sbx simulation, status line identity test, fixtures
```

### herdr's Claude detection rules

herdr works out whether an agent is working, idle or blocked from its screen
and window title, using a rules file per agent. The rules bundled in herdr
0.8.0 predate Claude Code 2.1.228's new title spinner, so herdr never saw
Claude as "working". herdr normally downloads fixed rules from `herdr.dev`,
which devenv blocks. Instead, `herdr/agent-detection/claude.toml` is herdr's
own published file (upstream commit in `versions.env`, sha256-checked),
installed as a local override at `~/.config/herdr/agent-detection/claude.toml`.
`devenv bump herdr-manifest latest` refreshes it, and `devenv check` warns
when herdr is bumped past the version it was tested with.

## Troubleshooting

- **Nothing happens in bash / all commands print nothing inside the sandbox.**
  Something added a shell-completion script to `/etc/sandbox-persistent.sh`.
  Remove it; devenv never does.
- **Claude asks to `/login` or gets HTTP 401.** Run `devenv doctor` inside the
  sandbox. `CLAUDE_CODE_OAUTH_TOKEN is not set` means the custom secret didn't
  reach it: check the `devenv host-prepare` output of `sbx env run`, then
  recreate. `SBX_CRED_ANTHROPIC_MODE=apikey` means a stored `anthropic`
  secret outranks the token: remove it (`sbx secret ls`) and recreate. A
  401 with the variable set means the setup-token expired or was revoked: make
  a new one with `claude setup-token` on the host.
- **The sandbox opens Claude instead of herdr.** The kit's entrypoint wasn't
  used (V2). Run `devenv entry` by hand, or use the mixin fallback described in
  `kits/devenv/spec.yaml`.
- **Skills are missing.** Run `devenv doctor` in the sandbox: its "Claude
  settings" part names any skill that isn't linked. `devenv start` links them
  from `$DEVENV_DIR/skills`; start a new Claude session afterwards.
- **The create fails with `failed to apply kit to sandbox`.** The kit's
  install step (the devenv clone, then `provision.sh`) failed; the reason is
  in sbx's daemon log (see docs/HOST-VERIFY.md, step 5). A `--kit-arg ref=`
  that names no branch on GitHub is one cause. Clean up with `sbx env rm`
  before retrying.
- **A download is blocked (HTTP 403).** Add only that host to
  `permissions.network.allow` in `kits/devenv/spec.yaml` (by PR), then
  recreate. Never `herdr.dev`.
- **Effort isn't `high` in new sessions.** The default is written per model
  (`CLAUDE_EFFORT_MODELS` in `devenv.conf`), because Claude Code ignores a
  model-independent effort in user settings. Add the new model's id there when
  the default model changes; `devenv doctor` flags a mismatch.
- **herdr shows agents as idle while they work.** Check
  `devenv doctor` → "herdr Claude detection". It should say `local override`.
- **`devenv check` warns that the devenv clone has uncommitted changes.** The
  sandbox runs from `~/fm-projects/devenv`, so changes there take effect at
  once. Move them to a branch (`git -C ~/fm-projects/devenv stash`, then work
  in a worktree) or discard them.
- Logs: `~/.cache/devenv/start.log`, `/var/log/sbx-kit-startup.log`,
  `~/.cache/devenv/herdr-server.log`.

## Roadmap (not built yet)

- A secrets manager for the setup-token and the GitHub token: swap the
  `command:` lines in `sbxenv.yaml` for `ref: op://…` (and `host-prepare`'s
  custom-secret command).
- A GitHub permission system for agents: rulesets or a bot bypass list, or a
  GitHub App with short-lived tokens through `secrets.github.command` plus
  `refresh`.
- Worker effort and model profiles in Firstmate's `config/crew-dispatch.json`.
- A second worker harness (e.g. Codex): `config/crew-harness` plus its install.
- Bumping herdr past 0.8.0 once Firstmate verifies newer versions.
- v3 kits, once a v3 Claude workload is available to build on: a v3 kit can
  declare where Claude reads skills, so sbx's shared store could replace the
  links.
