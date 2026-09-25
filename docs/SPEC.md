# devenv — Implementation Spec

| | |
|---|---|
| **Status** | Approved design, ready for implementation |
| **Written** | 2026-09-25, from a design interview with the owner (GitHub: `digigrant`) |
| **Target repo** | `github.com/digigrant/devenv` (private or public; contains no secrets) |
| **Executor** | An autonomous coding agent (you) |
| **Researched against** | sbx v0.45.1, Claude Code 2.1.282, herdr 0.8.0, Firstmate `main` @ `dbe124d` |

---

## 0. Read this first (rules for the executing agent)

1. **The decisions in §3 are settled.** Don't reopen them or change the architecture. When a verification item in §7 fails, apply its documented fallback. If an item has no fallback, or the fallback also fails, **stop and ask the owner**.
2. **Git workflow.** Work on a branch (e.g. `initial-setup`) in `digigrant/devenv`, push as `gej-machine`, and **open a PR**. You are explicitly told to open a PR for this work. **Never merge.** The owner reviews and merges.
3. **You cannot run `sbx`.** It is a host-only CLI; the host is WSL2 on Windows, and a native Linux machine later. Build and test everything you can inside the sandbox (§9, Phase 1–2). For the rest, write exact host commands with expected output into `docs/HOST-VERIFY.md` and the PR description. The owner runs them and reports back.
4. **Sandbox shell rule.** Never add shell-completion scripts to `/etc/sandbox-persistent.sh`. It is sourced before every bash command, and completion scripts break the shell entirely.
5. **Don't touch the owner's live files** under `/home/gejoy/dev/.claude/` until Phase 5, and only after the owner confirms. They power the current sandbox.
6. **Commit this spec** into the repo as `docs/SPEC.md` in your first commit.
7. **Firstmate facts** below were taken at commit `dbe124d`. If Firstmate `main` has changed in ways that affect this spec (config file formats, required tools), follow the current Firstmate docs and note the difference in the PR.

---

## 1. Goal and scope

### Goal
One repo that rebuilds the owner's agent dev environment quickly and reproducibly:
- in a **Docker Sandbox** (`sbx`) on WSL2 today and on a native Linux machine later;
- and, through a portable layer, on a plain Debian/Ubuntu machine without `sbx`.

The environment runs **Firstmate** (an agent orchestrator) on the **herdr** backend (a terminal multiplexer for agents), with **Claude Code** as the agent. Rebuilding is **one host command**: `sbx env run` inside `~/devenv`.

