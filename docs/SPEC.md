# devenv — Spec

| | |
|---|---|
| **Status** | Current design, revised 2026-09-26 to match the implementation and the owner's decisions since the original spec, on 2026-09-27 for the Infisical secrets manager ([SECRETS.md](SECRETS.md)), and on 2026-09-28 for Tailscale on the host (D33, §6.14) and the opt-in Android emulator (D34, §6.15). The originally approved version is commit `3cd88ee`; why each thing changed is in [HANDOFF.md](HANDOFF.md). |
| **Written** | 2026-09-25, from a design interview with the owner (GitHub: `digigrant`) |
| **Repo** | `github.com/digigrant/devenv` (public; contains no secrets) |
| **Readers** | The owner, and agents (Firstmate's first mate and workers) changing devenv |
| **Researched against** | sbx v0.45.1, Claude Code 2.1.28x, herdr 0.8.0, Firstmate `main` (owner's fork) |

---

## 0. Rules for agents working on devenv

1. **The decisions in §3 are settled.** Don't reopen them or change the architecture without the owner. If something fails and §7 has no answer, **stop and ask the owner**: explain the issue in plain terms, give the options, and recommend one.
2. **Git workflow.** Work on a branch, push as `gej-machine`, and **open a PR**. **Never merge.** The owner reviews, merges, and pulls on the host.
3. **Inside the sandbox, devenv runs from the clone at `~/fm-projects/devenv`** (`$DEVENV_DIR`). Work in your own worktree on a branch; never edit, commit in, or switch the branch of that clone.
4. **You cannot run `sbx`.** It is a host-only CLI; the host is WSL2 on Windows, and a native Linux machine later. Build and test everything you can inside the sandbox (`devenv test`). For the rest, write exact host commands with expected output into `docs/HOST-VERIFY.md` and the PR description. The owner runs them and reports back.
5. **Sandbox shell rule.** Never add shell-completion scripts to `/etc/sandbox-persistent.sh`. It is sourced before every bash command, and completion scripts break the shell entirely.
6. **Don't touch the owner's old files** under `/home/gejoy/dev/.claude/` (they power the old `claude-dev` sandbox) until Phase 5, and only after the owner confirms.
7. **Keep the docs in step with the code:** this spec, `README.md`, `docs/HOST-VERIFY.md`, `docs/HANDOFF.md` and the PR description.
8. **Firstmate** is the owner's fork, updated automatically from upstream. If Firstmate changes in ways that affect this spec (config formats, required tools), follow the current Firstmate docs and note the difference in the PR. The fork may be modified, minimally, only after showing that unmodified Firstmate doesn't work.

---

## 1. Goal and scope

### Goal
One repo that rebuilds the owner's agent dev environment quickly and reproducibly:
- in a **Docker Sandbox** (`sbx`) on WSL2 today and on a native Linux machine later;
- and, through a portable layer, on a plain Debian/Ubuntu machine without `sbx`.

The environment runs **Firstmate** (an agent orchestrator) on the **herdr** backend (a terminal multiplexer for agents), with **Claude Code** as the agent. Rebuilding is **one host command**: `sbx env run` inside `~/devenv`.

### In scope
- Installing and configuring the tools (herdr, Firstmate, and Firstmate's helper tools), all pinned except Claude Code and Firstmate.
- The owner's Claude Code user settings, including the **status line, reproduced exactly as it is now**, plus effort defaults and skills.
- Host-side `sbx` wiring: secrets, network allowances, entry command, lifecycle hooks.
- Keeping chosen state across teardown: Firstmate's home and Claude's memory.
- Tailscale on each host (D33): installing it, the one-time sign-in, and `doctor` checks. It is for Magic Conch, a phone app that will reach a hub on each machine over the tailnet. The hub itself and any `tailscale serve` or Funnel configuration are later work.
- Warnings for drift and expiry, commands to bump versions, a host "doctor" check, and a container smoke test.
- An opt-in Android emulator on the host that sandboxes drive with `adb` (D34, §6.15).

### Out of scope (do not build)
- A GitHub permission system for agents. That is future work; Firstmate's merge rule covers it for now.
- Any secrets manager other than Infisical as designed in [SECRETS.md](SECRETS.md) (D7), and the items that document leaves for later (its §11 exclusions and §12).
- CI or GitHub Actions, Renovate, or auto-bump PRs.
- The Windows `sbx.exe` path. Only the Linux `sbx` (inside WSL or native) is supported.
- tmux, or any Firstmate backend other than herdr.
- Optional Firstmate features: Relay, the mail plane, typesafe dispatch, remote secondmates, lavish-axi, and a Chromium browser.
- Other agent harnesses such as Codex or OpenCode. Keep the worker harness a single setting, but only install Claude Code.
- The owner's `digigrant/claude-shared` repo, the owner's `digigrant/dotfiles` repo, and any older "VM pool" plans. **Do not use or reference them.**

---

## 2. Facts

Researched on 2026-09-25 and 2026-09-26. Versions move; check before relying on a detail.

### 2.1 The old sandbox (`claude-dev`)
The sandbox devenv replaces; it runs alongside `dev` until Phase 5, and devenv's agents were built and tested in it.
- Ubuntu 26.04.1, x86_64, kernel 7.0.12. User `agent` (uid 1000, groups `sudo` and `docker`). `HOME=/home/agent`.
- Hardware: 24 CPUs, 7.4 GiB RAM, and a 20 GB root disk.
- **Workspace mode is "direct".** The host folder `/home/gejoy/dev` (in WSL) is mounted over virtiofs at the **same path**, read-write. `WORKSPACE_DIR=/home/gejoy/dev`.
- **The host's home folder differs per machine.** WSL uses `/home/gejoy`; the other Linux machine uses `/home/grant`. **Never hardcode a home path.**
- Preinstalled tools (the claude template image; the same in `dev`):
  - git 2.53, gh 2.46 (Ubuntu's package; provisioning replaces it with GitHub's current release, §6.3), Node v22.22.1, npm 9.2.0, python 3.14, uv 0.9.26, jq 1.8.1, curl, Docker 29.8.1 (an in-sandbox engine);
  - Claude Code (native build in `~/.local/bin`), which auto-updates.
  - The npm global prefix is `/usr/local/share/npm-global` (its `bin` is on PATH).
- Environment and plumbing:
  - `/etc/sandbox-persistent.sh` is sourced into every shell (`BASH_ENV`, profile, bashrc) and is also `CLAUDE_ENV_FILE`.
  - All HTTP(S) goes through a proxy at `gateway.docker.internal:3128`. The proxy intercepts TLS; its CA is base64-encoded in `PROXY_CA_CERT_B64`.
  - Credentials are injected by the proxy. The sandbox only ever sees placeholders (`GH_TOKEN=gho_sbxproxymanaged…`, `sk-ant-oat01-proxy-managed`).
  - A blocked request gets HTTP 403 with an explanation in the body. Example: `herdr.dev` is blocked by the default-deny policy.
- `~/.claude/{projects,sessions,todos,shell-snapshots,statsig}` are separate block volumes owned by the sandbox. Because `claude-dev` runs the built-in `claude` agent, `~/.claude/skills` is a read-only mount of `sbx`'s shared skills store.
- `sbx` generates a `CLAUDE.md` (runtime guidance) in the **parent folder of the workspace**, which is not host-mounted, plus `kits-agent-context/`.
- GitHub: `gh api user` → `gej-machine` (id `318032932`), a classic token with the `repo` scope only (no `read:org`, no `workflow`). Its expiry is readable from the `github-authentication-token-expiration` response header through the proxy; the current token expires 2026-12-24.

### 2.2 Docker Sandboxes (`sbx`)
Docs: https://docs.docker.com/ai/sandboxes/ (source: `docker/docs`, `content/manuals/ai/sandboxes/`, CLI reference in `data/sbx_cli/`). Kit specs: `docker/sandbox-kit-spec` (v3) and `docker/sbx-kits-contrib` (v2 spec library and validator).

- **Local sandboxes are microVMs.**
  - Linux host requirements: Ubuntu 24.04+, KVM, the user in the `kvm` group, and nested virtualization if the host is itself a VM.
  - Linux install:
    ```sh
    curl -fsSL https://get.docker.com | sudo REPO_ONLY=1 sh
    sudo apt install docker-sbx
    sudo usermod -aG kvm $USER
    ```
    Then `sbx login` (a Docker account is required) and `sbx policy init balanced`.
  - On WSL, Docker calls running the Linux `sbx` inside WSL "best-effort" (their preferred route is the Windows `sbx.exe`; see docker/sbx-releases#397). **The owner chose the Linux `sbx` in WSL**, so that WSL and native Linux behave the same.
- **`sbxenv.yaml` + `sbx env plan|run|create|exec|rm`** (experimental, sbx ≥ 0.42):
  - Top-level fields: `schemaVersion: "1"` (required), `name`, `agent` (required: a built-in agent or the name of an agent kit listed under `kits`), `args`, `kits` (a path or `{source, args}`), `workspace`, `additionalWorkspaces`, `env`, `sandboxOptions` (`template, memory, cpus, pullPolicy, profile, skills, display, gpu, usb`), `secrets`, `bindings`, `registries`, `mcp.servers`, `ports`, `lifecycle`.
  - **Layout.** Docker's docs keep the environment file **beside the workspace and outside every mounted folder** (the primary workspace and every `additionalWorkspaces` mount), e.g. `web-app-env/sbxenv.yaml` with `workspace: ./web-app`. `sbx` mounts the file itself read-only into the sandbox.
  - Relative paths resolve from the file's directory. Only `${{ env.args.X }}`, `${{ env.projectDir }}` and `${{ env.fileDir }}` expand; `${VAR}` does not.
  - `lifecycle.initialize | postCreate | preRemove` run **on the host**, with the owner's privileges.
  - Changes to workspaces, kits (and kit arguments), ports, secrets, bindings and `sandboxOptions` apply **only when the sandbox is next created**. Changes to `env` and MCP servers apply on the next `sbx env run`.
  - `sbx env run` shows a plan and asks for approval; `-y` skips it, `-d` creates/starts without attaching. `--kit-arg NAME=VALUE` passes kit arguments (`plan`, `run`, `create`). `sbx env exec -it -- CMD` runs a command in the environment's sandbox.
  - A failed create only prints `failed to apply kit to sandbox`; the install step's output is in `~/.local/state/sandboxes/sandboxes/sandboxd/daemon.log` on the host.
- **Kits.** The built-in agents (`claude`, …) are **v2** kits, and v2 and v3 kits can't be combined, so devenv's kit is v2.
  - A v2 kit is a folder holding `spec.yaml` (`schemaVersion: "2"`, `kind: mixin|sandbox`) plus an optional `files/` tree (`files/home/` → `/home/agent/`, `files/workspace/` → the workspace).
  - Blocks: `args`, `permissions.network.allow/deny`, `credentials`, `environment.variables`, `setup.install` (runs as root by default via `sh -c`, synchronously, before the terminal attaches), `setup.startup` (runs at every start as uid 1000 from a **detached** dispatcher, logged in `/var/log/sbx-kit-startup.log`; it doesn't gate the entrypoint), `setup.files`, `volumes`, `ports`, `agentInstructions`.
  - Kit arguments: `args: {name: {default|required, pattern|enum}}`, referenced as `${{ kit.args.name }}` anywhere in `spec.yaml`; substituted before YAML decoding.
  - Order at create: network and env → `files/home` → install → `setup.files` → register startup → `files/workspace`.
  - Forking an agent: `kind: sandbox`, `extends: claude`, `sandbox.entrypoint: [...]`. The child inherits the image, credentials, network rules, volumes, settings and setup. **A mixin can't change the entrypoint.**
  - To add shell init, append to `/etc/sandbox-persistent.sh` in an install command, never completion scripts.
- **Files `sbx` manages** (don't target these with kits): `~/.claude.json`, `~/.claude/settings.json`, `~/.claude/.config.json`. The claude kit writes `~/.claude/settings.json` in its install step at every (re)create, with `themeId`, `alwaysThinkingEnabled`, `permissions.defaultMode: bypassPermissions`, bypass-accepted flags, and `apiKeyHelper` when the Anthropic mode is `apikey`.
- **Skills:**
  - `sbx skills import` copies the host's `~/.claude/skills`; `sbx skills add owner/repo` installs from git. Both go into the host's shared store.
  - The store is mounted (read-only by default) at `~/.claude/skills` **only in sandboxes that run a supported (built-in) agent**. A custom kit such as devenv's doesn't get it; v2 kits can't declare where their agent reads skills (v3 kits can, with `agent-skills@1`). `sandboxOptions.skills: "off"` omits the mount. (Quote `"off"`: bare `off` is a YAML boolean.)
- **Persistence:**
  - `sbx stop` and restart keep everything.
  - `sbx rm` / `sbx env rm` deletes the VM, secrets scoped to that sandbox, and its `~/.claude/*` volumes. The workspace on the host survives.
  - There is no way to export a whole sandbox.
- **Secrets:**
  - `sbx secret set [SERVICE] [--sandbox NAME] (-t VALUE | --ref … | --command '…')`. Services include `anthropic` and `github`. `sbxenv.yaml` `secrets:` stores them sandbox-scoped at create; sandbox-scoped secrets outrank global ones.
  - **For a command source, sbx stores the command text, never the value** (SECRETS.md §3): age-encrypted under `~/.config/com.docker.sandboxes/`, and in plain text in `~/.local/state/sandboxes/sandboxes/sandboxd/runtimes/<sandbox>.json`. sandboxd runs the command on the host and keeps the value only in memory, for the secret's `--refresh`: `55m` by default for a service secret, but `on-demand` (every use) by default for a custom secret. `--refresh` takes `on-demand` or a Go duration (`55m`, `1h30m`, `90s`). So a command must never contain a secret.
  - `${{ env.fileDir }}` expands in any YAML value of an environment file (sbx ≥ 0.43), including `secrets.<service>.command`. Other `$` text is passed on unchanged, to the shell that runs the command. The only other expressions are `${{ env.projectDir }}` and `${{ env.args.NAME }}` (from the file's `args:` defaults, `--env-arg` or `--env-args-file`); host environment variables are never expanded, and argument values aren't passed to lifecycle commands.
  - A third-party kit needs a `bindings` entry (`bindings.<service>.apiKey.domains`) before the proxy injects a stored credential for it.
  - **Custom secrets:** `sbx secret set-custom --sandbox NAME --host H --env VAR --placeholder P --command '…'` puts placeholder `P` in `VAR` inside the sandbox and has the proxy swap in the real value on requests to `H`. `sbxenv.yaml` can't declare them. Command sources run from a temp directory on the host, so they need absolute paths.
    - A scope holds **one custom secret per env var**, keyed by its placeholder (checked against sbx 0.45.1): `set-custom` with the placeholder already stored updates the record (command, hosts, refresh), while a different placeholder for the same `VAR` fails with `custom secret env "VAR" already exists in scope "NAME" with placeholder "…"`. Leaving out `--placeholder` doesn't reuse the stored one either. `sbx secret ls --sandbox NAME --json` lists the scope's custom secrets (`scope`, `targets`, `env`, `placeholder`, `kind`, `source`, `refresh`; never a value) without needing the daemon.
    - `VAR` gets its value when the sandbox is created, so a running sandbox keeps the placeholder it started with.
    - Remove one with `sbx secret rm --sandbox NAME --host H [--env VAR] -f` or `sbx secret rm --sandbox NAME --placeholder P -f` (`--host`, `--env` and `--placeholder` work but aren't in `--help`). Without `--sandbox` it looks only at global secrets. It exits 0 when nothing matches.
  - A `claude setup-token` token stored as the `anthropic` service secret is treated as an **API key** (`SBX_CRED_ANTHROPIC_MODE=apikey`) and Anthropic rejects it (HTTP 401). As a custom secret on `CLAUDE_CODE_OAUTH_TOKEN` for `api.anthropic.com` it works (`authMethod: oauth_token`).
- **Network policy:**
  - `sbx policy init allow-all|balanced|deny-all`; `sbx policy allow|deny network [--sandbox N] "hosts…"`, plus `sbx policy ls|check|log`.
  - **There is no policy file to import or export.** Rules for reproducibility therefore go in the kit (`permissions.network.allow`, scoped to one sandbox).
  - The `balanced` baseline allowed every download devenv makes (GitHub releases, npm, github.com).
  - **Raw TCP to the host.** All of a sandbox's outbound TCP goes through the host-side proxy: HTTP(S) clients use its forward proxy, anything else is intercepted transparently, and both enforce the policy. Non-HTTP TCP (SSH, adb, databases) is allowed by a hostname or address rule; the hostname is recovered from the sandbox's DNS resolver. `host.docker.internal` (169.254.1.1 in the sandbox) reaches the host's `localhost`, and the policy resource is `localhost:<port>` (`sbx policy allow network localhost:<port>`); since sbx 0.30 that also holds for raw TCP ("Allow raw TCP to `host.docker.internal` when localhost is allowed in policy", docker/sbx-releases#211, #147), and since 0.40 a server that speaks first works too (#411). The transparent proxy accepts every TCP connection at once and only then applies the policy, so a denied or dead destination shows up as a connection that closes, not a refused connect; through the forward proxy a denied destination gets HTTP 403 with the reason (`Blocked by network policy: domain localhost:<port>`). Checked in a sandbox on 2026-09-28: SSH to an allowed `ssh.github.com:443` passes (the server's banner comes back); `host.docker.internal:<port>` without a rule is closed, and its 403 names `localhost:<port>`.
  - **No KVM inside a sandbox** (no `vmx`/`svm`, no `/dev/kvm`). sbx's nested virtualization (`sbx settings set feature.sandbox-nested`, `--nested`) is documented for macOS on Apple Silicon M3+ only (docker/sbx-releases#497). An Android emulator therefore runs on the host (D34).
- **Resources:** memory defaults to 50% of host memory (512 MiB–32 GiB, at most 75% of the host); CPUs default to all host CPUs; the Docker volume defaults to 10 GB.

### 2.3 Firstmate (`github.com/digigrant/firstmate`, the owner's fork of `kunchenguid/firstmate`, MIT, very active)
- An "agent distro": a repo of `AGENTS.md`, skills and bash `bin/` scripts. You clone it and run `claude` **inside the clone**; that session becomes the "first mate", which starts workers in git worktrees (via treehouse) inside a runtime backend.
- **Home folder layout.** The home is the repo root unless `FM_HOME` is set. `config/`, `state/`, `data/`, `projects/` and `.env` are all gitignored. Overrides: `FM_STATE_OVERRIDE`, `FM_DATA_OVERRIDE`, `FM_PROJECTS_OVERRIDE`, `FM_CONFIG_OVERRIDE`.
- **Config files** (each is one token, trimmed):
  - `config/backend`: `herdr`. Selection order: `--backend` flag, then `FM_BACKEND`, then `config/backend`, then auto-detection (`$TMUX`, then `HERDR_ENV=1`), then tmux.
  - `config/crew-harness`: `claude`; absent or `default` means workers mirror the primary.
  - `config/claude-permission-mode`: `bypass` (`--dangerously-skip-permissions`); `auto` → `--permission-mode auto`; absent means bypass.
  - `config/crew-dispatch.json`: optional per-worker `--model` / `--effort` profiles. **Leave it absent for now.**
- **herdr backend:** requires herdr protocol ≥ 14. **Verified herdr versions: 0.7.1, 0.7.3, 0.7.4, 0.7.5, 0.8.0** (`docs/herdr-backend.md`). A first mate running outside herdr is also supported (its workers get the home's own herdr workspace); devenv runs it inside herdr.
- **Required tools** (`COMMON_TOOLS` in `bin/fm-bootstrap.sh`): `node git gh no-mistakes gh-axi chrome-devtools-axi tasks-axi quota-axi`. The herdr backend adds `herdr jq treehouse`, and optionally `python3`.
- `FM_BOOTSTRAP_DETECT_ONLY=1 bin/fm-bootstrap.sh` is a read-only probe (prints `MISSING…`, `NEEDS_GH_AUTH`, etc.). At session start, bootstrap probes `gh auth status` (it passes through the proxy's `GH_TOKEN`).
- `bin/fm-update.sh` is the fast-forward-only updater behind `/updatefirstmate`.
- **Projects.** Clones live flat under `$FM_PROJECTS_OVERRIDE` (default `$FM_HOME/projects`); `data/projects.md` is the registry: name, delivery mode, optional `+yolo`/`branch=`/`forge=`, description. It holds **no URLs**, and Firstmate rebuilds a stale registry from the clones (an entry whose clone is gone is dropped). `bin/fm-fleet-sync.sh` fast-forwards each clone's default branch when it is clean and checked out, and reports any other state as `STUCK` without touching it.
- Worktrees are created by treehouse under `~/.treehouse/` by default.
- Workers inherit the environment unless the opt-in `config/launch-env-allowlist` or `config/claude-account` exists (devenv creates neither).
- **Merge rule** (AGENTS.md rule 2): *"Never merge a PR without the captain's explicit word."* A per-project `yolo` posture is the only standing relaxation. **Do not enable yolo.**
- Delivery modes: `no-mistakes`, `direct-PR`, `local-only`, and the policy `no-mistakes-prod-only`.

### 2.4 herdr (`github.com/herdrdev/herdr`, Apache-2.0 since 0.8.0)
- A Rust terminal multiplexer for agents: a single static binary with a background server and a client TUI that communicate over a Unix socket. It has **no TCP port and no web UI**.
- **Pinned release v0.8.0**, installed as `~/.local/bin/herdr` from GitHub Releases (`herdr-linux-<x86_64|aarch64>`, digests in `versions.env`).
- **Config** at `~/.config/herdr/config.toml`: `onboarding = false`, `[update] version_check = false`, `manifest_check = false` (key names confirmed with 0.8.0). State (sessions, sockets, logs) lives in `~/.config/herdr/`.
- **CLI:** `herdr` attaches, starting the server if needed; detach with `ctrl+b q` (panes keep running). `herdr server stop`, `herdr status server --json`, `herdr workspace create [--cwd] [--label] [--focus]` (JSON with `.result.root_pane.pane_id`), `herdr workspace list`, `herdr pane run <pane_id> <command>`. `herdr integration install claude` writes `~/.claude/hooks/herdr-agent-state.sh` and **edits `~/.claude/settings.json`** (a `SessionStart` hook; needs `python3` to report session identity).
- **Agent detection** reads each pane's screen and title with a rules file per agent. The rules bundled in 0.8.0 predate Claude Code 2.1.228's title spinner, so Claude never shows as "working". Local overrides are read from `~/.config/herdr/agent-detection/<agent>.toml`; herdr's own published `distribution/agent-detection/claude.toml` (commit `a05c403`, v2026.09.11.1) fixes it. `herdr server reload-agent-manifests` / `herdr server agent-manifests --json` show which rules are active. herdr switches to "working" about 3 s after a turn starts (its own debounce).
- The official installer and manifest updates use `herdr.dev`, which is **blocked, and not needed.**

### 2.5 Other pinned artifacts
Current pins and checksums are in `versions.env`. As of 2026-09-26:

| Tool | Version | Notes |
|---|---|---|
| treehouse (`kunchenguid/treehouse`) | v2.3.0 | `treehouse-v<ver>-linux-<amd64\|arm64>.tar.gz`; 3.0.0 exists (major bump, not adopted) |
| no-mistakes (`kunchenguid/no-mistakes`) | v1.79.0 | Firstmate requires ≥ 1.46.0 |
| gh-axi (npm) | 0.1.35 | `gh-axi setup hooks` after install |
| chrome-devtools-axi (npm) | 0.1.35 | `chrome-devtools-axi setup hooks` after install; **no browser** |
| tasks-axi (npm) | 0.2.6 | |
| quota-axi (npm) | 0.1.54 | declares `engines.node >=22.19` |
| Node (plain mode only) | 24.21.0 | floor 22.19.0 |

`gh-axi setup hooks` and `chrome-devtools-axi setup hooks` each add a `SessionStart` hook to `~/.claude/settings.json` and also write `~/.codex/config.toml`, `~/.codex/hooks.json` and `~/.config/opencode/plugins/axi-*.js`. Both are idempotent and ignore `CLAUDE_CONFIG_DIR`.

### 2.6 Claude Code
- `claude --effort <level>` sets effort **for one session only**.
- The default effort for new sessions is `modelSettings.<model-id>.effortLevel` in `~/.claude/settings.json` (what `/effort` saves). A top-level `effortLevel` in user settings is treated as legacy and **ignored** for current models (tested with `claude-opus-5-5` on 2.1.282), so there is no model-independent key.
- `$HOME` expands in the `statusLine` command.
- Auth precedence: an `apiKeyHelper` or API key outranks `CLAUDE_CODE_OAUTH_TOKEN`, which outranks the stored `/login`. A `claude setup-token` token is inference-only: claude.ai connectors, Remote Control, Claude in Chrome and plugin sync don't work with it.
- `autoMemoryDirectory` exists but is one fixed folder for every project; memory lives per project in `~/.claude/projects/<slug>/memory/`.
- User-level skills in `~/.claude/skills/<name>/SKILL.md` (symlinks work) are seen by every session; a project's `.claude/skills` only by sessions in that project.
- The owner's current user and project settings are reproduced in Appendix A.

### 2.7 Tailscale
Researched on 2026-09-28 from Tailscale's docs (tailscale.com/docs, which serves each page as Markdown at `<page>.md`), its installer (`scripts/installer.sh` in `tailscale/tailscale`) and Microsoft's WSL docs (`MicrosoftDocs/WSL`). `pkgs.tailscale.com` and `learn.microsoft.com` are blocked inside the sandbox; neither is needed there.
- **Linux install.** Tailscale documents `curl -fsSL https://tailscale.com/install.sh | sh`, or the manual steps per release on `pkgs.tailscale.com/stable`. For Ubuntu and Debian (`<os>` `ubuntu` or `debian`; the codename from `/etc/os-release`, `UBUNTU_CODENAME` first, as the installer reads it; `noble` and `resolute` are published):
  - the key `https://pkgs.tailscale.com/stable/<os>/<codename>.noarmor.gpg` → `/usr/share/keyrings/tailscale-archive-keyring.gpg`;
  - the source `<codename>.tailscale-keyring.list` → `/etc/apt/sources.list.d/tailscale.list`: `# Tailscale packages for <os> <codename>` and `deb [signed-by=/usr/share/keyrings/tailscale-archive-keyring.gpg] https://pkgs.tailscale.com/stable/<os> <codename> main`;
  - `apt-get update`, then `apt-get install tailscale tailscale-archive-keyring` (the installer installs both; the keyring package keeps the key current). On Ubuntu and Debian the package enables and starts `tailscaled` itself.
  - Then `sudo tailscale up` prints a sign-in URL (`https://login.tailscale.com/a/…`) and waits until the browser sign-in completes.
- **WSL 2** ([Tailscale's page](https://tailscale.com/docs/install/windows/wsl2), validated Nov 2025): with Tailscale running on the Windows host and inside WSL 2 at the same time, Tailscale traffic from WSL doesn't work, so Tailscale recommends Windows only (the owner chose WSL instead, D33). WSL's default MTU of 1280 is too small for Tailscale; tailscaled raises it to 1340 on WSL by itself (tailscale/tailscale#4833). The WSL node may get the Windows node's name.
- **systemd in WSL** (Microsoft's `systemd.md` and `wsl-config.md`): `[boot]` `systemd=true` in `/etc/wsl.conf`, WSL 0.67.6 or newer, then `wsl.exe --shutdown` from PowerShell. Ubuntu's WSL image enables it by default. systemd is the init when `/run/systemd/system` exists. WSL shuts an idle distro down after `instanceIdleTimeout` (`.wslconfig` `[general]`, 15000 ms by default) and the VM after `vmIdleTimeout`.
- **Windows side.** The Windows service is `Tailscale`. Through WSL's interop, `sc.exe query Tailscale` prints its state (`4  RUNNING`, `1  STOPPED`) or error `1060` when it isn't installed. Uninstall: Settings > Apps > Tailscale > Uninstall.
- **`tailscale status --json`** runs without root and exits 0 in every backend state (it fails only when tailscaled doesn't answer); its format is "subject to change". devenv reads `BackendState` (`NoState`, `NeedsLogin`, `NeedsMachineAuth`, `Stopped`, `Starting`, `Running`), `AuthURL` (a pending sign-in), `TailscaleIPs`, `Self.DNSName` (ends with a dot), `Self.KeyExpiry` (absent when expiry is disabled), `CurrentTailnet.Name` and `.MagicDNSEnabled`, and `CertDomains` (empty unless HTTPS certificates are on).
- **HTTPS certificates** (for `tailscale serve`): the admin console's DNS page (`https://console.tailscale.com/admin/dns`), MagicDNS on (the default for tailnets created since 2022-10-20), then HTTPS Certificates > Enable HTTPS. A machine that gets a certificate has its name published in the public Certificate Transparency logs.
- **Key expiry**: 180 days by default; `sudo tailscale up --force-reauth` renews, or it can be disabled per machine on the Machines page.

---

## 3. Settled decisions

| ID | Decision |
|---|---|
| D1 | **What a rebuild restores:** tools and their config, Claude user settings (status line, effort, skills), host `sbx` wiring (secrets, network, entry), Firstmate's home and Claude's memory. A new sandbox clones **no projects** except devenv itself (D31); Firstmate clones projects on demand (D32). |
| D2 | **The repo is `digigrant/devenv`.** The owner's **host copy lives at `~/devenv`** and is **never mounted into the sandbox**. It follows Docker's environment-file layout: `sbxenv.yaml` sits beside the workspace folder `dev/` inside the checkout (gitignored). The checkout is never inside a folder a sandbox can write, and `dev/` is the only sandbox-writable folder inside it. |
| D3 | **Changes to devenv arrive only by PR.** Agents (as `gej-machine`, a collaborator) change devenv in a worktree of the sandbox's devenv clone, push a branch and open a PR. The owner merges, then `git pull`s on the host. Anything that runs on the host (lifecycle hooks, secret `command:`s, host scripts, the kit) therefore comes only from code the owner has reviewed and pulled. `main` is protected by a ruleset (PR with one approval; no force-push, no deletion). |
| D4 | **Two layers.** `provision.sh` is the portable installer, safe to re-run, for any Debian/Ubuntu machine (`--plain`) and inside `sbx` (`--sbx`). The `sbx` layer (`sbxenv.yaml` plus a local kit) calls it. Nothing experimental about `sbx` leaks into `provision.sh`. |
| D5 | **Rebuilding is one command:** `cd ~/devenv && sbx env run`. The spec assumes `sbx` is already installed on the host. `devenv doctor` checks host prerequisites; the README documents them. |
| D6 | **The sandbox is named `dev`.** The workspace is the host's `~/devenv/dev`, mounted read-write at the same path. |
| D7 | **Secrets live in Infisical, never in the repo or in plain-text files** ([SECRETS.md](SECRETS.md)). One Infisical project holds the agent credentials: `CLAUDE_CODE_OAUTH_TOKEN` (the setup-token, D8) and `GITHUB_GEJ_MACHINE_PAT` (D9). Each host logs in as the machine identity `sbx-host` (Universal Auth, Viewer on that project only) and keeps that login (project ID, client ID, one client secret per machine) in its Secret Service keyring, stored by `devenv secrets-init`. sbx fetches a value by running `devenv secret-get NAME` on the host (one `--command` each, registered by `host-prepare`, with the refresh in `SECRET_REFRESH*`), which logs in, reads the one secret and prints it; the value lives only in sandboxd's memory. Nothing from Infisical enters the sandbox. |
| D8 | **Claude login** uses the owner's long-lived `claude setup-token` subscription token as an **sbx custom secret**: `CLAUDE_CODE_OAUTH_TOKEN` holds a placeholder in the sandbox and the proxy swaps in the real token for `api.anthropic.com`. `devenv host-prepare` sets it up before every run (`CLAUDE_AUTH=token`). No `/login` after a rebuild. Fallback: `CLAUDE_AUTH=login` (no secret; `/login` once per rebuild). Never store the token as the `anthropic` service secret (§2.2). Its expiry is not tracked for now (`ANTHROPIC_TOKEN_EXPIRES` stays empty). |
| D9 | **GitHub identity:** the machine account **`gej-machine`**. The `github` secret is its classic `repo` token, injected for `api.github.com` and `github.com` through a `github` binding. Commits in the sandbox are authored by the bot: `gej-machine <318032932+gej-machine@users.noreply.github.com>`. The owner sets branch rules by hand; that is not part of this repo. |
| D10 | **Agents** run on Claude Code only (Pro plan). Firstmate's `crew-harness` is `claude` and `claude-permission-mode` is `bypass`; the sandbox is the security boundary. The worker harness stays one setting. |
| D11 | **Effort.** The global default effort is **`high`**, which workers inherit, written as `modelSettings.<model>.effortLevel` for the models in `CLAUDE_EFFORT_MODELS` (update it when the default model changes; `doctor` flags a mismatch). The **first mate is launched with `--effort xhigh`**. Both are values in `devenv.conf`. Per-worker tuning comes later, through Firstmate's `crew-dispatch.json`; don't create that file now. |
| D12 | **Merges** follow Firstmate's rule: never without the owner's explicit word. Don't enable `yolo`, and add no extra config. |
| D13 | **herdr is Firstmate's backend.** Pin herdr **0.8.0** (the newest version Firstmate has verified), installed as a checksummed binary from GitHub Releases, with update and manifest checks off, plus herdr's own published Claude detection rules as a pinned local override (§2.4). **Don't install tmux.** |
| D14 | **Firstmate features: core only.** Install gh-axi, tasks-axi, quota-axi, no-mistakes, treehouse and jq, **plus the `chrome-devtools-axi` npm package without a browser** so bootstrap stops complaining. Nothing optional. |
| D15 | **Versions** are pinned in one `versions.env`, updated with `devenv bump`. Claude Code is **not** pinned (it auto-updates). Firstmate is **not** pinned either: see D30. |
| D16 | **What persists across teardown:** Claude **memory** and Firstmate's **home** (config, data, state) persist, stored in the workspace and kept **on this machine only**. Claude transcripts, herdr sessions, project clones (including the sandbox's devenv clone) and treehouse worktrees are disposable. |
| D17 | **Placement:** Firstmate's home is in the workspace (`$WORKSPACE_DIR/firstmate`). **Project clones and worktrees live on the sandbox's own disk** (`FM_PROJECTS_OVERRIDE=$HOME/fm-projects`, treehouse's default `~/.treehouse`) for speed. `sbx rm` loses only unpushed work. |
| D18 | **Entry:** the sandbox launches `devenv-entry`. `DEVENV_ENTRY=herdr` (the default) opens herdr with a first-mate pane (Claude at xhigh in `$FM_HOME`). `claude` opens plain Claude in the workspace, and `shell` opens bash. Switch by editing `env` in `sbxenv.yaml` and re-running `sbx env run`; no recreate is needed. This is why devenv's kit is a `kind: sandbox` fork of `claude` rather than a mixin. |
| D19 | **Staleness warnings** (`devenv check`): Firstmate with commits its fork's `main` doesn't have, a failed or stopped automatic update, a Firstmate clone whose `origin` isn't the fork, uncommitted changes in the devenv clone the sandbox runs from, installed tools that don't match `versions.env`, a GitHub token expiring within 14 days (or invalid), Firstmate config that differs from devenv's starting copy, and a herdr detection override that is missing or untested with the pinned herdr. They appear as **a one-line warning at entry and a marker in Claude's status line**. `devenv doctor` gives the full report. No Renovate or CI. |
| D20 | **Status line is preserved exactly.** The owner's `statusline-command.sh` is copied **byte-for-byte** (sha256 `dc324500…`). With no warnings, the rendered status line must be **byte-identical** to the original's output. The D19 marker is added by a separate wrapper, only when warnings exist, and can be turned off with `DEVENV_STATUSLINE_WARNINGS=off` in `devenv.conf`. |
| D21 | **Skills** (`grill-me`, `grilling`) are kept in `devenv/skills/` exactly as they are and **linked** into `~/.claude/skills/<name>` from the devenv checkout (in sbx mode the sandbox's clone), by `provision.sh` and at every `devenv start`. `sbx`'s shared store is off for `dev` (`sandboxOptions.skills: "off"`): sbx mounts it only for its built-in agents (§2.2). |
| D22 | **User-level `~/.claude/CLAUDE.md`** is generated by devenv. It contains **sandbox environment notes only**, and makes the `sbx` runtime guidance reachable for workers whose working folders are outside the workspace's parent. The workflow rules come from Firstmate. |
| D23 | **Network:** the host keeps the `balanced` baseline policy. Any extra domains are declared in the kit's `permissions.network.allow` (scoped to the sandbox, version-controlled). **Never allow `herdr.dev`.** No published ports. |
| D24 | **Resources:** `sbx` defaults. `sandboxOptions.memory` stays as a commented-out knob. |
| D25 | **Platform:** the Linux `sbx` in WSL2, and native Linux (Ubuntu 24.04+ with KVM). Support both x86_64 and aarch64 assets. |
| D26 | **Testing:** `devenv test` runs the status line byte-identity test, the secrets commands against fakes, shellcheck, `provision.sh --plain` in throwaway `ubuntu:24.04` and `ubuntu:26.04` containers (Docker is available inside the sandbox), a simulated sbx create that runs the kit's own install and startup steps, and the keyring code against a real gnome-keyring in a container. No CI. |
| D27 | **Agent-agnostic layout.** Everything Claude-specific lives under `agents/claude/`, so the owner can move off Claude later by swapping that folder. |
| D28 | **Operating rule** for the owner, documented in the README and printed by `doctor`: **treat `~/devenv/dev` as belonging to the sandbox.** Never run `git`, scripts or build tools in it from the host, don't `cd` into it with a git-aware shell prompt or open it in an editor (agents could plant git hooks, git config or scripts there), and never `git clean -x` in `~/devenv` (it would delete the workspace). The same goes for `~/dev` while `claude-dev` exists. |
| D29 | **Switchover:** build the new `dev` sandbox next to the old `claude-dev` and verify it. Then the owner runs `sbx rm claude-dev` and cleans up the old `~/dev` files, after confirming. |
| D30 | **Firstmate comes from the owner's fork** `digigrant/firstmate` (`FIRSTMATE_REPO`), which follows `kunchenguid/firstmate` (`FIRSTMATE_UPSTREAM`), and **updates automatically**: whenever `devenv entry` starts a first mate (never under a running one), devenv fast-forwards the fork from upstream with GitHub's Sync fork as gej-machine (only when the fork is strictly behind), then runs Firstmate's own `bin/fm-update.sh` on `$FM_HOME`. Upstream changes arrive unreviewed. `FIRSTMATE_AUTO_UPDATE=off` pauses both. Fresh setups clone the fork's `main`; an existing clone's code is never reset by provisioning. The fork's `main` is deliberately not protected (a PR-required ruleset blocks the sync, and the owner has no `gh` login on the host). |
| D31 | **devenv inside the sandbox is one writable clone** at `$FM_PROJECTS_DIR/devenv` (`~/fm-projects/devenv`), made by the kit's install step at create from GitHub (kit args `repo`, `ref`; default `main`; `sbx env run --kit-arg ref=<branch>` to build from a branch). The sandbox runs devenv from it (`$DEVENV_DIR`), and it is also Firstmate's project clone of devenv. Firstmate keeps it fast-forwarded while it is a clean `main`; agents work on devenv only in worktrees (rule 3). |
| D32 | **Projects are cloned on demand.** The owner tells the first mate each project's name, URL and delivery mode once (devenv: `direct-PR`); Firstmate remembers it in its home (which persists) and clones into `~/fm-projects` when a task needs the project. |
| D33 | **Tailscale runs on every host, in Linux:** inside the WSL 2 distro on the Windows PC, with Tailscale on Windows uninstalled (or kept stopped), and natively on a Linux PC. `devenv tailscale-setup` installs it from Tailscale's own apt repository and signs the machine in; host `doctor` checks it. Sign-in is the interactive browser sign-in of `sudo tailscale up`, once per machine: devenv never uses an auth key and stores no Tailscale secret. MagicDNS and HTTPS certificates are turned on once, in the admin console, for the Magic Conch hub's later `tailscale serve`. Owner's decision, 2026-09-28 (their option B: "Move it into WSL and let devenv manage it, taking it off Windows"). |
| D34 | **Android emulator: opt-in, on the host, driven from sandboxes over adb** (owner, 2026-09-28). `devenv emulator start` runs one headless emulator per host in a Docker Engine container with `/dev/kvm`, on demand (never always-on), with its adb port published on the host's `127.0.0.1` only (`ANDROID_EMULATOR_PORT`, default 15555). Sandboxes reach it at `host.docker.internal:<port>` through **one host-wide policy rule the owner adds once**, `sbx policy allow network localhost:<port>` (documented, not run by devenv, and not a kit rule: the emulator is opt-in per host, and a global rule survives sandbox rebuilds). The image is devenv's own, following Google's emulator container recipe, built from Google's zips pinned by sha256 (§6.15); the SDK lives in a Docker volume. Sandboxes get Google's platform-tools (`adb`), pinned. It is Docker's port publishing on the host, not an sbx published port (D23 is unchanged). GitHub Actions emulator setup belongs to each app's own repository. |

---

## 4. Architecture

### 4.1 Flow

```
HOST (WSL2 or native Linux)                            SANDBOX "dev" (microVM)
~/devenv  (git clone, owner-controlled; not mounted)
├── sbxenv.yaml, kits/devenv, bin/, …
└── dev/  (workspace, gitignored)       ──rw mount──►  /home/<u>/devenv/dev
keyring (Secret Service): this host's Infisical login (sbx-host)
Infisical: CLAUDE_CODE_OAUTH_TOKEN, GITHUB_GEJ_MACHINE_PAT
  (sbx runs `devenv secret-get NAME` on the host and keeps the value in
   sandboxd's memory; the proxy injects it; the sandbox sees placeholders)

cd ~/devenv && sbx env run
  1. host: lifecycle.initialize → bin/devenv host-prepare
        (unlock the keyring if locked, via a pop-up window; doctor-lite:
         keyring entries, both secrets fetch, github secret is gej-machine,
         checkout location; create dev/; Claude setup-token → custom secret)
  2. sbx creates the sandbox (if absent) with kit ./kits/devenv (extends claude)
       setup.install  → git clone devenv@ref → ~/fm-projects/devenv
                        → provision.sh --sbx   (as root, then drops to agent)
       setup.startup  → devenv start           (every start, as agent)
  3. sbx attaches the terminal to the entrypoint → devenv-entry ($DEVENV_ENTRY)
        herdr  → ensure herdr server + "firstmate" workspace; when it creates one:
                 Firstmate fork sync + fm-update, then a pane running
                 `claude --dangerously-skip-permissions --effort xhigh` in $FM_HOME → attach
        claude → exec claude --dangerously-skip-permissions (cwd: workspace)
        shell  → exec bash -l
```

### 4.2 Where things live

| Thing | Location | Survives `sbx rm`? | Travels between machines? |
|---|---|---|---|
| devenv repo (host) | `~/devenv`, never mounted | yes (host) | yes (git) |
| devenv (sandbox) | `~/fm-projects/devenv` (sandbox disk), cloned at create | no (cloned again) | yes (git) |
| Secrets | Infisical (the agent project) | yes | yes (every host reads the same project) |
| This host's Infisical login | the host's keyring (Secret Service), service `devenv-infisical` | yes (host) | no: one client secret per machine (`devenv secrets-init`) |
| Firstmate home (clone + `config/ data/ state/`) | `$WORKSPACE_DIR/firstmate` = `~/devenv/dev/firstmate` | yes | no |
| Claude memory | `$WORKSPACE_DIR/.devenv-state/claude-memory/<slug>/`, linked from `~/.claude/projects/<slug>/memory` | yes | no |
| Firstmate project clones | `$HOME/fm-projects` (sandbox disk) | no | no |
| treehouse worktrees | `~/.treehouse` (sandbox disk) | no | no |
| herdr sessions, config | `~/.config/herdr` (config written by `devenv start`) | no (config re-created) | n/a |
| Claude transcripts, todos | `~/.claude/*` volumes | no | no |
| Warnings cache, logs | `~/.cache/devenv/` | no | n/a |
| Tailscale (host) | the `tailscale` package; tailscaled keeps its own state (the machine's key) in `/var/lib/tailscale` | yes (host) | no: each machine signs in once (§6.14) |
| adb (platform-tools) | `~/.local/share/android-sdk` (sandbox disk; `ANDROID_HOME`) | no (installed again at create) | n/a |
| Android emulator image and SDK volume | the host's Docker Engine (`devenv-android-emulator:*`, `devenv-android-sdk-*`) | yes (host) | no |

---

## 5. Repository layout

```
devenv/
├── README.md                     # quick start, layout, operating rules, commands, troubleshooting
├── AGENTS.md, CLAUDE.md          # instructions for agents working on devenv (CLAUDE.md imports AGENTS.md)
├── docs/
│   ├── SPEC.md                   # this document
│   ├── HANDOFF.md                # decisions since the original spec, status, open work, traps
│   ├── SECRETS.md                # the Infisical secrets manager (design and as built)
│   └── HOST-VERIFY.md            # host-side verification checklist (the owner runs it)
├── sbxenv.yaml                   # sbx layer: agent kit, workspace ./dev, env, secrets, bindings, lifecycle
├── dev/                          # the sandbox workspace (gitignored; created by host-prepare)
├── kits/
│   └── devenv/spec.yaml          # v2 kit, kind: sandbox, extends: claude; clones devenv; entrypoint devenv-entry
├── devenv.conf                   # non-secret settings (§6.1)
├── versions.env                  # every pinned version + sha256 (§6.2)
├── provision.sh                  # portable installer: --sbx | --plain
├── bin/
│   ├── devenv                    # CLI: start | entry | check | doctor | bump | test | host-prepare | secrets-init | secret-get | tailscale-setup | emulator
│   └── devenv-entry              # entrypoint shim → `devenv entry`
├── lib/                          # sourced helpers (common, tools, android, claude, herdr, firstmate, secrets, tailscale); lib/cmd/ one file per subcommand
├── android/
│   └── emulator/                 # the host emulator's image (§6.15): Dockerfile, launch.sh (its entrypoint)
├── agents/
│   └── claude/
│       ├── statusline-command.sh # VERBATIM copy of the owner's script (Appendix A.1)
│       ├── statusline.sh         # wrapper: original output + optional warnings marker
│       ├── settings.overlay.json # merged into ~/.claude/settings.json at every start
│       ├── hooks/memory-link.sh  # SessionStart hook: memory symlinks (§6.11)
│       └── CLAUDE.md             # sandbox environment notes (source for ~/.claude/CLAUDE.md)
├── firstmate/
│   └── config/                   # starting copy for $FM_HOME/config/: backend, crew-harness, claude-permission-mode
├── herdr/
│   ├── config.toml               # onboarding off, update/manifest checks off
│   └── agent-detection/claude.toml  # herdr's published Claude rules (a05c403), pinned by sha256
├── skills/
│   ├── grill-me/SKILL.md         # VERBATIM (Appendix A.3)
│   └── grilling/SKILL.md         # VERBATIM (Appendix A.4)
└── tests/
    ├── statusline-identity.sh    # byte-identical check (fixtures in tests/fixtures/)
    ├── secrets.sh, fakes/        # secret-get, secrets-init, doctor, host-prepare against fake secret-tool/busctl/curl/sbx
    ├── container-smoke.sh, container-inner.sh   # provision.sh --plain in ubuntu containers
    ├── sbx-sim.sh, sbx-sim-inner.sh             # the kit's install/startup in a sandbox-like container
    ├── keyring.sh, keyring-inner.sh             # the keyring code against a real gnome-keyring in a container
    ├── tailscale.sh                             # tailscale-setup and doctor's Tailscale checks against fakes
    ├── emulator.sh                              # devenv emulator against fake docker/adb/sbx and a fake adbd
    └── emulator-image.sh                        # the emulator's real image and SDK volume (opt-in, heavy)
```

All scripts are bash with `set -euo pipefail`, must pass shellcheck, and must be **safe to run repeatedly**.

---

## 6. Behavior specs

### 6.1 `devenv.conf` (sourced by bash; non-secret)
```sh
SANDBOX_NAME=dev
BOT_LOGIN=gej-machine
BOT_EMAIL=318032932+gej-machine@users.noreply.github.com
CLAUDE_EFFORT_DEFAULT=high            # global default, inherited by workers
FIRSTMATE_EFFORT=xhigh                # first mate only, via `claude --effort`
CLAUDE_EFFORT_MODELS="claude-opus-5-5"   # models that get the default (D11)
DEVENV_STATUSLINE_WARNINGS=on         # on|off — the D19 marker in the status line
WARN_DAYS=14                          # expiry warning threshold
ANTHROPIC_TOKEN_EXPIRES=              # YYYY-MM-DD, optional; checked only when set
CLAUDE_AUTH=token                     # token (D8) | login
INFISICAL_DOMAIN=https://app.infisical.com   # the Infisical instance (D7)
INFISICAL_ENV=dev                     # environment slug
INFISICAL_PATH=/                      # folder
SECRET_GITHUB=GITHUB_GEJ_MACHINE_PAT  # Infisical names; the only ones secret-get fetches
SECRET_CLAUDE=CLAUDE_CODE_OAUTH_TOKEN
SECRET_REFRESH=55m                    # sbx's --refresh for every Infisical secret: a duration or on-demand
SECRET_REFRESH_CLAUDE=                # per-secret override; empty = SECRET_REFRESH
SECRET_REFRESH_GITHUB=                # per-secret override; empty = SECRET_REFRESH
FIRSTMATE_REPO=https://github.com/digigrant/firstmate
FIRSTMATE_UPSTREAM=https://github.com/kunchenguid/firstmate
FIRSTMATE_AUTO_UPDATE=on              # on|off (D30)
FM_PROJECTS_DIR='$HOME/fm-projects'   # expanded at runtime; the sandbox's devenv clone is <this>/devenv
PLAIN_WORKSPACE_DIR='$HOME/dev'       # plain mode only: holds Firstmate's home and state
ANDROID_EMULATOR_PORT=15555           # the host emulator's adb port on 127.0.0.1 (D34); the policy rule is localhost:<this>
ANDROID_EMULATOR_MEMORY=4096          # its guest RAM in MB; 4096 is the least the API 36 image boots with
ANDROID_EMULATOR_CORES=4              # its guest CPU cores
```
A few values can be overridden from the environment for one run (`WARN_DAYS`, `DEVENV_STATUSLINE_WARNINGS`, `ANTHROPIC_TOKEN_EXPIRES`, `CLAUDE_AUTH`, `FIRSTMATE_REPO`, `FIRSTMATE_AUTO_UPDATE`, `PLAIN_WORKSPACE_DIR`, `SECRET_REFRESH`, `SECRET_REFRESH_CLAUDE`, `SECRET_REFRESH_GITHUB`, `ANDROID_EMULATOR_PORT`, `ANDROID_EMULATOR_MEMORY`, `ANDROID_EMULATOR_CORES`).

The refresh settings take exactly what sbx's `--refresh` takes (checked against sbx 0.45.1): `on-demand`, or a Go duration such as `55m`, `10m`, `1h30m` or `90s`. `host-prepare` and host `doctor` reject anything else with the setting's name, before touching the keyring, Infisical or sbx. `SECRET_REFRESH` must not be empty.

The Infisical project ID, client ID and client secret are **not** settings: they live in the host's keyring (§6.9), never in the repo. `DEVENV_KEYRING_SERVICE` (default `devenv-infisical`) overrides the keyring entries' `service` attribute for one run, so a check can simulate missing entries without touching the real ones.

### 6.2 `versions.env`
Shell-sourceable `KEY=value` lines, one tool per block. Architecture-specific checksums use `_X86_64` and `_AARCH64` suffixes:
- `HERDR_VERSION`, `HERDR_SHA256_*`;
- `HERDR_CLAUDE_MANIFEST_COMMIT`, `_VERSION`, `_SHA256`, and `HERDR_CLAUDE_MANIFEST_HERDR` (the herdr version the override was tested with);
- `TREEHOUSE_VERSION`, `TREEHOUSE_SHA256_*`; `NO_MISTAKES_VERSION`, `NO_MISTAKES_SHA256_*`;
- `NPM_GH_AXI`, `NPM_CHROME_DEVTOOLS_AXI`, `NPM_TASKS_AXI`, `NPM_QUOTA_AXI`;
- `NODE_MIN_VERSION` (22.19.0), `NODE_VERSION` + `NODE_SHA256_*` (plain mode installs it only if node is missing or older);
- Android, from Google's SDK repository (`dl.google.com/android/repository`, which publishes only SHA-1s; the sha256s are devenv's, computed by `devenv bump`, which also checks Google's SHA-1): `ANDROID_PLATFORM_TOOLS_VERSION` + `_SHA256` (adb, x86_64 Linux only); for the host emulator `ANDROID_EMULATOR_VERSION`, `_BUILD`, `_SHA256`, the system image `ANDROID_SYSTEM_IMAGE_API`, `_TAG`, `_REVISION`, `_ZIP`, `_SHA256`, and `ANDROID_EMULATOR_BASE_IMAGE` (ubuntu, pinned by digest);
- `TEST_SHELLCHECK_IMAGE` (pinned by digest).

Every download must be verified against its sha256 before installing. **No `curl | sh`.** The single documented exception is installing Claude Code in plain mode when it's missing (§6.3), because it updates itself anyway. apt packages aren't pinned: apt verifies them against their repository's key, `gh`'s key is GitHub's keyring, fetched over HTTPS from `cli.github.com` as GitHub documents (§6.3 step 1), and on the host Tailscale's key comes over HTTPS from `pkgs.tailscale.com` as Tailscale documents (§6.14).

### 6.3 `provision.sh [--sbx|--plain] [--yes] [--git-identity bot|skip] [--skip-claude-install]`
The mode is auto-detected when no flag is given: `--sbx` if `IS_SANDBOX=1` or `SANDBOX_NAME` is set, otherwise `--plain`. The git identity defaults to `bot` in sbx mode and `skip` in plain mode. Every step is idempotent: a second run changes nothing and exits 0. devenv runs from the checkout that holds `provision.sh` (in sbx mode, the sandbox's clone).

1. **System packages.** Install via apt what's missing: `git curl jq ca-certificates tar unzip python3`. **Never install tmux.** Use sudo only when needed. Then, in both modes, install `gh` from GitHub's own apt repository, set up as GitHub documents for Debian/Ubuntu: the keyring `https://cli.github.com/packages/githubcli-archive-keyring.gpg` at `/etc/apt/keyrings/githubcli-archive-keyring.gpg` and the source `/etc/apt/sources.list.d/github-cli.list` (`deb [arch=… signed-by=<that keyring>] https://cli.github.com/packages stable main`). When the keyring or source differs, or the installed `gh` isn't apt's candidate from that repository, confirm (unless `--yes`), write them, `apt-get update` and `apt-get install gh`. This installs GitHub's current release, and in sbx mode replaces the image's older Ubuntu `gh` (2.46, which lacks `gh api --slurp`). `gh` isn't pinned. A failed download or apt run warns and leaves `gh` as it is.
2. **Node.** Require node ≥ `NODE_MIN_VERSION`. In plain mode, install the pinned Node tarball if node is missing or older. In sbx mode it's preinstalled; just check it.
3. **Pinned binaries.** Put `herdr`, `treehouse` and `no-mistakes` in `~/.local/bin`. Pick the asset for the architecture, download from GitHub Releases, verify the sha256, and install atomically. Skip any tool whose `--version` already matches.
3b. **adb.** On x86_64, Google's platform-tools at `ANDROID_PLATFORM_TOOLS_VERSION` (sha256-verified) in `~/.local/share/android-sdk/platform-tools`, with `adb` linked into `~/.local/bin`. Skipped when its `adb --version` matches; on other architectures skipped with a note (Google publishes platform-tools for x86_64 Linux only).
4. **npm globals.** Install the pinned versions globally into the existing npm global prefix (plain mode: a user prefix under `~/.local` if that isn't writable). **Do not install a browser.** (The tools' `setup hooks` commands run in step 10.)
5. **Claude Code.** In sbx mode, it's preinstalled; leave it. In plain mode, if it's missing, download the official installer to a file and run it (the documented exception; logs a notice).
6. **Environment.** Write one managed block of exports, idempotently, to `/etc/sandbox-persistent.sh` (sbx) or `~/.config/devenv/env.sh` sourced from `~/.bashrc` (plain): `DEVENV_DIR` (this checkout), `FM_HOME`, `FM_PROJECTS_OVERRIDE`, `DEVENV_STATE_DIR`, `NO_MISTAKES_TELEMETRY=off` (no-mistakes sends no telemetry), `NPM_CONFIG_PREFIX` when set, `ANDROID_HOME` (x86_64: `~/.local/share/android-sdk` unless already set), and PATH additions for `~/.local/bin` and `$DEVENV_DIR/bin`. Guard the block with markers (`# >>> devenv >>>` / `# <<< devenv <<<`) and **never include completion scripts**. In sbx mode also install `/usr/local/bin/devenv-entry` with this checkout baked in.
7. **Git identity.** With `--git-identity bot`, set `git config --global user.name "$BOT_LOGIN"` and `user.email "$BOT_EMAIL"`.
8. **Firstmate.** If `$FM_HOME` doesn't exist (or is empty): `git clone $FIRSTMATE_REPO "$FM_HOME"` (the fork's `main`). A failed clone warns instead of failing the create. If it exists: **don't touch the code** (updates happen at first-mate start, D30). Then copy each file from `devenv/firstmate/config/` into `$FM_HOME/config/` **only if it is absent there**.
9. **herdr config.** Install `herdr/config.toml` to `~/.config/herdr/config.toml` (keeping a differing user copy as `.bak`) and the detection override to `~/.config/herdr/agent-detection/claude.toml` (sha256-checked).
10. **Claude user config.** See §6.4; link the skills (§6.10).
11. **Claude memory persistence.** See §6.11.
12. Finish with `devenv check` and print a summary.

In sbx mode the kit's `setup.install` (as root) clones devenv (D31) and runs `provision.sh --sbx --yes` from the clone. `provision.sh` does the system steps as root (packages, the env block, the entrypoint shim), then re-runs itself as the agent user (uid 1000, `sudo -u agent -H` with the proxy variables preserved) for the rest. Files are written in place so existing owners and modes stay (e.g. `/etc/sandbox-persistent.sh` stays agent-owned). Anything that must be re-applied after `sbx`'s own rewrites belongs in `devenv start` (§6.5).

### 6.4 Claude settings, status line, `CLAUDE.md`
- **Merging `settings.overlay.json`.** Deep-merge it (jq) into `~/.claude/settings.json`: objects merge, arrays gain missing elements, scalars take the overlay's value; keys `sbx` sets are preserved. devenv's own hook entries (`~/.claude/hooks/devenv-*`) are replaced, not duplicated. The overlay sets:
  - `statusLine`: `{"type":"command","command":"bash \"$HOME/.claude/statusline.sh\""}`;
  - a `SessionStart` hook running `~/.claude/hooks/devenv-memory-link.sh --hook` (§6.11).
  
  The merge also sets `modelSettings.<model>.effortLevel = CLAUDE_EFFORT_DEFAULT` for each model in `CLAUDE_EFFORT_MODELS` (D11).
- **Integrations.** `herdr integration install claude`, `gh-axi setup hooks` and `chrome-devtools-axi setup hooks` rewrite `settings.json`, so they are re-run before the merge rather than their output copied. Everything is serialized with a lock, because `devenv start` (detached) and `devenv entry` may run it at the same time.
- **Status line files.** Install `agents/claude/statusline-command.sh` → `~/.claude/statusline-command.sh` **byte-for-byte** (verify sha256 `dc324500a5e54bc7905816cd92039c6519e4bcd3303d40a023e0686cde7e27c4`), and `agents/claude/statusline.sh` → `~/.claude/statusline.sh`.
- **`statusline.sh` behavior:**
  - With no warnings, exec the original with the untouched stdin, so the output is **exactly** the original's bytes.
  - If `DEVENV_STATUSLINE_WARNINGS=on` and `~/.cache/devenv/warnings` isn't empty, append `$'\033[2m | \033[0m'$'\033[31m'"⚠ devenv:$N"$'\033[0m'`, where N is the number of warning lines.
  - If the cache is older than 6 hours, start `devenv check --quiet` in the background, detached and non-blocking. The status line never waits on the network.
- **`~/.claude/CLAUDE.md`** is generated at every start from `agents/claude/CLAUDE.md` and stays short. It holds:
  - one line that imports the `sbx` runtime guidance if it exists: `@<dirname "$WORKSPACE_DIR">/CLAUDE.md` (workers in `~/.treehouse` otherwise wouldn't see it). Sessions under the workspace's parent may load it twice; that's accepted;
  - the notes: GitHub acts as `gej-machine`; Firstmate's `AGENTS.md` governs the git workflow and merges; project clones and worktrees are on sandbox disk and are lost on `sbx rm`, so push work; never add completion scripts to `/etc/sandbox-persistent.sh`; the environment runs from the devenv clone in `$DEVENV_DIR`, so change devenv only in a worktree on a branch.

### 6.5 `devenv start` (kit `setup.startup`; runs as `agent` at every start)
Idempotent and fast (a few seconds, apart from network checks, which have timeouts). It never fails the startup dispatcher; problems are warnings (log: `~/.cache/devenv/start.log`).
1. **Wait (bounded, 30 s)** until the built-in claude kit's startup commands have logged ok/fail in the current dispatcher run (`/var/log/sbx-kit-startup.log`), then re-apply §6.4: files, `CLAUDE.md`, integrations, the settings merge.
2. Make sure the herdr config and detection override are in place (a running server reloads what changed).
3. Claude memory links (§6.11).
4. Skill links (§6.10).
5. `devenv check --quiet`, which writes the warnings cache.

### 6.6 `devenv entry` / `bin/devenv-entry` (the sandbox entrypoint)
Arguments are ignored (the parent kit's flags may be passed to the entrypoint). It re-applies §6.4 first (in case anything rewrote `settings.json` after `devenv start`), prints the cached warnings in yellow, then reads `DEVENV_ENTRY` (default `herdr`):
- **`herdr`:**
  1. Make sure the herdr server is running (started detached, so it outlives the terminal).
  2. If no workspace labeled `firstmate` exists: run the automatic Firstmate update (D30: fork sync, then `bin/fm-update.sh`), create one with `herdr workspace create --cwd "$FM_HOME" --label firstmate --focus`, and run `claude --dangerously-skip-permissions --effort "$FIRSTMATE_EFFORT"` in its root pane with `herdr pane run`. Serialized with a lock. `HERDR_PROCESS_DETECTION` isn't needed.
  3. `exec herdr` to attach.

  Running it again **re-attaches without making a second first-mate pane**. Detach with `ctrl+b q`.
- **`claude`:** `cd "$WORKSPACE_DIR" && exec claude --dangerously-skip-permissions`.
- **`shell`:** `exec bash -l`.
- **Anything else, or any failure before handing over:** print why, then start a login shell.

### 6.7 `devenv check [--quiet]` (inside the sandbox, or in plain mode)
Writes one warning per line to `~/.cache/devenv/warnings`, and an empty file when all is well. Without `--quiet` it also prints them, plus notes. Always exits 0. Checks:
1. **Firstmate.** Warn when `$FM_HOME` has commits its fork's `main` (as last fetched) doesn't; note when it is merely behind. Warn when the last automatic sync or update failed, stopped, or skipped a dirty/diverged clone; note otherwise. Warn when the clone's `origin` isn't `FIRSTMATE_REPO`.
2. **devenv clone.** Note which branch and commit devenv runs from; in sbx mode, warn when that clone has uncommitted changes.
3. **Tool versions.** `herdr`, `treehouse`, `no-mistakes`, the four npm packages and (x86_64) `adb` against `versions.env`; `node` against the minimum.
4. **herdr detection override.** Warn when it isn't installed, or when `HERDR_VERSION` differs from the herdr version it was tested with.
5. **GitHub token.** Read the `github-authentication-token-expiration` header from `https://api.github.com/user` (5-second timeout). Warn within `WARN_DAYS` or on HTTP 401; note "no expiry" when the header is absent.
6. **Anthropic token.** Only when `ANTHROPIC_TOKEN_EXPIRES` is set: warn within `WARN_DAYS`.
7. **Firstmate config drift.** A file in `devenv/firstmate/config/` whose contents differ from `$FM_HOME/config/`.

### 6.8 `devenv bump`
Operates on a writable devenv checkout: `--repo PATH`, defaulting to the checkout containing the script. In the sandbox, bump in a worktree of the devenv clone (rule 3), not in the clone itself. It edits `versions.env` and prints the diff; it never commits or pushes.
- `devenv bump herdr <version>`: fetches the release asset digests from the GitHub API and updates the version and both sha256 values. **Warns loudly** if `<version>` isn't listed in the verified herdr versions in `$FM_HOME/docs/herdr-backend.md`.
- `devenv bump herdr-manifest <commit|latest>`: the detection override from herdr's repo, with its sha256.
- `devenv bump treehouse|no-mistakes <version|latest>`, `devenv bump npm <pkg> <version|latest>`, `devenv bump node <version|latest-lts>`.
- Android (§6.15), from Google's repository index (stable channel), downloading each file to check Google's SHA-1 and compute the sha256: `devenv bump platform-tools <version|latest>`, `devenv bump android-emulator <build|latest>`, `devenv bump android-system-image <api> [tag]` (x86_64; the tag defaults to the pinned one), and `devenv bump android-base-image [image:tag]` (the digest, from `docker buildx imagetools inspect`).
- `devenv bump --list`: a table of pinned vs. latest versions (and upstream Firstmate vs. the fork, and the Android pins). Read-only.

### 6.9 Secrets, `sbxenv.yaml` and `host-prepare`
```yaml
schemaVersion: "1"
name: dev
agent: devenv                         # the sandbox kit below (extends claude)
kits:
  - ./kits/devenv                     # kit args: repo, ref (default main)
workspace: ./dev                      # beside this file (D2)
env:
  DEVENV_ENTRY: herdr                 # herdr | claude | shell (applies on next `sbx env run`)
bindings:
  github:
    apiKey:
      domains: [api.github.com, github.com]
sandboxOptions:
  skills: "off"                       # skills are linked instead (D21)
  # memory: 12g                       # knob; default = 50% of host
lifecycle:
  initialize:
    - name: devenv host-prepare
      command: ./bin/devenv host-prepare
      workdir: ${{ env.fileDir }}
      timeout: 5m
```
There is no `secrets:` block: `host-prepare` gives the sandbox both secrets from Infisical, each with its refresh from `devenv.conf` (§6.1), which this file can't read. `bindings.github` still approves the proxy injecting the `github` secret. There is no `anthropic` secret (D8). sbx stores each command's text in plain text (§2.2), so every `--command` holds only a path and a secret name. The details are [SECRETS.md](SECRETS.md) §6; in short:

**The keyring.** Three `secret-tool` entries with the attributes `service devenv-infisical key project-id|client-id|client-secret`, written with `secret-tool store` (value on stdin) and read with `secret-tool lookup`. Whether they exist and whether the keyring is locked is asked of the Secret Service's `SearchItems` over D-Bus (`busctl --user`), which loads no secret and never opens a window. If `DBUS_SESSION_BUS_ADDRESS` is unset, it defaults to `unix:path=$XDG_RUNTIME_DIR/bus`.

**`devenv secret-get NAME`** (host, non-interactive; what sbx runs): accepts only `$SECRET_GITHUB` and `$SECRET_CLAUDE`; reads the three entries into variables; logs in to `$INFISICAL_DOMAIN` (`POST /api/v1/auth/universal-auth/login`), then reads the one secret (`GET /api/v4/secrets/NAME` with `projectId`, `environment=$INFISICAL_ENV`, `secretPath=$INFISICAL_PATH`), with `curl`, the request body and the `Authorization` header on stdin, and `--max-time` on each request; prints the value and a newline on stdout and nothing else. Every fetch logs in afresh and discards its 5-minute access token. It writes no file and puts no secret on a command line. It never prompts: a locked keyring, a missing entry, or any HTTP error exits non-zero with one line on stderr (e.g. `devenv: error: keyring locked; run sbx env run (host-prepare unlocks it)`).

**`devenv secrets-init`** (host, interactive, safe to re-run): refuses in a sandbox or without a terminal; checks `secret-tool`, `busctl`, `jq`, `curl` and that a Secret Service answers; unlocks the keyring if needed; prompts with echo off for the project ID, client ID and client secret (Enter keeps a stored one) and pipes each into `secret-tool store`. On a machine with no keyring yet, the first store makes the Secret Service open a window asking for a new keyring password. Then it test-fetches both secrets and prints only name, length and shape (`GITHUB_GEJ_MACHINE_PAT: ok (40 chars, ghp_…)`), stopping at the first failure.

**`devenv host-prepare`** runs on the host before every run:
- when the keyring is locked (after every WSL restart), a `secret-tool lookup` makes the Secret Service open its unlock window (a pop-up under WSLg or on a desktop), and host-prepare waits up to 3 minutes (the hook's timeout is 5). The password never passes through devenv. With no display it stops with instructions; when the keyring is unlocked it does nothing;
- a light version of `doctor` that fails fast when a refresh setting (§6.1) isn't one sbx accepts, a keyring entry is missing, a fetch fails (it stops after the first failed fetch: 3 failed logins lock `sbx-host` for 5 minutes), the github secret isn't a GitHub token or isn't `$BOT_LOGIN` (checked with the token on curl's stdin), the setup-token doesn't look like `sk-ant-oat01-` (token mode), or the checkout overlaps a sandbox workspace other than its own `dev/` (§6.12). It warns while `~/.config/devenv/secrets/` (the old plain-text files) still exists. Values stay in variables and are never printed;
- creates `dev/` when it is missing;
- sets the sandbox's `github` service secret: `sbx secret set github --sandbox dev --command '<absolute checkout>/bin/devenv secret-get GITHUB_GEJ_MACHINE_PAT' --refresh <SECRET_REFRESH_GITHUB or SECRET_REFRESH>` (an update when it exists; sbx runs the command once to check it). It stops with sbx's error line when that fails;
- with `CLAUDE_AUTH=token`: reads the placeholder sbx already holds for `CLAUDE_CODE_OAUTH_TOKEN` in scope `dev` (`sbx secret ls --sandbox dev --json`), or makes a random `sbx-cs-devenv-<32 hex>` when there is none, and runs `sbx secret set-custom --sandbox dev --host api.anthropic.com --env CLAUDE_CODE_OAUTH_TOKEN --placeholder … --command '<absolute checkout>/bin/devenv secret-get CLAUDE_CODE_OAUTH_TOKEN' --refresh <SECRET_REFRESH_CLAUDE or SECRET_REFRESH>` (idempotent: the same placeholder is an update). sbx is the only record of the placeholder, so the sandbox's variable and sbx always agree and a run that only attaches keeps a running sandbox signed in. If `sbx secret ls` fails or its JSON has no `custom_secrets` list, it stops before `set-custom` and never deletes anything. It removes the old host file `~/.config/devenv/claude-oauth-placeholder` when present. With `login`, it removes that custom secret: `sbx secret rm --sandbox dev --host api.anthropic.com --env CLAUDE_CODE_OAUTH_TOKEN -f`.

None of these read or run anything from `dev/`, which the sandbox can write.

### 6.10 Skills
- `devenv start` and `provision.sh` link each `skills/<name>` of the running checkout into `~/.claude/skills/<name>` (in sbx mode, from the clone). Links to skills removed from the repo are dropped. A user's own skill that isn't a symlink is never replaced. If `~/.claude/skills` isn't writable (an sbx store mounted there), warn and skip.
- `doctor` fails when a skill isn't linked.
- **Acceptance:** both skills are listed and usable in a Claude session started in `$FM_HOME` **and** in a worker running in a `~/.treehouse` worktree (AC7).

### 6.11 Claude memory persistence
- **Goal:** memory Claude writes in any session survives `sbx rm` and a rebuild.
- **Storage:** `$WORKSPACE_DIR/.devenv-state/claude-memory/<slug>/`, where `<slug>` is Claude's project folder name under `~/.claude/projects/`.
- **How:** `devenv start` (`memory-link.sh --all`) moves any real `~/.claude/projects/*/memory` folder into the state folder, replaces it with a symlink, and links every existing state folder back in. A `SessionStart` hook (`--hook`) does the same for the current project, so memory is linked before it's written. A differing file is never overwritten (the incoming copy is kept beside it). The hook never fails a session and prints nothing on stdout.
- **Acceptance:** AC10.

### 6.12 `devenv doctor`
It detects where it's running and exits 1 when any check fails.
- **On the host:**
  - `sbx` installed; print its version (warn below 0.45); the daemon running; `sbx ls` works (taken as "logged in").
  - `/dev/kvm` accessible and the user in the `kvm` group.
  - A network policy has been set up (`sbx policy ls` isn't empty).
  - Secrets (§6.9), without ever prompting: the refresh settings are ones sbx accepts (§6.1); `secret-tool`, `busctl`, `jq` and `curl` are installed; the three keyring entries exist and the keyring is unlocked; `$SECRET_GITHUB` fetches, and GitHub accepts it as `$BOT_LOGIN` (the token goes to curl on stdin, never on a command line), with its expiry; with `CLAUDE_AUTH=token`, `$SECRET_CLAUDE` fetches and looks like `sk-ant-oat01-…`; the `ANTHROPIC_TOKEN_EXPIRES` note. Any of these failing is a FAIL. Warnings for the old plain-text files in `~/.config/devenv/secrets/` and a non-empty `~/.infisical/secrets-backup/` (SECRETS.md S13).
  - **Checkout location (hard failure):** no sandbox workspace (from `sbx ls --json`, plus `~/dev`) contains the checkout, and none lies inside it except the checkout's own `dev/`.
  - The checkout is clean, on `main`, and not behind `origin/main` (warn).
  - When `/proc/version` contains "microsoft", a note that this is WSL and Docker supports the Linux `sbx` there only "best-effort".
  - **Tailscale** (§6.14), never needing root and changing nothing, each failure with its fix: on WSL, systemd is the init (else the `/etc/wsl.conf` fix) and Tailscale isn't running on Windows (FAIL when it runs; a warning when it is installed but stopped, or when `sc.exe` doesn't answer); the `tailscale` package is installed (FAIL: run `devenv tailscale-setup`) from Tailscale's apt source (warn); tailscaled is active (FAIL: `sudo systemctl enable --now tailscaled`) and enabled at boot (warn); the machine is signed in (FAIL with `sudo tailscale up`, plus the pending sign-in link when there is one; also for `NeedsMachineAuth` and `Stopped`); a key expiring within `WARN_DAYS` (warn); MagicDNS and HTTPS certificates on for the tailnet (warn each, with the admin console's DNS page).
  - **Android emulator (optional, §6.15).** What isn't set up is a note, a started emulator that doesn't work is a FAIL, prerequisites that stop it are warnings, each with its fix: x86_64; Docker Engine installed (a note when not), answering, usable by the user, and not Docker Desktop; `/dev/kvm`; the image and SDK volume for the current pins; when both exist and it isn't running, the emulator's own `-accel-check` in a container with `/dev/kvm`; the container's state (running and booted with adb answering on `127.0.0.1:<port>`, still booting, lost its device, or stopped); `sbx policy check network --sandbox dev localhost:<port>` (a warning with the `sbx policy allow network` command when denied).
  - Print the D28 operating rule.
- **In the sandbox or plain mode:**
  - every tool is present at its pinned version; tmux is not installed;
  - `gh api user` → `$BOT_LOGIN`; `gh auth status` passes (Firstmate's bootstrap depends on it);
  - Claude is logged in (`claude auth status`), via `oauth_token` in token mode;
  - in sbx mode: `SBX_CRED_ANTHROPIC_MODE` isn't `apikey`; `CLAUDE_CODE_OAUTH_TOKEN` is the sbx placeholder (never a real token);
  - the herdr server responds, and its Claude detection comes from the local override;
  - `$FM_HOME` exists, and Firstmate's detect-only bootstrap reports no `MISSING`, `NEEDS_GH_AUTH` or `BACKEND_INVALID`;
  - the settings overlay and effort are applied, the status line checksum matches, the memory hook and skill links are in place;
  - `adb` at its pinned version (x86_64); whether the host's emulator answers (a note, since it is normally stopped), and if not, why (§6.15);
  - print the output of `devenv check`.

### 6.13 `devenv test [--image IMG]… [--no-containers] [--no-shellcheck] [--emulator-image]`
1. `tests/statusline-identity.sh`: feed fixture JSON into the original script and into the wrapper (empty warnings cache) and assert byte-identical output; the marker appears when the cache isn't empty and disappears with `DEVENV_STATUSLINE_WARNINGS=off`.
2. `tests/secrets.sh`: `secret-get`, `secrets-init` (on a pseudo-terminal), `doctor` and `host-prepare` with fake `secret-tool`, `busctl`, `curl` and `sbx` first on `PATH`, dummy values and a temporary `HOME` (SECRETS.md §6.9). It asserts that stdout is exactly the value, that no file under `HOME` or `TMPDIR` changes, that no dummy secret or identity detail appears in any command's arguments, that a locked keyring, missing entries and HTTP errors each fail with one stderr line (a locked keyring without calling `secret-tool`), that an unconfigured name is refused, and that a rejected login is tried only once.
   `tests/emulator.sh`: `devenv emulator` with fake `docker`, `adb` and `sbx` first on `PATH`, a stand-in KVM device, dummy SDK zips whose sha256s replace the pins in a copy of the tree, and a small adbd (python3) on `127.0.0.1`: start (image, SDK volume, the `docker run` flags, boot wait, the policy hint), a second start, status, the doctor section, stop, restart, the failures (taken port, a crash while booting, no KVM, no Docker access, Docker Desktop, bad settings, inside a sandbox), a new pin, clean; connect, run (`ANDROID_SERIAL`, exit status, the lock not inherited, a second run waiting), booting, authorization and nothing answering. Inside a Docker Sandbox it also asks the real proxy about `localhost:15555`.
3. `tests/tailscale.sh`: `tailscale-setup` and doctor's Tailscale checks with fake `tailscale`, `systemctl`, `sc.exe`, `apt-get`, `dpkg-query`, `sudo` and `curl` first on `PATH`, and `DEVENV_HOST_ROOT` standing a folder in for `/`. It covers a new Ubuntu and Debian machine (the key, the source, the apt and systemctl calls, exactly `sudo tailscale up`, no auth key, nothing written under `HOME`), a second run that changes nothing and runs no sudo, every stop before installing (no terminal, a sandbox, an unsupported release, a failed download, no systemd, Tailscale running on Windows), and each doctor result.
4. shellcheck on every script (installed shellcheck, or the pinned image).
5. For `ubuntu:24.04` and `ubuntu:26.04`: a container with the repo mounted read-only and a non-root user with sudo runs `provision.sh --plain --yes --git-identity skip --skip-claude-install`, then asserts the versions, a clean second run, and that `devenv check` exits 0 with no warnings.
6. `tests/sbx-sim.sh`: an `ubuntu:26.04` container laid out like a Docker Sandbox (uid-1000 `agent`, the workspace at `<home>/devenv/dev`, an agent-owned `/etc/sandbox-persistent.sh`) runs the kit's own install snippet as root, cloning devenv from a git copy of the working tree, then the startup snippet as the agent. It asserts the clone, the root-to-agent handoff, ownership, skill links, the hooks, the entrypoint, and a clean second install.
7. `tests/keyring.sh`: an `ubuntu:26.04` container with gnome-keyring, `secret-tool` and `busctl` (only Infisical, GitHub and sbx faked) runs `secrets-init`, then `secret-get` unlocked and locked, while `dbus-monitor` records the Secret Service calls: a locked keyring must fail with the one-line message using only `SearchItems` (no `Unlock` or `Prompt`), and host-prepare's unlock step must call `Unlock` and `Prompt`, then stop with instructions when no display is available.
8. Only with `--emulator-image`: `tests/emulator-image.sh` runs `devenv emulator start` in host mode with the real Docker (downloads about 2.2 GB, about 6 GB of Docker disk): the image builds, the SDK volume unpacks and is complete, and the emulator finds its system image and boots (with KVM) or stops at its hardware checks (without); then `clean`. It refuses to run beside an existing devenv emulator.

`--no-containers` runs only 1 to 4. **Proxy note:** inside the sandbox, test containers use `--network host` and get `HTTPS_PROXY`, `HTTP_PROXY`, `NO_PROXY` and the proxy CA (`PROXY_CA_CERT_B64` → `update-ca-certificates`), **only when those variables are present**.


### 6.14 Tailscale on the host: `devenv tailscale-setup` (D33)
Host only (`lib/cmd/tailscale-setup.sh`, helpers in `lib/tailscale.sh`), interactive (it refuses in a sandbox or without a terminal), once per machine and safe to run again. It needs `curl`, `jq`, `dpkg-query`, `apt-get` and `systemctl` (Ubuntu or Debian with systemd); root work goes through `sudo`.
1. **Can tailscaled run here?** Stop with the fix when systemd isn't the init (`/run/systemd/system` is missing). On WSL the fix depends on `/etc/wsl.conf`: append `[boot]` `systemd=true` when it has no `[boot]`, add `systemd=true` under an existing `[boot]`, or, when it already says `systemd=true`, restart WSL (`wsl.exe --shutdown`) or update it. On WSL also ask Windows (`sc.exe query Tailscale`, through interop): stop while Tailscale runs there, warn when it is installed but stopped or when `sc.exe` doesn't answer.
2. **Install**, as Tailscale documents (§2.7): the release is `ubuntu <UBUNTU_CODENAME>`, else `ubuntu|debian <VERSION_CODENAME>` from `/etc/os-release`; any other system stops with a pointer to Tailscale's Linux page. Download `<os>/<codename>.noarmor.gpg` from `https://pkgs.tailscale.com/stable` to a temp file (a failed download stops before anything is written). When the key at `/usr/share/keyrings/tailscale-archive-keyring.gpg` is the same, `/etc/apt/sources.list.d/tailscale.list` holds exactly Tailscale's source for the release, and both `tailscale` and `tailscale-archive-keyring` are installed, do nothing more ("already installed"). Otherwise write the key and the source (`write_if_changed`, mode 0644), `apt-get update`, and `apt-get install -y tailscale tailscale-archive-keyring`; a failure stops with the fix. Not pinned: apt verifies the packages against Tailscale's key, like `gh` (§6.2), and later versions arrive with normal apt upgrades.
3. **Daemon:** when tailscaled isn't active or isn't enabled, `sudo systemctl enable --now tailscaled`.
4. **Sign-in:** with `BackendState` `NeedsLogin` or `NoState` (or `Stopped`, after `tailscale down`), say so and run `sudo tailscale up`, with no other arguments; it prints the sign-in link, and the owner opens it in a browser and signs in. Never an auth key; nothing is stored. `NeedsMachineAuth` stops with the admin console's Machines page.
5. **Report** from `tailscale status --json`: the machine's MagicDNS name, first address and tailnet, its key expiry (a warning within `WARN_DAYS`), and a warning with the admin console's DNS page for MagicDNS or HTTPS certificates while either is off.

A run with everything in place downloads the key to compare it and changes nothing: no sudo, no apt, no sign-in. host `doctor` reports the same state without root (§6.12). `host-prepare` doesn't look at Tailscale, so a machine without it still runs its sandbox. The files it reads and writes (`/etc/os-release`, `/etc/wsl.conf`, `/proc/version`, `/run/systemd/system`, the apt key and source) go through `host_path`, so `tests/tailscale.sh` can stand a folder in for `/` with `DEVENV_HOST_ROOT`.

### 6.15 `devenv emulator` (D34)
**On the host** (`start`, `stop`, `clean` refuse inside a sandbox):
- **`start`** needs x86_64, valid settings (§6.1), `/dev/kvm` and Docker Engine (not Docker Desktop, whose containers get no `/dev/kvm`); it stops at the first problem with its fix. Then:
  1. **Image** `devenv-android-emulator:<12 hex>`, tagged by a hash of `android/emulator/Dockerfile`, `launch.sh` and `ANDROID_EMULATOR_BASE_IMAGE`: built when missing, from a temporary context holding only those two files (`--label devenv.android-emulator=image`). It holds the emulator's runtime libraries, `socat`, `unzip` and `launch.sh` (under 0.5 GB). Older devenv emulator images are removed.
  2. **SDK volume** `devenv-android-sdk-api<api>-<12 hex>`, named by a hash of the SDK pins: when missing, or without `launch.sh`'s completion marker, download the emulator, the system image and platform-tools (about 2.2 GB) into `~/.cache/devenv/android-emulator`, verify each sha256 (a file that already matches is reused), and have the image unpack them into the volume (`launch.sh --unpack system-images/android-<api>/<tag>`, about 5 GB); then delete the downloads and remove older SDK volumes. Keeping the SDK out of the image leaves no multi-GB build context or build cache behind.
  3. **Container** `devenv-android-emulator`: `docker run -d --init --device /dev/kvm -p 127.0.0.1:<port>:6555 -v <volume>:/android/sdk -e EMULATOR_MEMORY -e EMULATOR_CORES`. No restart policy. A taken port is reported with the setting to change.
  4. Wait (up to 15 minutes) until Docker reports the container healthy, i.e. Android booted; if it stops, print its last log lines. Then check adb on `127.0.0.1:<port>` and the policy (`sbx policy check network --sandbox dev localhost:<port>`), printing the `sbx policy allow network localhost:<port>` command when it is denied, and how to use and stop it.
  An already running emulator is reused (with a warning when it runs an older image).
- **`launch.sh`** (the container's entrypoint, as root): writes a fresh AVD (x86_64, 1080×2400 at 420 dpi, software GPU, no audio, cameras or SD card), forwards the container's port 6555 to the emulator's loopback-only adb port 5557 with `socat` (6555 is outside the range adb scans for local emulators), and execs `emulator -avd devenv -ports 5556,5557 -no-window -no-audio -no-boot-anim -no-snapshot -wipe-data -no-metrics -skip-adb-auth -gpu swiftshader_indirect -accel on -memory … -cores …`. A background step waits for `sys.boot_completed`, turns animations off and writes the marker the health check reads (with `adb get-state` from inside the container).
- **`stop`** stops and removes the container (image and volume stay). **`clean`** also removes every devenv emulator image, SDK volume and the download cache.
- **`status`** prints the host report that `doctor` uses (§6.12) and exits 1 on a failure.

**In the sandbox or plain mode** (the emulator is at `host.docker.internal:<port>` from a sandbox, `127.0.0.1:<port>` otherwise):
- A probe opens a TCP connection and sends adb's `CNXN` message: `CNXN` back means adbd accepts the connection, `AUTH` that it wants key authorization, anything else that nothing answers. (A plain TCP connect proves nothing from a sandbox, whose proxy accepts every connection first, and `adb connect` then reports "failed to connect" after 10 seconds and leaves an offline entry.) When nothing answers from a sandbox, an HTTP request through the forward proxy tells a missing policy rule (403 "Blocked…", with the `sbx policy allow network localhost:<port>` fix) from an emulator that isn't running (`devenv emulator start` on the host).
- **`connect`**: probe, drop a stale offline entry, `adb connect`, wait for the device, require `sys.boot_completed`; prints only the serial on stdout.
- **`run -- CMD…`**: connect, take an exclusive `flock` on `${XDG_RUNTIME_DIR:-/tmp}/devenv-android-emulator.lock` (saying so when it waits), and run CMD with `ANDROID_SERIAL` set and the lock's descriptor closed for it (so a Gradle daemon doesn't keep the lock); exits with CMD's status.
- **`status`**: `adb`'s version and the probe, with the reason when nothing answers.

---

## 7. Verification items

**Who:** **A** = an agent, inside a sandbox. **H** = the owner, on the host, with commands in `docs/HOST-VERIFY.md`. Status as of 2026-09-26; host checks must be re-run with the current layout (HOST-VERIFY from step 0).

| ID | Who | Question | Status / answer |
|---|---|---|---|
| V1 | H | Does Claude sign in without `/login`? | The setup-token as the `anthropic` secret failed (API-key mode, 401). As a custom secret it works (host probe). To confirm in `dev`, also after a restart and a recreate. Fallback: `CLAUDE_AUTH=login`. |
| V2 | H | Can `agent:` name a local `kind: sandbox` kit extending claude, with entrypoint `devenv-entry`? What happens to the herdr server on detach? | `sbx env plan` accepted `agent: devenv` + `kits: [./kits/devenv]`, and `extends: claude` resolved. Detach/re-attach on the host is pending. Fallback: `agent: claude` + the kit as a mixin, `devenv entry` by hand. |
| V3 | A | Does herdr 0.8.0 detect Claude's states? | Yes, with the pinned detection override (D13); default detection, no `child-groups`. |
| V4 | H/A | How do the skills reach every session? | The sbx store isn't mounted for custom kits (confirmed on the host: the first mate saw none). Replaced by links (D21). Host check: HOST-VERIFY V4, AC7. |
| V5 | H | Do relative paths and the mounts come out as intended? | Relative paths resolved in the plan. The current layout's single `dev/` mount is HOST-VERIFY V5. |
| V6 | H | Does Claude memory survive `sbx rm` plus a rebuild? | Pending on the host (in-sandbox: memory lands in the state folder through the link). Fallback: a `lifecycle.preRemove` host hook. |
| V7 | H | Does the kit's clone and provisioning work in a real create? | Replaces "is the read-only mount present at install" (which passed with the first layout). Pending: HOST-VERIFY V7. |
| V8 | A | Which files do the tools' `setup hooks` modify? | Answered (§2.5); they are re-run in `devenv start`/`entry`. |
| V9 | A | Global default effort key? `$HOME` in `statusLine`? | Per-model only (D11); `$HOME` expands. |
| V10 | H/A | Does the claude kit rewrite `settings.json` after devenv's startup? | It writes it at install (create). `devenv start` waits for its startup commands and `devenv entry` re-merges. Restart check pending on the host. |
| V11 | H | Which extra domains does `balanced` block? | None for devenv's downloads (first host create). `herdr.dev` must stay blocked. |
| V12 | A/H | Does Firstmate's bootstrap pass in `dev`? | In-sandbox: nothing missing except the optional `PRESENTATION_UNAVAILABLE: lavish-axi`. Host check pending. |
| V13 | H | Do `devenv tailscale-setup` and doctor's Tailscale checks work on the WSL 2 PC and on the Linux laptop, and does Tailscale traffic from WSL work once Tailscale is off Windows? | Built and tested against fakes (`tests/tailscale.sh`); `pkgs.tailscale.com` is blocked in the sandbox, so the real install, sign-in and checks are pending on each host: HOST-VERIFY §10. |
| V14 | A/H | Can a sandbox drive an Android emulator on the host over adb (D34)? | In-sandbox: raw non-HTTP TCP passes the proxy to an allowed destination; `host.docker.internal:<port>` is refused until `localhost:<port>` is allowed; the real image builds, the SDK volume unpacks and the emulator gets to its hardware checks without KVM (`tests/emulator-image.sh`). Pending on the host (HOST-VERIFY §11): Android boots in the container under WSL2 and on native Linux, adb reaches it from the sandbox once the rule is added, and a test runs. |

---

## 8. Acceptance criteria

- [ ] **AC1** On a host that meets the prerequisites and has its Infisical login in the keyring (`devenv secrets-init`), `cd ~/devenv && sbx env run` creates a working `dev` sandbox with **no manual steps** (no `/login` in token mode).
- [ ] **AC2** You land in herdr, with a `firstmate` workspace whose pane runs Claude at xhigh in `$FM_HOME`. Firstmate uses the herdr backend and its bootstrap reports no missing tools and no `NEEDS_GH_AUTH`.
- [ ] **AC3** Running `sbx env run` again re-attaches without making a second first-mate pane.
- [ ] **AC4** `DEVENV_ENTRY=claude` and `DEVENV_ENTRY=shell` work after editing `sbxenv.yaml` and re-running, without recreating the sandbox.
- [ ] **AC5** The status line output is **byte-identical** to the original script's for fixture inputs when there are no warnings. A marker appears when warnings exist, and the `off` setting works. The script's sha256 is `dc324500…`.
- [ ] **AC6** After a restart **and** after a recreate, `~/.claude/settings.json` contains the status line and the global effort (`high`), and every key `sbx` requires is still there.
- [ ] **AC7** `grill-me` and `grilling` are available in Claude sessions in `$FM_HOME` and in a treehouse worktree.
- [ ] **AC8** `devenv check` catches: Firstmate with a commit its fork's `main` doesn't have; a tool version that doesn't match; token expiry (a large `WARN_DAYS`). Each warning shows at entry and in the status line.
- [ ] **AC9** `devenv bump` updates `versions.env` correctly for herdr (with its sha256 and the verified-version warning), the herdr detection override, treehouse, no-mistakes, the npm packages and Node.
- [ ] **AC10** After `sbx rm dev` and a rebuild, the Firstmate home (`config/`, `data/`, `state/`) and Claude memory are still there; project clones and worktrees are gone, and devenv is freshly cloned.
- [ ] **AC11** Commits made in the sandbox are authored by `gej-machine <318032932+gej-machine@users.noreply.github.com>`, and pushing and `gh pr create` work.
- [ ] **AC12** `devenv test` passes, including a second provisioning run that changes nothing.
- [ ] **AC13** Host `devenv doctor` passes, and **fails** if the checkout is inside a workspace, another workspace is inside the checkout, a keyring entry is missing (`DEVENV_KEYRING_SERVICE=devenv-missing`), or a secret can't be fetched.
- [ ] **AC14** The repo contains no secrets: `git grep -nE 'sk-ant-|ghp_|github_pat_|gho_[A-Za-z0-9]{20}'` finds nothing except placeholder docs and the dummy values in `tests/`. The Infisical project ID and client ID never enter the repo either (SECRETS.md A6).
- [ ] **AC15** No `herdr.dev` allowance; herdr's update and manifest checks are off; tmux is not installed.
- [ ] **AC16** Nothing in the repo hardcodes `/home/gejoy` or `/home/agent`, except in test fixtures, tests and docs.
- [ ] **AC17** On the WSL 2 PC (Tailscale off Windows) and on a native Linux host, `devenv tailscale-setup` installs Tailscale from Tailscale's apt repository and signs the machine in through one browser sign-in; a second run changes nothing and asks for no sudo; host `doctor`'s Tailscale lines all pass once MagicDNS and HTTPS certificates are on; and it FAILs with the fix when tailscaled is stopped (HOST-VERIFY §10).
- [ ] **AC18** On a host with Docker Engine and the policy rule, `devenv emulator start` boots Android, `devenv emulator run -- adb shell getprop ro.build.version.sdk` in the sandbox prints the pinned API level, and `devenv emulator stop` frees the memory.

---

## 9. Status and remaining plan

- **Done (A):** the repo, `docs/SPEC.md`, the verbatim files, `provision.sh`, `bin/devenv`, `lib/`, the kit, `sbxenv.yaml`, configs, README, HOST-VERIFY; V3, V8, V9 and the in-sandbox parts of the others; `devenv test` passes. Delivered as PR #1 (branch `initial-setup`); the restructure to the current layout is part of it.
- **Phase 3 — Host verification (H).** `docs/HOST-VERIFY.md` from step 0: remove the first-layout sandbox, pull, `sbx env run --kit-arg ref=initial-setup` (while the PR is open), then the V-checks and AC1–AC11. The owner pastes the output into the PR.
- **Phase 4 — Iterate (A).** Fix what the owner reports, on the same PR. Stop and ask if something fails and §7 has no answer.
- **Phase 5 — Switchover (H, with the owner's confirmation):**
  1. The owner merges the PR, then `git -C ~/devenv pull`; later creates no longer need `--kit-arg ref=…`.
  2. The owner removes the old sandbox: `sbx rm claude-dev`.
  3. Only after the owner confirms: remove the leftovers in `/home/gejoy/dev`: `firstmate/` and `.devenv-state/` (the first layout's), and `.claude/settings.json`, `.claude/statusline-command.sh`, `.claude/skills/` (the old sandbox's project-level files).

---

## 10. Security invariants (must always hold)

1. No secret values in the repo, in logs, or in files the sandbox can write. Inside the sandbox, only proxy placeholders exist.
2. The host's devenv checkout is never inside a folder a sandbox can write to, and the only sandbox-writable folder inside it is `dev/` (`doctor` and `host-prepare` enforce this).
3. Code that runs on the host (lifecycle hooks, secret `command:`s, `bin/devenv` host subcommands, the kit) comes only from the owner's host checkout, and never reads or runs anything from `dev/`.
4. Every download is pinned and checksum-verified. No `curl | sh`, except the Claude Code install in plain mode (§6.2). apt packages, including `gh` from GitHub's repository and, on the host, `tailscale` from Tailscale's, are verified by apt against their repository's key instead (§6.2).
5. No allowance for `herdr.dev`; herdr's automatic checks are off.
6. No completion scripts in `/etc/sandbox-persistent.sh`.
7. Firstmate's `yolo` stays off. Merges need the owner's explicit word (Firstmate rule 2).
8. The `github` secret is the `gej-machine` token only. Never the owner's personal token.
9. Nothing sensitive leaves the keyring. No secret value and no Infisical identity detail (project ID, client ID, client secret) appears in the repo, on a command line, in shell history or in a file. The only copy at rest on a host is its Secret Service entry.
10. Nothing from Infisical enters the sandbox: no value, token, certificate or CLI.
11. The machine identity `sbx-host` reads only the agent project, as Viewer.
12. Every `command:` and `--command` holds only a path and a secret name, because sbx stores command text in plain text (§2.2).
13. No Tailscale auth key, or any other Tailscale secret, in the repo, in `devenv.conf`, on a command line or in a file devenv writes. Each machine signs in interactively in a browser (D33).
14. The Android emulator's adb port (it skips adb authorization) is published on the host's `127.0.0.1` only, never on another interface, and its container gets `/dev/kvm` and nothing more privileged.

---

## 11. Future work (don't build now; noted in the README "Roadmap")

- Later secrets work ([SECRETS.md](SECRETS.md) §12): GitHub App tokens instead of the `gej-machine` PAT, SSH for git, and wiring Firstmate's typesafe dispatch (S10).
- A GitHub permission system for agents: rulesets or a bot bypass list, or a GitHub App with short-lived tokens through host-prepare's `github` secret (a `secret-get`-style command) and a short `SECRET_REFRESH_GITHUB`. Keeping agents off the fork's `main` would need the fork sync to run with the owner's credential.
- Worker effort and model profiles in Firstmate's `config/crew-dispatch.json`.
- A second worker harness (e.g. Codex), which needs `config/crew-harness` and its install.
- Bumping herdr past 0.8.0 once Firstmate verifies newer versions.
- v3 kits, once a v3 Claude workload is available to build on: a v3 kit can declare where Claude reads skills, so the sbx store could replace the links.
- An Android build toolchain in the sandbox (a JDK, `sdkmanager`, SDK packages), if phone-app projects don't bring their own; more than one emulator (API levels, concurrent runs).

---

## Appendix A — Files to preserve exactly

### A.1 `agents/claude/statusline-command.sh`
Source: `/home/gejoy/dev/.claude/statusline-command.sh`. sha256 `dc324500a5e54bc7905816cd92039c6519e4bcd3303d40a023e0686cde7e27c4`. The block below is for reference; the file in the repo is the byte-exact copy.

```bash
#!/bin/bash
# Claude Code status line: model | effort | current context | session token totals
input=$(cat)
j() { echo "$input" | jq -r "$1"; }

model=$(j '.model.display_name // "unknown"')
effort=$(j '.effort.level // empty')
size=$(j '.context_window.context_window_size // empty')
pct=$(j '.context_window.used_percentage // empty')
cur=$(j '(.context_window.current_usage // {}) | ((.input_tokens//0)+(.cache_creation_input_tokens//0)+(.cache_read_input_tokens//0))')
tin=$(j '.context_window.total_input_tokens // 0')
tout=$(j '.context_window.total_output_tokens // 0')

fmt() { awk -v n="${1:-0}" 'BEGIN{ if(n>=1e6) printf "%.1fM",n/1e6; else if(n>=1e3) printf "%.1fk",n/1e3; else printf "%d",n }'; }
sep=$'\033[2m | \033[0m'

out=$'\033[36m'"$model"$'\033[0m'
[ -n "$effort" ] && out+="$sep"$'\033[35m'"effort:$effort"$'\033[0m'
if [ -n "$size" ]; then
  ctx="ctx:$(fmt "$cur")/$(fmt "$size")"
  [ -n "$pct" ] && ctx+=" ($(printf '%.0f' "$pct")%)"
  out+="$sep"$'\033[33m'"$ctx"$'\033[0m'
fi
out+="$sep"$'\033[32m'"session: $(fmt "$tin") in / $(fmt "$tout") out"$'\033[0m'
printf '%s' "$out"
```

### A.2 The old sandbox's settings (for reference; not copied as-is)
Project-level `/home/gejoy/dev/.claude/settings.json` (sha256 `c49c8ac9…`), removed in Phase 5:
```json
{
  "statusLine": {
    "type": "command",
    "command": "bash /home/gejoy/dev/.claude/statusline-command.sh"
  }
}
```
User-level `~/.claude/settings.json` in `claude-dev` (partly written by `sbx`):
```json
{
  "permissions": { "defaultMode": "bypassPermissions" },
  "alwaysThinkingEnabled": true,
  "skipDangerousModePermissionPrompt": true,
  "themeId": 1,
  "bypassPermissionsModeAccepted": true,
  "modelSettings": { "claude-opus-5-5": { "effortLevel": "xhigh" } }
}
```

### A.3 `skills/grill-me/SKILL.md`
Source: `/home/gejoy/dev/.claude/skills/grill-me/SKILL.md`. sha256 `caaf8b8de1684f96e26b28f3c29189db5c89cce4b73e1c93d86164f66ef88637`.
```markdown
---
name: grill-me
description: A relentless interview to sharpen a plan or design.
disable-model-invocation: true
---

Call the Skill tool with "grilling".
```

### A.4 `skills/grilling/SKILL.md`
Source: `/home/gejoy/dev/.claude/skills/grilling/SKILL.md`. sha256 `10ff989e7498b23b5acb49d5048f11dcd906757d2f79c5cdf8a00001381296f2`. 1,987 bytes with nested code fences; the file in the repo is the byte-exact copy.
