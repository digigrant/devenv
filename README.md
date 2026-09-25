# devenv

Rebuilds the agent dev environment in one command: a Docker Sandbox (`sbx`)
named `dev` that runs [Firstmate](https://github.com/kunchenguid/firstmate)
on the [herdr](https://github.com/herdrdev/herdr) backend, with Claude Code as
the agent. Every tool is pinned and checksum-verified, and the Claude
settings are reapplied on each start, including the owner's status line,
copied byte-for-byte. A portable layer (`provision.sh --plain`) sets up the
same tools on a plain Debian/Ubuntu machine without `sbx`.

```sh
cd ~/devenv && sbx env run
```

The design and every decision behind it are in [docs/SPEC.md](docs/SPEC.md).
The host-side verification checklist is [docs/HOST-VERIFY.md](docs/HOST-VERIFY.md).

## Quick start (host)

1. Meet the [host prerequisites](#host-prerequisites).
2. Clone devenv **next to** the workspace, never inside it:
   ```sh
   git clone https://github.com/digigrant/devenv ~/devenv
   ```
3. Put the gej-machine GitHub token in a file only you can read:
   ```sh
   install -d -m 700 ~/.config/devenv/secrets
   (umask 077; cat > ~/.config/devenv/secrets/github)      # the gej-machine token, then Ctrl-D
   ```
4. Check the host: `~/devenv/bin/devenv doctor`
5. Build and enter the sandbox: `cd ~/devenv && sbx env run`

You land in herdr, in a workspace named `firstmate`, where the first mate
(Claude at `xhigh` effort) runs in `~/dev/firstmate`. After each rebuild,
type `/login` there once and sign in with the Claude subscription; the login
survives restarts (`sbx stop`), and the sandbox's proxy keeps the tokens on
the host. (A `claude setup-token` token can't be stored as the sbx
`anthropic` secret: sbx sends it as an API key, which Anthropic rejects.) Detach with `ctrl+b q`;
panes keep running. Run `sbx env run` again to re-attach.

`sbx env run` shows a plan and asks for approval (`-y` skips the prompt). With
no path argument it also merges `~/.sbxenv.yaml` if you have one; use
`sbx env run .` to skip that file.

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

- **Treat `~/dev` as belonging to the sandbox.** Never run `git`, scripts or
  build tools in it from the host: agents can plant git hooks or scripts
  there. (`devenv doctor` prints this rule.)
- **devenv changes arrive only by PR.** Agents (as `gej-machine`) change
  devenv in their own clone and open a PR; the owner merges, then runs
  `git -C ~/devenv pull`. Everything that runs on the host (the lifecycle
  hook, the secret commands, `bin/devenv` host commands, kit network rules)
  therefore comes only from reviewed code.
- The `~/devenv` checkout must never be inside a folder the sandbox can
  write. Inside the sandbox it is mounted read-only. `devenv doctor` and
  `devenv host-prepare` refuse to continue otherwise.
- Secrets never go in the repo. The `github` secret is the `gej-machine`
  token only, never a personal token.
- Never allow `herdr.dev`: herdr is pinned, and its update and manifest
  checks are off.
- Merges follow Firstmate's rule: never without the owner's explicit word.
  `yolo` stays off.

## Choosing what the sandbox opens

`env.DEVENV_ENTRY` in `sbxenv.yaml`:

| Value | Opens |
|---|---|
| `herdr` (default) | herdr with the `firstmate` workspace, creating it (and starting the first mate) only if it doesn't exist |
| `claude` | plain Claude in `~/dev` |
| `shell` | a login shell |

Edit it and run `sbx env run` again; no recreate is needed.

## What persists

| Thing | Where | Survives `sbx rm`? |
|---|---|---|
| devenv | host `~/devenv` (read-only in the sandbox) | yes |
| Secrets | host `~/.config/devenv/secrets/` (0600) | yes |
| Firstmate home (clone, `config/`, `data/`, `state/`) | `~/dev/firstmate` | yes |
| Claude memory | `~/dev/.devenv-state/claude-memory/<project>/`, linked from `~/.claude/projects/<project>/memory` | yes |
| Firstmate project clones | `~/fm-projects` (sandbox disk) | no: push your work |
| treehouse worktrees | `~/.treehouse` (sandbox disk) | no |
| herdr sessions, Claude transcripts | sandbox | no |

## Commands

`bin/devenv` (on `PATH` inside the sandbox):

| Command | Where | What |
|---|---|---|
| `devenv doctor` | host, sandbox, plain | Full health report. On the host: sbx, KVM, policy, secret files, checkout location, operating rule. Inside: pinned tools, GitHub identity, Claude login, herdr, Firstmate bootstrap, settings. |
| `devenv check [--quiet]` | sandbox, plain | Staleness warnings: Firstmate ahead of its pin, tool versions, GitHub token expiry (via the API), `ANTHROPIC_TOKEN_EXPIRES` (if set), Firstmate config drift, herdr detection override. Shown at entry and as `⚠ devenv:N` in Claude's status line. |
| `devenv bump …` | a writable clone | Update `versions.env`: `firstmate`, `herdr <v>`, `herdr-manifest <commit\|latest>`, `treehouse\|no-mistakes <v\|latest>`, `npm <pkg> <v\|latest>`, `node <v\|latest-lts>`, `--list`. Prints the diff; never commits. |
| `devenv test` | sandbox or any Docker host | Status line byte-identity, shellcheck, `provision.sh --plain` in `ubuntu:24.04` and `ubuntu:26.04` containers (twice, to prove it's idempotent), and a simulated sbx create that runs the kit's own install and startup steps. |
| `devenv start` | sandbox | Run by the kit at every start: reapply Claude settings, status line, `CLAUDE.md`, herdr config, memory links, warnings. |
| `devenv entry` | sandbox | The entrypoint (via `devenv-entry`). |
| `devenv host-prepare` | host | The `lifecycle.initialize` hook: checks secrets and the checkout location, syncs skills into sbx's store. |
| `devenv skills-sync` | host | Put `skills/` into sbx's shared skills store; removes skills deleted from the repo. |
| `devenv up` | host | Fallback only (V5): render `sbxenv.yaml` with absolute paths and run it. |

### Updating versions

Pins live in `versions.env`, one tool per block, with a sha256 for every
download. To move one, work in your own clone and open a PR:

```sh
git clone https://github.com/digigrant/devenv ~/src/devenv
devenv bump --repo ~/src/devenv --list
devenv bump --repo ~/src/devenv herdr 0.9.1      # warns loudly: Firstmate has not verified 0.9.1
```

Claude Code is not pinned; it updates itself. Firstmate is pinned to a commit
that only fresh setups check out; an existing clone is never reset, so
`/updatefirstmate` keeps working. `devenv check` then warns that Firstmate is
ahead of its pin, and `devenv bump firstmate` records the new commit.

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
`--git-identity bot`.

## Layout

```
sbxenv.yaml            sbx layer: kit, workspaces, env, secrets, lifecycle
kits/devenv/           v2 sandbox kit (extends claude; entrypoint devenv-entry)
provision.sh           portable installer: --sbx | --plain
devenv.conf            non-secret settings
versions.env           every pin and sha256
repos.txt              optional repos to clone into the workspace
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
- **Claude asks to `/login` after a rebuild.** Expected: log in once per
  rebuild (V1). If `devenv doctor` inside the sandbox says
  `SBX_CRED_ANTHROPIC_MODE=apikey`, a stored `anthropic` secret is shadowing
  the login: `sbx secret ls`, remove it, and recreate.
- **The sandbox opens Claude instead of herdr.** The kit's entrypoint wasn't
  used (V2). Run `devenv entry` by hand, or use the mixin fallback described in
  `kits/devenv/spec.yaml`.
- **Skills are missing.** Check `sbx skills ls` on the host. Fallback: set
  `sandboxOptions.skills: off` in `sbxenv.yaml` and `DEVENV_SKILLS=link` in
  `devenv.conf`, then recreate.
- **A download is blocked (HTTP 403).** Add only that host to
  `permissions.network.allow` in `kits/devenv/spec.yaml` (by PR), then
  recreate. Never `herdr.dev`.
- **`setup.install` can't find the devenv checkout (V7).** Set
  `DEVENV_STAGE_PAYLOAD=on`; `host-prepare` then copies what provisioning
  needs into the kit.
- **Effort isn't `high` in new sessions.** The default is written per model
  (`CLAUDE_EFFORT_MODELS` in `devenv.conf`), because Claude Code ignores a
  model-independent effort in user settings. Add the new model's id there when
  the default model changes; `devenv doctor` flags a mismatch.
- **herdr shows agents as idle while they work.** Check
  `devenv doctor` → "herdr Claude detection". It should say `local override`.
- Logs: `~/.cache/devenv/start.log`, `/var/log/sbx-kit-startup.log`,
  `~/.cache/devenv/herdr-server.log`.

## Roadmap (not built yet)

- A GitHub permission system for agents: rulesets or a bot bypass list, or a
  GitHub App with short-lived tokens through `secrets.github.command` plus
  `refresh`.
- A secrets manager: swap the `command:` lines in `sbxenv.yaml` for
  `ref: op://…`.
- Worker effort and model profiles in Firstmate's `config/crew-dispatch.json`.
- A second worker harness (e.g. Codex): `config/crew-harness` plus its install.
- Bumping herdr past 0.8.0 once Firstmate verifies newer versions.