### In scope
- Installing and configuring the tools (herdr, Firstmate, and Firstmate's helper tools), all pinned.
- The owner's Claude Code user settings, including the **status line, reproduced exactly as it is now**, plus effort defaults and skills.
- Host-side `sbx` wiring: secrets, network allowances, entry command, lifecycle hooks.
- Keeping chosen state across teardown: Firstmate's home and Claude's memory.
- Warnings for drift and expiry, commands to bump versions, a host "doctor" check, and a container smoke test.

### Out of scope (do not build)
- A GitHub permission system for agents. That is future work; Firstmate's merge rule covers it for now.
- A secrets manager. Keep secret sources swappable, one line each (§6.9).
- CI or GitHub Actions, Renovate, or auto-bump PRs.
- The Windows `sbx.exe` path. Only the Linux `sbx` (inside WSL or native) is supported.
- tmux, or any Firstmate backend other than herdr.
- Optional Firstmate features: Relay, the mail plane, typesafe dispatch, remote secondmates, lavish-axi, and a Chromium browser.
- Other agent harnesses such as Codex or OpenCode. Keep the worker harness a single setting, but only install Claude Code.
- The owner's `digigrant/claude-shared` repo, the owner's `digigrant/dotfiles` repo, and any older "VM pool" plans. **Do not use or reference them.**

---

## 2. Facts discovered during design

### 2.1 The current sandbox (`claude-dev`)
- Ubuntu 26.04.1, x86_64, kernel 7.0.12. User `agent` (uid 1000, groups `sudo` and `docker`). `HOME=/home/agent`.
- Hardware: 24 CPUs, 7.4 GiB RAM, and a 20 GB root disk with about 19 GB free.
- **Workspace mode is "direct".** The host folder `/home/gejoy/dev` (in WSL) is mounted over virtiofs at the **same path**, read-write. `WORKSPACE_DIR=/home/gejoy/dev`. Only that folder comes from the host.
- **The host's home folder differs per machine.** WSL uses `/home/gejoy`; the other Linux machine uses `/home/grant`. **Never hardcode a home path.**
- Preinstalled tools:
  - git 2.53, gh 2.46, Node v22.22.1, npm 9.2.0, python 3.14, uv 0.9.26, jq 1.8.1, curl, Docker 29.8.1 (an in-sandbox engine);
  - Claude Code 2.1.282, the native build in `~/.local/bin`, which auto-updates.
  - The npm global prefix is `/usr/local/share/npm-global` (its `bin` is on PATH).
  - **Not installed:** tmux, herdr, Firstmate or its tools.
- Environment and plumbing:
  - `/etc/sandbox-persistent.sh` is sourced into every shell (`BASH_ENV`, profile, bashrc) and is also `CLAUDE_ENV_FILE`.
  - All HTTP(S) goes through a proxy at `gateway.docker.internal:3128`. The proxy intercepts TLS; its CA is base64-encoded in `PROXY_CA_CERT_B64`.
  - Credentials are injected by the proxy. The sandbox only ever sees placeholders: `GH_TOKEN=gho_sbxproxymanaged…`, and `~/.claude/.credentials.json` holds `sk-ant-oat01-proxy-managed`.
  - A blocked request gets HTTP 403 with an explanation in the body. Example: `herdr.dev` is blocked by the default-deny policy.
- `~/.claude/{projects,sessions,todos,shell-snapshots,statsig}` are separate ext4 block volumes owned by the sandbox. `~/.claude/skills` is a read-only virtiofs mount of `sbx`'s shared skills store, which is currently empty.
- The startup hooks of the built-in `claude` kit are in `/etc/durable-startup.d/` (`001-startup-claude`, `manifest.json`, `run.sh`).
- `sbx` generates `/home/gejoy/CLAUDE.md` (runtime guidance) in the **parent folder of the workspace**, which is not host-mounted, plus `/home/gejoy/kits-agent-context/`.
- GitHub:
  - `gh api user` → `gej-machine` (id `318032932`), a classic token with the `repo` scope.
  - **The token expires `2026-10-25 08:31:48 UTC`.** Read from the `github-authentication-token-expiration` response header; this works through the proxy from inside the sandbox.
- Claude login: a Pro subscription (OAuth). `SBX_CRED_ANTHROPIC_MODE=none` in the current sandbox.

### 2.2 Docker Sandboxes (`sbx`)
Docs: https://docs.docker.com/ai/sandboxes/. The CLI source is not public; kit specs are at `docker/sandbox-kit-spec` and `docker/sbx-kits-contrib`.

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
  - Top-level fields: `schemaVersion: "1"` (required), `name`, `agent` (required), `args`, `kits`, `workspace` (a string or `{path, clone}`), `additionalWorkspaces` (`{path, readOnly}`), `env`, `sandboxOptions` (`template, memory, cpus, pullPolicy, profile, skills, display, gpu, usb`), `secrets`, `bindings`, `registries`, `mcp.servers`, `ports`, `lifecycle`.
  - `lifecycle.initialize | postCreate | preRemove` run **on the host**.
  - Only `${{ env.args.X }}`, `${{ env.projectDir }}` and `${{ env.fileDir }}` expand. `${VAR}` does not.
  - Changes to workspaces, kits, ports, secrets, bindings and `sandboxOptions` apply **only when the sandbox is next created**. Changes to `env` and MCP servers apply on the next `sbx env run`.
  - `sbx env run` shows a plan and asks for approval. `-y` / `--auto-approve` skips the prompt.
  - Docker's docs: keep the file **outside mounted workspaces**; it is mounted read-only into the sandbox.
  - Examples from the docs:
    ```yaml
    secrets:
      anthropic:
        ref: op://Private/Anthropic/api-key
        refresh: 55m
      github:
        command: gh auth token
    lifecycle:
      initialize:
        - name: Prepare workspace
          command: test -d web-app || git clone https://github.com/example/web-app
          timeout: 5m
    ```
- **Kits.** The built-in `claude` agent is a **v2** kit, so extensions must be v2.
  - A v2 kit is a folder holding `spec.yaml` (`schemaVersion: "2"`, `kind: mixin|sandbox`) plus an optional `files/` tree:
    - `files/home/` is copied to `/home/agent/`;
    - `files/workspace/` is copied to the primary workspace.
  - Blocks: `permissions.network.allow/deny`, `credentials`, `environment.variables`, `setup.install` (runs as root by default via `sh -c`; use `user:` to change), `setup.startup` (runs at every start as uid 1000 and doesn't block the agent), `setup.files`, `volumes`, `ports`, `agentInstructions`, `args`.
  - Order at create: network and env → `files/home` → install → `setup.files` → register startup → `files/workspace`.
  - Forking the agent's launch command:
    ```yaml
    schemaVersion: "2"
    kind: sandbox
    name: claude-safe
    extends: claude
    sandbox:
      entrypoint: [claude, "--permission-mode", "manual"]
    ```
  - Tooling: `sbx kit validate|inspect|pack|push|pull`.
  - To add shell init, append to `/etc/sandbox-persistent.sh` in an install command, never completion scripts.
- **Files `sbx` manages** (don't target these with kits): `~/.claude.json`, `~/.claude/settings.json`, `~/.claude/.config.json`. **`~/.claude/settings.json` is rewritten on every (re)create**, with `themeId`, `alwaysThinkingEnabled`, `permissions.defaultMode: bypassPermissions`, bypass-accepted flags, and `apiKeyHelper` when the Anthropic mode isn't `none`.
- **Skills:**
  - `sbx skills import` copies the host's `~/.claude/skills`; `sbx skills add owner/repo` installs from git.
  - Both go into the host's shared store, which is mounted read-only at `~/.claude/skills` in every sandbox (`--skills off|readonly|readwrite`, default `readonly`).
- **Persistence:**
  - `sbx stop` and restart keep everything.
  - `sbx rm` deletes the VM, secrets scoped to that sandbox, and (almost certainly) its `~/.claude/*` volumes.
  - The workspace on the host survives.
  - There is no way to export a whole sandbox.
- **Secrets:**
  - `sbx secret set [SERVICE] [--sandbox NAME] (-t VALUE | --ref … | --command '…') [--refresh …]`. Services include `anthropic` and `github`.
  - Stored in the OS keychain, or in a file under `~/.config/com.docker.sandboxes` when there is no Secret Service (common on WSL).
  - `SBX_CRED_ANTHROPIC_MODE` (`apikey | oauth | none`) is derived from the host-side Anthropic credential when the sandbox is created.
- **Network policy:**
  - `sbx policy init allow-all|balanced|deny-all`.
  - `sbx policy allow|deny network [--sandbox N] "hosts…"`, plus `sbx policy ls|check|log`.
  - **There is no policy file to import or export.** Rules for reproducibility therefore go in the kit (`permissions.network.allow`, scoped to one sandbox) or in a script.
- **Resources:**
  - Memory defaults to 50% of host memory, clamped between 512 MiB and 32 GiB, with a maximum of 75% of the host.
  - CPUs default to all host CPUs.
  - The Docker volume defaults to 10 GB.

### 2.3 Firstmate (`github.com/kunchenguid/firstmate`, MIT, no releases, very active)
- An "agent distro": a repo of `AGENTS.md`, skills and bash `bin/` scripts. You clone it and run `claude` **inside the clone**; that session becomes the "first mate", which starts workers in git worktrees (via treehouse) inside a runtime backend.
- **Home folder layout.** The home is the repo root unless `FM_HOME` is set. `config/`, `state/`, `data/`, `projects/` and `.env` are all gitignored. Overrides: `FM_STATE_OVERRIDE`, `FM_DATA_OVERRIDE`, `FM_PROJECTS_OVERRIDE`, `FM_CONFIG_OVERRIDE`.
- **Config files** (each is one token, trimmed):
  - `config/backend`: set to `herdr`. Selection order: `--backend` flag, then `FM_BACKEND`, then `config/backend`, then auto-detection (`$TMUX`, then `HERDR_ENV=1`), then tmux.
  - `config/crew-harness`: set to `claude`; absent or `default` means workers mirror the primary.
  - `config/claude-permission-mode`: set to `bypass`; `bypass` → `--dangerously-skip-permissions`, `auto` → `--permission-mode auto`; absent means bypass.
  - `config/crew-dispatch.json`: optional dispatch profiles that can pass `--model` / `--effort` for each worker. **Leave it absent for now**; the owner will tune worker effort later.
- **herdr backend:** requires herdr protocol ≥ 14. **Verified herdr versions: 0.7.1, 0.7.3, 0.7.4, 0.7.5, 0.8.0.** Firstmate's own CI pins 0.7.4.
- **Required tools** (`COMMON_TOOLS` in `bin/fm-bootstrap.sh`): `node git gh no-mistakes gh-axi chrome-devtools-axi tasks-axi quota-axi`. The herdr backend adds `herdr jq treehouse`, and optionally `python3`.
- Firstmate's own install commands, for reference only; we install pinned versions instead:
  - `npm install -g <gh-axi|chrome-devtools-axi> && <pkg> setup hooks`
  - `npm install -g <tasks-axi|quota-axi>`
- At session start, bootstrap probes `gh auth status` and prints `NEEDS_GH_AUTH` if it fails.
- Worktrees are created by treehouse under `~/.treehouse/` by default.
- **Merge rule** (AGENTS.md rule 2): *"Never merge a PR without the captain's explicit word."* A per-project `yolo` posture is the only standing relaxation. **Do not enable yolo.**
- Delivery modes: `no-mistakes`, `direct-PR`, `local-only`.

### 2.4 herdr (`github.com/herdrdev/herdr`, Apache-2.0 since 0.8.0)
- A Rust terminal multiplexer for agents: a single static binary with a background server and a client TUI that communicate over a Unix socket. It has **no TCP port and no web UI**.
- **Pinned release v0.8.0** (published 2026-08-03). GitHub asset digests:
  - `herdr-linux-x86_64`: `sha256:b872ea7e40fa2cb17e857ac9b62b1bf26db7b403c622f5d2f3f5b35f6e9acd28`
  - `herdr-linux-aarch64`: `sha256:f647ac66468d9efbc642fe534fb284468f0aea60641606fc008dfc0d82a3ca87`
  - Download URL: `https://github.com/herdrdev/herdr/releases/download/v0.8.0/<asset>`. Install as `~/.local/bin/herdr`, mode 0755.
- **Config** lives at `~/.config/herdr/config.toml` (or `HERDR_CONFIG_PATH`). `herdr --default-config` prints every key. Required settings:
  - turn off update checks and agent-manifest checks (`[update] version_check = false`, `manifest_check = false` in later versions; **confirm the key names with the 0.8.0 binary**);
  - `onboarding = false`.
- **State** lives in `~/.config/herdr/`: sessions, sockets, logs.
- **CLI, from the 0.8.0 docs:**
  - `herdr` attaches, starting the server if needed. Detach with `ctrl+b q`; panes keep running.
  - `herdr server stop` stops the server.
  - `herdr workspace create [--cwd PATH] [--label TEXT] [--env KEY=VALUE] [--focus|--no-focus]` returns JSON containing `.result.workspace`, `.result.tab` and `.result.root_pane`.
  - `herdr pane split …` and `herdr pane run <pane_id> <command>`.
  - `herdr integration install claude` writes `~/.claude/hooks/herdr-agent-state.sh` and **edits `~/.claude/settings.json`**.
- **Agent detection** uses the terminal's foreground process group. In restricted runtimes, set `HERDR_PROCESS_DETECTION=child-groups`.
- The official installer uses `herdr.dev`, which is **blocked, and we don't need it.** Always install from GitHub Releases.

### 2.5 Other pinned artifacts (latest as of 2026-09-25)

| Tool | Version | Linux assets (GitHub digest) |
|---|---|---|
| treehouse (`kunchenguid/treehouse`) | v2.3.0 | `treehouse-v2.3.0-linux-amd64.tar.gz` `94fd2b2c20c35aac1ddc2941317890ad82c9916f5ccecbac4a50cda783eed10f`; `…-linux-arm64.tar.gz` `408589ba72b58d5e942071ed863a83fd96566cfd1e514945daa59defde528bbb` |
| no-mistakes (`kunchenguid/no-mistakes`) | v1.79.0 (Firstmate requires ≥ 1.46.0) | `no-mistakes-v1.79.0-linux-amd64.tar.gz` `d178c8a5134763b8e5f6d82545a3a76285fbbcdc13d09020d1091ec80a3f8da6`; `…-linux-arm64.tar.gz` `eac3f8e494c7d2487594b7eb513e605e59588be4ce147390b8fd184a7e6a8b05` |
| gh-axi (npm) | 0.1.35 | run `gh-axi setup hooks` after install |
| chrome-devtools-axi (npm) | 0.1.35 | run `chrome-devtools-axi setup hooks` after install; **no browser** |
| tasks-axi (npm) | 0.2.6 | |
| quota-axi (npm) | 0.1.54 | |
| Firstmate | commit `dbe124d5129aa13e1148af1a14136d32729dd142` (2026-09-25) | **Re-pin to the `main` HEAD at implementation time** |

The npm packages require node ≥ 20. Check what's inside each tarball (the binary names) when you implement.

### 2.6 Claude Code
- `claude --effort <level>` sets effort **for one session only**.
- `/effort` saves the default for new sessions into `~/.claude/settings.json` as `modelSettings.<model-id>.effortLevel`. Currently `modelSettings["claude-opus-5-5"].effortLevel = "xhigh"`.
- The current user settings file and the owner's project-level status line settings are reproduced in Appendix A.

---

## 3. Settled decisions

| ID | Decision |
|---|---|
| D1 | **What a rebuild restores:** tools and their config, Claude user settings (status line, effort, skills), host `sbx` wiring (secrets, network, entry), and an optional list of repos to clone (starts empty). |
| D2 | **The repo is `digigrant/devenv`.** The owner's **host copy lives at `~/devenv`**, a sibling of the workspace `~/dev`, and **outside every folder the sandbox can write to**. Inside the sandbox it is visible **read-only**. |
| D3 | **Changes to devenv arrive only by PR.** Agents (as `gej-machine`, a collaborator) change devenv in their own clone, push a branch and open a PR. The owner merges, then `git pull`s on the host. Anything that runs on the host (lifecycle hooks, secret `command:`s, host scripts, kit network rules) therefore comes only from code the owner has reviewed and pulled. |
| D4 | **Two layers.** `provision.sh` is the portable installer, safe to re-run, for any Debian/Ubuntu machine (`--plain`) and inside `sbx` (`--sbx`). The `sbx` layer (`sbxenv.yaml` plus a local kit) calls it. Nothing experimental about `sbx` leaks into `provision.sh`. |
| D5 | **Rebuilding is one command:** `cd ~/devenv && sbx env run`. The spec assumes `sbx` is already installed on the host. `devenv doctor` checks host prerequisites; the README documents them. |
| D6 | **The sandbox is named `dev`.** The workspace is the host's `~/dev`, mounted read-write at the same path. |
| D7 | **Secrets are never in the repo.** The host keeps files readable only by the owner (mode 0600): `~/.config/devenv/secrets/anthropic` and `~/.config/devenv/secrets/github`. `sbxenv.yaml` reads each with a `command:` (e.g. `cat …`), so moving to a secrets manager later changes just that line (to `ref: op://…`). |
| D8 | **Claude login** uses the owner's long-lived `claude setup-token` subscription token as the `anthropic` secret, so no `/login` is needed after a rebuild. The fallback is in §7 V1. |
| D9 | **GitHub identity:** the machine account **`gej-machine`**. The `github` secret is its classic `repo` token. Commits in the sandbox are authored by the bot: `gej-machine <318032932+gej-machine@users.noreply.github.com>`. The owner sets branch rules by hand; that is not part of this repo. Note: repos are under a personal account on GitHub Free, so private repos can't have branch rules. |
| D10 | **Agents** run on Claude Code only (Pro plan). Firstmate's `crew-harness` is `claude` and `claude-permission-mode` is `bypass`; the sandbox is the security boundary. The worker harness stays one setting. |
| D11 | **Effort.** The global default effort is **`high`**, which workers inherit. The **first mate is launched with `--effort xhigh`**. Both are values in `devenv.conf`. Per-worker tuning comes later, through Firstmate's `crew-dispatch.json`; don't create that file now. |
| D12 | **Merges** follow Firstmate's rule: never without the owner's explicit word. Don't enable `yolo`, and add no extra config. |
| D13 | **herdr is Firstmate's backend.** Pin herdr **0.8.0** (the newest version Firstmate has verified), installed as a checksummed binary from GitHub Releases, with update and manifest checks off. **Don't install tmux.** |
| D14 | **Firstmate features: core only.** Install gh-axi, tasks-axi, quota-axi, no-mistakes, treehouse and jq, **plus the `chrome-devtools-axi` npm package without a browser** so bootstrap stops complaining. Nothing optional. |
| D15 | **Versions** are pinned in one `versions.env`, updated with `devenv bump`. Claude Code is **not** pinned (it auto-updates). Firstmate is pinned to a commit: **only fresh setups check out the pin**, and an existing clone is never reset (`/updatefirstmate` keeps working). `devenv bump firstmate` records the current HEAD. |
| D16 | **What persists across teardown:** Claude **memory** and Firstmate's **home** (config, data, state) persist, stored under the host workspace and kept **on this machine only**. Claude transcripts, herdr sessions, Firstmate project clones and treehouse worktrees are disposable. |
| D17 | **Placement:** Firstmate's home is in the workspace (`$WORKSPACE_DIR/firstmate`). **Project clones and worktrees live on the sandbox's own disk** (`FM_PROJECTS_OVERRIDE=$HOME/fm-projects`, treehouse's default `~/.treehouse`) for speed. `sbx rm` loses only unpushed work. |
| D18 | **Entry:** the sandbox launches `devenv-entry`. `DEVENV_ENTRY=herdr` (the default) opens herdr with a first-mate pane (Claude at xhigh in `$FM_HOME`). `claude` opens plain Claude, and `shell` opens bash. Switch by editing `env` in `sbxenv.yaml` and re-running `sbx env run`; no recreate is needed. |
| D19 | **Staleness warnings** (`devenv check`): Firstmate ahead of its pin, installed tools that don't match `versions.env`, a token expiring within 14 days, and Firstmate config that differs from the devenv starting copy. They appear as **a one-line warning at entry and a marker in Claude's status line**. `devenv doctor` gives the full report. No Renovate or CI. |
| D20 | **Status line is preserved exactly.** The owner's `statusline-command.sh` is copied **byte-for-byte** (sha256 `dc324500…`). With no warnings, the rendered status line must be **byte-identical** to the original's output. The D19 marker is added by a separate wrapper, only when warnings exist, and can be turned off with `DEVENV_STATUSLINE_WARNINGS=off` in `devenv.conf`. |
| D21 | **Skills** (`grill-me`, `grilling`) are kept in `devenv/skills/` exactly as they are now and delivered through `sbx`'s shared skills store (read-only in every sandbox). In plain mode, `provision.sh` links them into `~/.claude/skills`. |
| D22 | **User-level `~/.claude/CLAUDE.md`** is generated by devenv. It contains **sandbox environment notes only**, and makes the `sbx` runtime guidance reachable for workers whose working folders are outside `/home/<user>`. The workflow rules come from Firstmate. |
| D23 | **Network:** the host keeps the `balanced` baseline policy. Any extra domains are declared in the kit's `permissions.network.allow` (scoped to the sandbox, version-controlled). **Never allow `herdr.dev`.** No published ports. |
| D24 | **Resources:** `sbx` defaults. `sandboxOptions.memory` stays as a commented-out knob. |
| D25 | **Platform:** the Linux `sbx` in WSL2, and native Linux (Ubuntu 24.04+ with KVM). Support both x86_64 and aarch64 assets. |
| D26 | **Testing:** `devenv test` runs `provision.sh --plain` in throwaway `ubuntu:24.04` and `ubuntu:26.04` containers (Docker is available inside the sandbox), plus a byte-identical test of the status line and shellcheck. No CI. |
| D27 | **Agent-agnostic layout.** Everything Claude-specific lives under `agents/claude/`, so the owner can move off Claude later by swapping that folder. |
| D28 | **Operating rule** for the owner, documented in the README and printed by `doctor`: **treat `~/dev` as belonging to the sandbox.** Never run `git`, scripts or build tools in it from the host, because agents could plant git hooks or scripts there. |
| D29 | **Switchover:** build the new `dev` sandbox next to the old `claude-dev` and verify it. Then the owner runs `sbx rm claude-dev` and cleans up the old `~/dev/.claude/` files, after confirming. |

---

## 4. Architecture

### 4.1 Flow

```
HOST (WSL2 or native Linux)                          SANDBOX "dev" (microVM)
~/devenv  (git clone, owner-controlled) ──ro mount──► /home/<u>/devenv (read-only)
~/dev     (workspace)                  ──rw mount──► /home/<u>/dev
~/.config/devenv/secrets/{anthropic,github} ─(sbx proxy injects; sandbox sees placeholders)

cd ~/devenv && sbx env run
  1. host: lifecycle.initialize → bin/devenv host-prepare
        (doctor-lite, skills → sbx store, stage kit payload if needed)
  2. sbx creates the sandbox (if absent) with kit ./kits/devenv (extends claude)
       setup.install  → provision.sh --sbx      (as root, then drops to agent where needed)
       setup.startup  → devenv start            (every start, as agent)
  3. sbx attaches the terminal to the entrypoint → devenv-entry ($DEVENV_ENTRY)
        herdr  → ensure herdr server + "firstmate" workspace pane running
                 `claude --dangerously-skip-permissions --effort xhigh` in $FM_HOME → attach
        claude → exec claude --dangerously-skip-permissions (cwd: workspace)
        shell  → exec bash -l
```

### 4.2 Where things live

| Thing | Location | Survives `sbx rm`? | Travels between machines? |
|---|---|---|---|
| devenv repo | host `~/devenv`, read-only in the sandbox | yes (host) | yes (git) |
| Secrets | host `~/.config/devenv/secrets/` (0600) | yes | copied by hand |
| Firstmate home (clone + `config/ data/ state/`) | `$WORKSPACE_DIR/firstmate` | yes | no |
| Claude memory | `$WORKSPACE_DIR/.devenv-state/claude-memory/<slug>/`, linked from `~/.claude/projects/<slug>/memory` | yes | no |
| Firstmate project clones | `$HOME/fm-projects` (sandbox disk) | no | no |
| treehouse worktrees | `~/.treehouse` (sandbox disk) | no | no |
| herdr sessions, config | `~/.config/herdr` (config written by `devenv start`) | no (config re-created) | n/a |
| Claude transcripts, todos | `~/.claude/*` volumes | no | no |
| Warnings cache | `~/.cache/devenv/warnings` | no | n/a |

---

## 5. Repository layout

```
devenv/
├── README.md                     # quick start, host prerequisites, operating rules, troubleshooting
├── docs/
│   ├── SPEC.md                   # this document
│   └── HOST-VERIFY.md            # host-side verification checklist (you write it; the owner runs it)
├── sbxenv.yaml                   # sbx layer: agent kit, workspaces, env, secrets, lifecycle
├── kits/
│   └── devenv/                   # v2 kit, kind: sandbox, extends: claude (fallback: mixin; see V2)
│       ├── spec.yaml
│       └── files/…               # only if V7 requires staging a copy of the payload
├── devenv.conf                   # non-secret settings (see §6.1)
├── versions.env                  # every pinned version + sha256 (see §6.2)
├── repos.txt                     # optional repos to clone into the workspace (starts empty, comments only)
├── provision.sh                  # portable installer: --sbx | --plain
├── bin/
│   ├── devenv                    # CLI: doctor | check | bump | test | start | entry | host-prepare | skills-sync
│   └── devenv-entry              # entrypoint shim → `devenv entry`
├── lib/                          # sourced shell helpers (download+verify, logging, json merge, …)
├── agents/
│   └── claude/
│       ├── statusline-command.sh # VERBATIM copy of the owner's script (Appendix A.1)
│       ├── statusline.sh         # wrapper: original output + optional warnings marker
│       ├── settings.overlay.json # merged into ~/.claude/settings.json at every start
│       └── CLAUDE.md             # sandbox environment notes (source for ~/.claude/CLAUDE.md)
├── firstmate/
│   └── config/                   # starting copy for $FM_HOME/config/
│       ├── backend               # "herdr"
│       ├── crew-harness          # "claude"
│       └── claude-permission-mode# "bypass"
├── herdr/
│   └── config.toml               # update/manifest checks off, onboarding off (keys confirmed with 0.8.0)
├── skills/
│   ├── grill-me/SKILL.md         # VERBATIM (Appendix A.3)
│   └── grilling/SKILL.md         # VERBATIM (Appendix A.4)
└── tests/
    ├── container-smoke.sh        # used by `devenv test`
    └── statusline-identity.sh    # byte-identical check (fixtures in tests/fixtures/)
```

All scripts are bash with `set -euo pipefail`, must pass shellcheck, and must be **safe to run repeatedly**.

---

## 6. Behavior specs

### 6.1 `devenv.conf` (sourced by bash; non-secret)
```sh
SANDBOX_NAME=dev
BOT_LOGIN=gej-machine
BOT_EMAIL=318032932+gej-machine@users.noreply.github.com
CLAUDE_EFFORT_DEFAULT=high          # global default, inherited by workers
FIRSTMATE_EFFORT=xhigh              # first mate only, via `claude --effort`
DEVENV_STATUSLINE_WARNINGS=on       # on|off — the D19 marker in the status line
WARN_DAYS=14                        # expiry warning threshold
ANTHROPIC_TOKEN_EXPIRES=            # YYYY-MM-DD; owner fills in (setup-token lasts ~1 year); empty = unknown (doctor notes it)
FIRSTMATE_REPO=https://github.com/kunchenguid/firstmate
FM_PROJECTS_DIR='$HOME/fm-projects' # expanded at runtime
```

### 6.2 `versions.env`
Shell-sourceable `KEY=value` lines, one tool per block. Architecture-specific checksums use `_X86_64` and `_AARCH64` suffixes. Example:
```sh
HERDR_VERSION=0.8.0
HERDR_SHA256_X86_64=b872ea7e40fa2cb17e857ac9b62b1bf26db7b403c622f5d2f3f5b35f6e9acd28
HERDR_SHA256_AARCH64=f647ac66468d9efbc642fe534fb284468f0aea60641606fc008dfc0d82a3ca87
TREEHOUSE_VERSION=2.3.0
TREEHOUSE_SHA256_X86_64=94fd2b2c20c35aac1ddc2941317890ad82c9916f5ccecbac4a50cda783eed10f
TREEHOUSE_SHA256_AARCH64=408589ba72b58d5e942071ed863a83fd96566cfd1e514945daa59defde528bbb
NO_MISTAKES_VERSION=1.79.0
NO_MISTAKES_SHA256_X86_64=d178c8a5134763b8e5f6d82545a3a76285fbbcdc13d09020d1091ec80a3f8da6
NO_MISTAKES_SHA256_AARCH64=eac3f8e494c7d2487594b7eb513e605e59588be4ce147390b8fd184a7e6a8b05
NPM_GH_AXI=0.1.35
NPM_CHROME_DEVTOOLS_AXI=0.1.35
NPM_TASKS_AXI=0.2.6
NPM_QUOTA_AXI=0.1.54
NODE_MIN_MAJOR=20                   # plain mode installs a pinned Node only if missing/older
NODE_VERSION=<pin an LTS ≥ 22 with its sha256 from nodejs.org SHASUMS256.txt>
FIRSTMATE_COMMIT=<main HEAD at implementation time>
```
Every download must be verified against its sha256 before installing. **No `curl | sh`.** The single documented exception is installing Claude Code in plain mode when it's missing (§6.3), because it updates itself anyway.

### 6.3 `provision.sh [--sbx|--plain] [--yes] [--git-identity bot|skip]`
The mode is auto-detected when no flag is given: `--sbx` if `IS_SANDBOX=1` or `SANDBOX_NAME` is set, otherwise `--plain`. The git identity defaults to `bot` in sbx mode and `skip` in plain mode. Every step must be idempotent. A second run should change nothing and exit 0.

1. **System packages.** Install via apt what's missing: `git curl jq ca-certificates tar` (and `gh` in plain mode). **Never install tmux.** Use sudo only when needed.
2. **Node.** Require node ≥ `NODE_MIN_MAJOR`. In plain mode, install the pinned Node tarball if node is missing or older. In sbx mode it's preinstalled; just check it.
3. **Pinned binaries.** Put `herdr`, `treehouse` and `no-mistakes` in `~/.local/bin` (make sure it's on PATH). Pick the asset for the architecture (`uname -m` → `x86_64` or `aarch64`), download from GitHub Releases, verify the sha256, and install atomically. Skip any tool whose `--version` already matches.
4. **npm globals.** Install the pinned versions globally with `npm install -g gh-axi@… chrome-devtools-axi@… tasks-axi@… quota-axi@…`, into the existing npm global prefix. In plain mode, if the prefix isn't writable, use a user prefix under `~/.local`. Then run `gh-axi setup hooks` and `chrome-devtools-axi setup hooks`. **Record which files these commands modify (V8).** Do not install a browser.
5. **Claude Code.** In sbx mode, it's preinstalled; leave it. In plain mode, if it's missing, download the official installer to a file and run it. That's the documented exception; log a notice.
6. **Environment.** Write one managed block of exports, idempotently, to `/etc/sandbox-persistent.sh` (sbx) or `~/.config/devenv/env.sh` sourced from `~/.bashrc` (plain):
   - `DEVENV_DIR`: the path to the devenv checkout; the read-only mount in sbx;
   - `FM_HOME=$WORKSPACE_DIR/firstmate` (plain: a configurable path, default `~/dev/firstmate`);
   - `FM_PROJECTS_OVERRIDE=$HOME/fm-projects`;
   - PATH additions for `~/.local/bin` and `$DEVENV_DIR/bin`.

   Guard the block with markers (`# >>> devenv >>>` / `# <<< devenv <<<`) and **never include completion scripts**.
7. **Git identity.** With `--git-identity bot`, set `git config --global user.name "$BOT_LOGIN"` and `user.email "$BOT_EMAIL"`.
8. **Firstmate.**
   - If `$FM_HOME` doesn't exist: `git clone $FIRSTMATE_REPO "$FM_HOME"`, then `git -C "$FM_HOME" checkout -B main "$FIRSTMATE_COMMIT"` and `git branch --set-upstream-to=origin/main`.
   - If it exists: **don't touch the code.**
   - Then copy each file from `devenv/firstmate/config/` into `$FM_HOME/config/` **only if it is absent there** (never overwrite).
9. **herdr config.** Install `devenv/herdr/config.toml` to `~/.config/herdr/config.toml`. If the user's copy differs, keep a `.bak`.
10. **Claude user config.** See §6.4. In plain mode, also link the skills (§6.10).
11. **Claude memory persistence.** See §6.11.
12. **Repos manifest.** For each non-comment line `url [dir]` in `repos.txt`, clone it into the workspace if it's missing.
13. Finish with `devenv check` and print a summary.

In sbx mode, the kit's `setup.install` runs `provision.sh --sbx --yes`. Per-user steps must run as `agent` (uid 1000) with `HOME=/home/agent`; drop privileges with `sudo -u agent -H`, or split the kit into a root step and a user step. Anything that must be re-applied after `sbx`'s own startup rewrites belongs in `devenv start` (§6.5), not here.

### 6.4 Claude settings, status line, `CLAUDE.md`
- **Merging `settings.overlay.json`.** Merge it deeply (jq) into `~/.claude/settings.json`. Keys `sbx` sets must be preserved, not clobbered. The overlay sets:
  - `statusLine`: `{"type":"command","command":"bash \"$HOME/.claude/statusline.sh\""}`. **Confirm Claude Code expands `$HOME` in this command.** If it doesn't, write the absolute path at merge time.
  - The default effort: `CLAUDE_EFFORT_DEFAULT` (`high`). **V9:** find the settings key Claude Code 2.1.x uses for the global default. The current file shows `modelSettings.<model>.effortLevel`; prefer a key that doesn't depend on the model if one exists. If only the per-model form works, set it for the current default model and document that it must be updated when the model changes. `doctor` should flag a mismatch.
  - Hooks added by `herdr integration install claude`, and anything `gh-axi` / `chrome-devtools-axi setup hooks` wrote into `settings.json`. Re-apply them by re-running those commands inside `devenv start` after the merge, rather than copying their output, and make sure nothing ends up duplicated.
- **Status line files.** Install `agents/claude/statusline-command.sh` → `~/.claude/statusline-command.sh` **byte-for-byte** (verify sha256 `dc324500a5e54bc7905816cd92039c6519e4bcd3303d40a023e0686cde7e27c4`), and `agents/claude/statusline.sh` → `~/.claude/statusline.sh`.
- **`statusline.sh` behavior:**
  - Read all of stdin once and pipe it to `bash ~/.claude/statusline-command.sh`. Capture that output exactly, with no added newline.
  - If `DEVENV_STATUSLINE_WARNINGS=on` and `~/.cache/devenv/warnings` isn't empty, append `$'\033[2m | \033[0m'$'\033[31m'"⚠ devenv:$N"$'\033[0m'`, where N is the number of warning lines. Otherwise output **exactly** the original's bytes.
  - If the cache is older than 6 hours, start `devenv check --quiet` in the background, detached and non-blocking. The status line must never wait on the network.
- **`~/.claude/CLAUDE.md`** is generated at every start from `agents/claude/CLAUDE.md` and must stay short. It holds:
  - one line that imports the `sbx` runtime guidance if it exists: `@<dirname "$WORKSPACE_DIR">/CLAUDE.md`. That file is generated by `sbx`, and workers in `~/.treehouse` otherwise wouldn't see it;
  - the notes: GitHub acts as `gej-machine`; Firstmate's `AGENTS.md` governs the git workflow and merges; project clones and worktrees are on sandbox disk and are lost on `sbx rm`, so push work; never add completion scripts to `/etc/sandbox-persistent.sh`.

  If Claude loads the import twice for sessions under `/home/<u>` (for example, the first mate), note it in the PR. That's acceptable.

### 6.5 `devenv start` (kit `setup.startup`; runs as `agent` at every start)
Idempotent and fast (under about 5 seconds, apart from network checks, which have timeouts):
1. **Wait for or run after** the built-in claude kit's startup (V10), then re-apply §6.4: the overlay merge, installing the status line files, generating `CLAUDE.md`, and re-running the integration commands.
2. Make sure the herdr config is in place.
3. Claude memory links (§6.11).
4. Skills fallback linking, if V4 failed (§6.10).
5. `devenv check --quiet`, which writes the warnings cache.

### 6.6 `devenv entry` / `bin/devenv-entry` (the sandbox entrypoint)
Read `DEVENV_ENTRY` (default `herdr`):
- **`herdr`:**
  1. Make sure the herdr server is running.
  2. If no workspace labeled `firstmate` exists, create one with `herdr workspace create --cwd "$FM_HOME" --label firstmate --focus`, and run `claude --dangerously-skip-permissions --effort "$FIRSTMATE_EFFORT"` in its root pane with `herdr pane run`. Set `HERDR_PROCESS_DETECTION=child-groups` only if V3 requires it.
  3. `exec herdr` to attach.

  Running it again must **re-attach without making a second first-mate pane**. Detach with `ctrl+b q`. The sandbox keeps the herdr server alive only as long as the VM is running; report the behavior you observe (V2).
- **`claude`:** `cd "$WORKSPACE_DIR" && exec claude --dangerously-skip-permissions`.
- **`shell`:** `exec bash -l`.
- **Anything else:** print the valid values, then fall back to `shell`.

### 6.7 `devenv check [--quiet]` (runs inside the sandbox, or in plain mode)
Writes one warning per line to `~/.cache/devenv/warnings`, and an empty file when all is well. Without `--quiet` it also prints them. Checks:
1. **Firstmate pin.** If `$FM_HOME` HEAD ≠ `FIRSTMATE_COMMIT`: when the pin is an ancestor, `firstmate N commits ahead of pin — run: devenv bump firstmate`; otherwise, `firstmate diverged from pin`.
2. **Tool versions.** `herdr`, `treehouse`, `no-mistakes` and the four npm packages' installed versions against `versions.env`. Also `node` against the minimum.
3. **GitHub token expiry.** Read the `github-authentication-token-expiration` header from `https://api.github.com/user`, using the proxy-injected `GH_TOKEN`, with a 5-second timeout. Warn when within `WARN_DAYS`, or when the token is invalid (401). Show "no expiry" when the header is absent.
4. **Anthropic token.** Warn when `ANTHROPIC_TOKEN_EXPIRES` is set and within `WARN_DAYS`.
5. **Firstmate config drift.** A file in `devenv/firstmate/config/` whose contents differ from `$FM_HOME/config/`.
6. **At entry.** `devenv entry` prints the warnings (yellow, one line each) before attaching.

### 6.8 `devenv bump`
Operates on a **writable** devenv checkout: `--repo PATH`, defaulting to the repo containing the script if writable. If only the read-only mount is available, fail with instructions to clone the repo. It edits `versions.env` and prints the diff; it never commits or pushes by itself.
- `devenv bump firstmate`: sets `FIRSTMATE_COMMIT` to `$FM_HOME` HEAD.
- `devenv bump herdr <version>`: fetches the release asset digests from the GitHub API and updates the version and both sha256 values. **Warn loudly** if `<version>` isn't listed in the verified herdr versions in `$FM_HOME/docs/herdr-backend.md`.
- `devenv bump treehouse|no-mistakes <version|latest>`: same idea.
- `devenv bump npm <pkg> <version|latest>`.
- `devenv bump --list`: a table of pinned vs. latest versions. Read-only.

### 6.9 Secrets and `sbxenv.yaml`
A sketch; confirm every field with V5 and V1:
```yaml
schemaVersion: "1"
name: dev
agent: ./kits/devenv                 # sandbox kit extending claude (V2)
workspace: ../dev                     # sibling of ~/devenv, no hardcoded home (V5)
additionalWorkspaces:
  - path: .                           # devenv itself, read-only (V5, V7)
    readOnly: true
env:
  DEVENV_ENTRY: herdr                 # herdr | claude | shell  (applies on next `sbx env run`)
secrets:
  anthropic:
    command: cat "$HOME/.config/devenv/secrets/anthropic"   # swap for `ref: op://…` later
  github:
    command: cat "$HOME/.config/devenv/secrets/github"
sandboxOptions:
  skills: readonly                    # `off` if V4 falls back
  # memory: 12g                       # knob; default = 50% of host
lifecycle:
  initialize:
    - name: devenv host-prepare
      command: ./bin/devenv host-prepare
```
`devenv host-prepare` runs on the host:
- a light version of `doctor` that fails fast on missing secret files or wrong permissions;
- syncing skills into the `sbx` store (V4);
- staging the kit payload, if V7 needs it.

It must not write anywhere the sandbox can write.

### 6.10 Skills
- **sbx mode:** get `devenv/skills/*` into `sbx`'s shared store from the host (V4), in a way that is idempotent and also removes skills that were deleted from the repo.
- **Fallback:** set `sandboxOptions.skills: off`, and have `devenv start` link `~/.claude/skills/<name>` → `$DEVENV_DIR/skills/<name>`.
- **Plain mode:** link each skill into `~/.claude/skills/<name>`. Never overwrite a user's existing skill that isn't a symlink.
- **Acceptance:** both skills are listed and usable in a Claude session started in `$FM_HOME` **and** in a worker running in a `~/.treehouse` worktree.

### 6.11 Claude memory persistence
- **Goal:** memory Claude writes in any session survives `sbx rm` and a rebuild.
- **Storage:** `$WORKSPACE_DIR/.devenv-state/claude-memory/<slug>/`, where `<slug>` is Claude's project folder name under `~/.claude/projects/`, e.g. `-home-gejoy-dev`.
- **Suggested approach:**
  - `devenv start` moves any real `~/.claude/projects/*/memory` folder into the state folder and replaces it with a symlink, and links every existing state folder back in.
  - Add a lightweight Claude `SessionStart` hook (through the overlay) that does the same for the current project, so memory is linked before it's written.
  - Alternatively, if Claude Code has a documented setting for the memory location, use that and say so in the PR.
- **Acceptance:** AC10.

### 6.12 `devenv doctor`
It detects where it's running.
- **On the host:**
  - `sbx` installed; print its version (warn below 0.45).
  - `sbx` logged in.
  - `/dev/kvm` accessible and the user in the `kvm` group.
  - A network policy has been set up (`sbx policy ls` isn't empty).
  - Secret files exist with mode 0600.
  - **The devenv checkout is not inside `~/dev`** or any other sandbox workspace. This is a hard failure.
  - The checkout is clean, on `main`, and not behind `origin/main` (warn).
  - Anthropic token expiry is known and in the future.
  - Print the D28 operating rule.
  - When `/proc/version` contains "microsoft", note that this is WSL and that Docker supports the Linux `sbx` there only "best-effort".
- **In the sandbox or plain mode:**
  - every tool is present at its pinned version;
  - `gh api user` → `$BOT_LOGIN`;
  - `gh auth status` passes, because Firstmate's bootstrap depends on it;
  - Claude is logged in (`claude auth status` or equivalent);
  - `SBX_CRED_ANTHROPIC_MODE=oauth` in sbx mode;
  - the herdr server responds;
  - `$FM_HOME` exists;
  - Firstmate bootstrap reports no missing tools (run its detection-only probe if one exists);
  - the settings overlay is applied and the status line checksum matches;
  - print the output of `devenv check`.

### 6.13 `devenv test`
For each image in `ubuntu:24.04` and `ubuntu:26.04`:
1. Start a container with the repo mounted read-only.
2. Create a non-root user with sudo.
3. Run `provision.sh --plain --yes --git-identity skip`. The Claude Code step may be skipped with a test flag.
4. Assert the versions, a clean second run (idempotent), and that `devenv check` exits 0.

Also run `tests/statusline-identity.sh`: feed fixture JSON into the original script and into the wrapper (with an empty warnings cache) and assert byte-identical output. Then assert the marker appears when the cache isn't empty, and disappears with `DEVENV_STATUSLINE_WARNINGS=off`. Finally, run shellcheck on all scripts.

**Proxy note:** inside the sandbox, containers must reach the network through the sandbox proxy. Pass `HTTPS_PROXY`, `HTTP_PROXY` and `NO_PROXY` through, and install the proxy CA (`echo "$PROXY_CA_CERT_B64" | base64 -d` → `/usr/local/share/ca-certificates/sbx-proxy.crt`, then `update-ca-certificates`) in the test container, but **only when those variables are present**.

---

## 7. Verification items (test these first; each has a fallback)

**Who runs them:** **A** = you, inside the current sandbox. **H** = the owner, on the host, using commands you write in `docs/HOST-VERIFY.md`.

| ID | Who | Question | Procedure | Fallback |
|---|---|---|---|---|
| V1 | H | Does `sbx` accept the subscription token (`sk-ant-oat01…`) as the `anthropic` secret? | Create `dev`; inside it, `echo $SBX_CRED_ANTHROPIC_MODE` should print `oauth`; `claude -p "reply ok"` should work without `/login`. | Drop the `anthropic` secret and document a one-time `/login` after each rebuild. |
| V2 | H | Can `sbxenv.yaml` `agent:` refer to a local sandbox kit (`kind: sandbox`, `extends: claude`) whose entrypoint is `devenv-entry`, while keeping Claude's credentials and network rules? What happens to the herdr server when the entrypoint exits (on detach)? | `sbx env plan`, then `sbx env run`; run it again to test re-attaching. | Use `agent: claude` plus the kit as a **mixin** (`kits: [./kits/devenv]`), and have the owner run `devenv entry` by hand. The README then documents `DEVENV_ENTRY` as advisory. |
| V3 | A | Does herdr 0.8.0 run in the sandbox and correctly detect Claude's state (working, blocked, idle)? | Install to a temporary prefix. Start the server, create a workspace, `pane run` Claude, and watch the detected state. Try the default detection first, then `HERDR_PROCESS_DETECTION=child-groups`. | Set `HERDR_PROCESS_DETECTION=child-groups` in the managed env block. If detection still fails, stop and report. |
| V4 | H/A | Can `sbx`'s shared skills store be filled from `devenv/skills` (local folder), in a way that is idempotent and removes deleted skills? | Check `sbx skills --help` on the host; try `add` with a local path, or `import` from a staging `HOME`. | `skills: off` plus linking in `devenv start` (§6.10). |
| V5 | H | Do relative paths work (`workspace: ../dev`, `additionalWorkspaces: [{path: ., readOnly: true}]`, and a relative lifecycle `command:`)? Is the sbxenv folder already mounted read-only on its own? Do secret `command:`s run in a shell with `$HOME` expanded? | `sbx env plan` output, then `sbx env run` and inspect the mounts. | Use `${{ env.fileDir }}` expressions. If those also fail, add a tiny host wrapper `bin/devenv up` that renders `sbxenv.yaml` from a template with absolute paths and runs `sbx env run`. |
| V6 | H | Does Claude memory survive `sbx rm` plus a rebuild? | Write a memory in the sandbox, run `sbx rm dev`, rebuild, and check. | Add a `lifecycle.preRemove` host hook that runs `sbx env exec -- devenv state-save` before removal. |
| V7 | H | Is the read-only devenv mount present while `setup.install` runs? | Log `ls $DEVENV_DIR` at install time. | Have `host-prepare` stage the files `provision.sh` needs into `kits/devenv/files/…` (gitignored build output), so they are copied in by the kit. |
| V8 | A | Which files do `gh-axi setup hooks` and `chrome-devtools-axi setup hooks` modify? | Snapshot `~` before and after, in a throwaway container or a temporary `HOME`. | If they edit `~/.claude/settings.json`, re-run them in `devenv start` (§6.4). |
| V9 | A | Which settings key sets the **global default** effort in Claude Code 2.1.x? Does the `statusLine` command expand `$HOME`? | Read the Claude Code settings docs and schema; test with a temporary `CLAUDE_CONFIG_DIR`. | Use the per-model key and write an absolute path. |
| V10 | H/A | Does the built-in claude kit's startup rewrite `settings.json` **after** our startup hook runs? | Compare timestamps and contents after a restart (`sbx stop dev`, then `sbx env run`). | `devenv start` waits until the `sbx` startup has finished (poll for `/var/log/sbx-kit-startup.log` completion) before merging, or re-merges when `devenv entry` launches. |
| V11 | H | Which extra domains does the `balanced` policy block for our downloads? Candidates: `github.com`, `api.github.com`, `codeload.github.com`, `objects.githubusercontent.com`, `release-assets.githubusercontent.com`, `raw.githubusercontent.com`, `registry.npmjs.org`, and `nodejs.org` for plain mode only. | `sbx policy check network --sandbox dev <host>` for each, or watch `sbx policy log` during the first create. | Add only the blocked ones to the kit's `permissions.network.allow`. **Never `herdr.dev`.** |
| V12 | A/H | Does Firstmate's bootstrap pass inside `dev` (all tools found, `gh auth status` OK, herdr backend detected)? | Start the first mate and read its bootstrap output. | Fix the provisioning. If the problem is in Firstmate itself (e.g. `gh auth status` behind the proxy), report it and don't patch Firstmate. |

---

## 8. Acceptance criteria

- [ ] **AC1** On a host that meets the prerequisites and has the secret files, `cd ~/devenv && sbx env run` creates a working `dev` sandbox with **no manual steps** (except `/login`, only if V1 fell back).
- [ ] **AC2** You land in herdr, with a `firstmate` workspace whose pane runs Claude at xhigh in `$FM_HOME`. Firstmate uses the herdr backend and its bootstrap reports no missing tools and no `NEEDS_GH_AUTH`.
- [ ] **AC3** Running `sbx env run` again re-attaches without making a second first-mate pane.
- [ ] **AC4** `DEVENV_ENTRY=claude` and `DEVENV_ENTRY=shell` work after editing `sbxenv.yaml` and re-running, without recreating the sandbox.
- [ ] **AC5** The status line output is **byte-identical** to the original script's for fixture inputs when there are no warnings. A marker appears when warnings exist, and the `off` setting works. The script's sha256 is `dc324500…`.
- [ ] **AC6** After a restart **and** after a recreate, `~/.claude/settings.json` contains the status line and the global effort (`high`), and every key `sbx` requires is still there.
- [ ] **AC7** `grill-me` and `grilling` are available in Claude sessions in `$FM_HOME` and in a treehouse worktree.
- [ ] **AC8** `devenv check` catches:
  - Firstmate ahead of its pin (make a local commit or move the pin);
  - a tool version that doesn't match;
  - token expiry (test with a large `WARN_DAYS`; the bot token expires 2026-10-25).

  Each warning shows at entry and in the status line.
- [ ] **AC9** `devenv bump` updates `versions.env` correctly for Firstmate, herdr (with its sha256 and the verified-version warning), treehouse, no-mistakes and the npm packages.
- [ ] **AC10** After `sbx rm dev` and a rebuild, the Firstmate home (`config/`, `data/`, `state/`) and Claude memory are still there, and project clones and worktrees are gone, as expected.
- [ ] **AC11** Commits made in the sandbox are authored by `gej-machine <318032932+gej-machine@users.noreply.github.com>`, and pushing and `gh pr create` work.
- [ ] **AC12** `devenv test` passes on `ubuntu:24.04` and `ubuntu:26.04`, and running provisioning a second time changes nothing.
- [ ] **AC13** Host `devenv doctor` passes, and **fails** if the devenv checkout is inside a workspace or a secret file is readable by anyone else.
- [ ] **AC14** The repo contains no secrets: `git grep -nE 'sk-ant-|ghp_|github_pat_|gho_[A-Za-z0-9]{20}'` finds nothing except placeholder docs.
- [ ] **AC15** No `herdr.dev` allowance; herdr's update and manifest checks are off; tmux is not installed.
- [ ] **AC16** Nothing in the repo hardcodes `/home/gejoy` or `/home/agent`, except in test fixtures and docs.

---

## 9. Execution plan

**Phase 0 — Preconditions (the owner does these; check them before you start):**
1. `digigrant/devenv` exists with a starting README (so `main` exists), and `gej-machine` has been invited.
2. In the sandbox, accept the invite as the bot:
   ```sh
   gh api user/repository_invitations --jq '.[] | select(.repository.full_name=="digigrant/devenv") | .id' \
     | xargs -I{} gh api -X PATCH user/repository_invitations/{}
   ```
3. Clone to the **sandbox disk** (e.g. `~/src/devenv`), **not** under `/home/gejoy/dev`. Create the branch `initial-setup`.

**Phase 1 — Build (A):** the repo layout (§5), `docs/SPEC.md`, the verbatim files (Appendix A, checked by sha256), `provision.sh`, `bin/devenv`, `lib/`, the kit, `sbxenv.yaml`, the configs and the README.

**Phase 2 — Verify what you can inside the sandbox (A):**
- V3, V8 and V9;
- `devenv test` (AC12, AC5 identity);
- `provision.sh --sbx` in the **current** sandbox against a temporary `WORKSPACE_DIR` and `HOME`, where practical. Don't clobber the live `~/.claude/settings.json`; use `CLAUDE_CONFIG_DIR` or a temporary `HOME`.

Commit, push, and open the PR. Its description must include:
- a summary;
- V-item results so far;
- a link to `docs/HOST-VERIFY.md`;
- known risks.

**Phase 3 — Host verification (H).** `docs/HOST-VERIFY.md` must give exact commands and what they should print, in order:
1. Prerequisites: `sbx version`, `sbx login` status, `sbx policy ls`.
2. Clone: `git clone https://github.com/digigrant/devenv ~/devenv` from the PR branch, or from `main` once merged.
3. Secrets:
   ```sh
   install -d -m 700 ~/.config/devenv/secrets
   (umask 077; cat > ~/.config/devenv/secrets/anthropic)   # paste setup-token, Ctrl-D
   (umask 077; cat > ~/.config/devenv/secrets/github)      # paste gej-machine token, Ctrl-D
   ```
   Also fill in `ANTHROPIC_TOKEN_EXPIRES` if the date is known.
4. `~/devenv/bin/devenv doctor`.
5. `cd ~/devenv && sbx env plan`, then `sbx env run`.
6. Checks for V1, V2, V4, V5, V6, V7, V10, V11 and AC1–AC11, each with the exact command to run and what it should print. The owner pastes the output back.

**Phase 4 — Iterate (A):** apply fallbacks according to what the owner reports, and push fixes to the same PR. Stop and ask if something fails and has no fallback.

**Phase 5 — Switchover (H, with the owner's confirmation):**
1. The owner merges the PR, then `git -C ~/devenv pull`.
2. Final `sbx env run`.
3. The owner removes the old sandbox: `sbx rm claude-dev`.
4. Only after the owner confirms: remove the old `/home/gejoy/dev/.claude/settings.json` (project-level `statusLine`), `/home/gejoy/dev/.claude/statusline-command.sh` and `/home/gejoy/dev/.claude/skills/`. These are superseded by user-level config, and the project-level `statusLine` would otherwise override the wrapper for sessions in `~/dev`.

---

## 10. Security invariants (must always hold)

1. No secret values in the repo, in logs, or in files the sandbox can write. Inside the sandbox, only proxy placeholders exist.
2. The host's devenv checkout is never inside a folder the sandbox can write to. Inside the sandbox it is read-only (`doctor` enforces this).
3. Code that runs on the host (lifecycle hooks, secret `command:`s, `bin/devenv` host subcommands) comes only from the owner's host checkout.
4. Every download is pinned and checksum-verified. No `curl | sh`, except the Claude Code install in plain mode (§6.2).
5. No allowance for `herdr.dev`; herdr's automatic checks are off.
6. No completion scripts in `/etc/sandbox-persistent.sh`.
7. Firstmate's `yolo` stays off. Merges need the owner's explicit word (Firstmate rule 2).
8. The `github` secret is the `gej-machine` token only. Never the owner's personal token.

---

## 11. Future work (don't build now; note in the README "Roadmap")

- A GitHub permission system for agents: rulesets or a bot bypass list, or a GitHub App with short-lived tokens through `secrets.github.command` plus `refresh`.
- A secrets manager: swap the `command:` lines for `ref: op://…`.
- Worker effort and model profiles in Firstmate's `config/crew-dispatch.json`.
- A second worker harness (e.g. Codex), which needs `config/crew-harness` and its install.
- Bumping herdr past 0.8.0 once Firstmate verifies newer versions.

---

## Appendix A — Files to preserve exactly

### A.1 `agents/claude/statusline-command.sh`
Source: `/home/gejoy/dev/.claude/statusline-command.sh`. sha256 `dc324500a5e54bc7905816cd92039c6519e4bcd3303d40a023e0686cde7e27c4`. **Copy the source file itself**; the block below is for reference. If the source is unavailable, re-create it from this block and verify the sha256.

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

### A.2 Current settings (for reference; not to be copied as-is)
Project-level `/home/gejoy/dev/.claude/settings.json` (sha256 `c49c8ac9…`):
```json
{
  "statusLine": {
    "type": "command",
    "command": "bash /home/gejoy/dev/.claude/statusline-command.sh"
  }
}
```
User-level `~/.claude/settings.json` in the current sandbox (partly written by `sbx`):
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
Source: `/home/gejoy/dev/.claude/skills/grilling/SKILL.md`. sha256 `10ff989e7498b23b5acb49d5048f11dcd906757d2f79c5cdf8a00001381296f2`. **Copy the source file itself.** It is 1,987 bytes and contains nested code fences, so don't re-type it. If the source is unavailable, stop and ask the owner for it.
