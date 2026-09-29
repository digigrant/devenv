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
3. Store this machine's Infisical login in its keyring:
   `~/devenv/bin/devenv secrets-init`. The secrets themselves live in
   Infisical; on a machine that has never run devenv, follow
   [A new machine](#a-new-machine) for where to find the three values.
4. Install Tailscale and sign this machine in (once):
   `~/devenv/bin/devenv tailscale-setup` (see [Tailscale](#tailscale)).
5. Check the host: `~/devenv/bin/devenv doctor`
6. Build and enter the sandbox: `cd ~/devenv && sbx env run`

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

devenv's host commands also use `bash`, `git`, `jq`, `curl`, `secret-tool`
and `busctl`, and a Secret Service (gnome-keyring) for the keyring:

```sh
sudo apt install jq curl libsecret-tools gnome-keyring   # busctl comes with systemd
```

The opt-in [Android emulator](#android-emulator-opt-in) also needs Docker
Engine; its section says how to install it.

On WSL, Docker supports the Linux `sbx` only "best-effort"
(docker/sbx-releases#397); `devenv doctor` says so. The owner chose it so WSL
and native Linux behave the same.

### Tailscale

Every devenv host runs Tailscale in Linux: inside the WSL 2 distro on the
Windows PC, and natively on a Linux PC. (It is for Magic Conch, a phone app
that will reach a hub on each machine over the tailnet; the hub isn't part of
devenv yet.) Once per machine:

```sh
~/devenv/bin/devenv tailscale-setup
```

It adds Tailscale's own apt repository for your release as Tailscale
documents it (the key `/usr/share/keyrings/tailscale-archive-keyring.gpg` and
the source `/etc/apt/sources.list.d/tailscale.list`, from
`pkgs.tailscale.com`), installs `tailscale`, starts `tailscaled` and enables it
at boot. If the machine isn't signed in, it runs `sudo tailscale up`, which
prints a link: open it in a browser and sign in to your tailnet. That is the
only sign-in, once per machine. devenv never uses a Tailscale auth key and
stores nothing from Tailscale (tailscaled keeps the machine's own key, as on
any machine running Tailscale). Run the command again whenever you like: with
everything in place it changes nothing and doesn't ask for sudo. Tailscale
updates arrive with the machine's normal apt upgrades. `devenv doctor` checks
all of this and prints the fix for anything missing.

**On WSL 2** (Tailscale's page:
[Install Tailscale on Windows with WSL 2](https://tailscale.com/docs/install/windows/wsl2)):

- **Uninstall Tailscale on Windows** (Settings > Apps > Installed apps >
  Tailscale > Uninstall), or keep it stopped whenever WSL runs Tailscale:
  with both running, Tailscale traffic from WSL doesn't work. Tailscale's
  own advice is to run it on Windows only; devenv runs it in WSL instead, so
  the Windows PC and a Linux PC work the same way. To keep it installed but
  stopped, in an administrator PowerShell:
  `Set-Service Tailscale -StartupType Disabled; Stop-Service Tailscale`.
  `tailscale-setup` refuses to start, and `doctor` fails, while it runs on
  Windows.
- **systemd must be on** in the distro, since tailscaled is a systemd
  service: `/etc/wsl.conf` needs `systemd=true` under `[boot]` (Ubuntu's WSL
  image has it), then `wsl.exe --shutdown` in PowerShell and open the distro
  again. `doctor` prints the exact fix when it's off.
- WSL can shut an idle distro down (`instanceIdleTimeout` in `.wslconfig`,
  15 seconds by default), and tailscaled stops with it.
- The WSL machine may get the Windows machine's name. If the Windows PC was in
  the tailnet, remove its old entry on the admin console's
  [Machines](https://console.tailscale.com/admin/machines) page, and rename
  the WSL one there if you like.

**Once per tailnet, in the admin console** (the Magic Conch hub will use
`tailscale serve`, which needs both; devenv doesn't configure `serve`): open
the [DNS](https://console.tailscale.com/admin/dns) page, turn on **MagicDNS**
if it is off (tailnets created since October 2022 have it on), and under
**HTTPS Certificates** select **Enable HTTPS**. Enabling HTTPS publishes the
name of every machine that gets a certificate in the public Certificate
Transparency logs, so keep machine names free of anything sensitive. `doctor`
warns while either is off.

**Key expiry.** A machine's Tailscale key expires (after 180 days by default),
and the machine then drops off the tailnet until it signs in again. `doctor`
warns `WARN_DAYS` ahead. Renew with `sudo tailscale up --force-reauth`, or
disable key expiry for the machine on the Machines page.

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
  token only, never a personal token. Never paste a secret value, or the
  Infisical client ID, client secret or project ID, into a PR, an issue or an
  agent's session: they live only in Infisical and in each host's keyring.
- Never allow `herdr.dev`: herdr is pinned, and its update and manifest
  checks are off.
- Merges follow Firstmate's rule: never without the owner's explicit word.
  `yolo` stays off.

## Claude sign-in

With `CLAUDE_AUTH=token` (the default, in `devenv.conf`), Claude, the first
mate and every worker run on your Claude subscription through the long-lived
`claude setup-token` token:

- The token is `CLAUDE_CODE_OAUTH_TOKEN` in Infisical ([Secrets](#secrets-infisical)).
  `devenv host-prepare` gives it to sbx as a **custom secret** for sandbox
  `dev` (`sbxenv.yaml` can't declare custom secrets) whose command is
  `devenv secret-get CLAUDE_CODE_OAUTH_TOKEN`. Inside the sandbox
  `CLAUDE_CODE_OAUTH_TOKEN` holds only a placeholder; the proxy swaps in the
  real token on requests to `api.anthropic.com`. The placeholder is random,
  and sbx is the only place that keeps it: on every `sbx env run`,
  host-prepare reuses the one sbx already holds for `dev` (so a running
  sandbox stays signed in) and makes a new one only when sbx has none.
- Firstmate needs no changes: workers inherit the variable, and `quota-axi`
  reads your subscription's usage windows with it.
- No stored claude.ai login may exist in the sandbox in this mode. Claude's
  daemon, which hosts the first mate's conversation, starts without
  `CLAUDE_CODE_OAUTH_TOKEN` whenever `~/.claude/.credentials.json` holds one,
  and sbx's `claude` kit seeds one when your host has an Anthropic
  subscription (OAuth) credential. `devenv start` and `devenv entry` therefore
  move it to `~/.claude/.credentials.json.devenv-stored-login` before the
  first mate starts (login mode is never touched), and `devenv doctor` fails
  while one exists or while a running Claude daemon lacks the variable. To
  make the setup-token the only path, also remove the host's own `anthropic`
  OAuth secret from sbx (a host action; see HOST-VERIFY V1): while it exists,
  the proxy signs requests to `api.anthropic.com` with it whatever the sandbox
  sends.
- The token is inference-only by design: claude.ai connectors, Remote Control,
  Claude in Chrome and plugin sync don't work with it. Nothing in devenv or
  Firstmate uses them.
- Don't store the token with `sbx secret set anthropic` (or in `sbxenv.yaml`
  `secrets:`): sbx then treats it as a Console API key
  (`SBX_CRED_ANTHROPIC_MODE=apikey`), which outranks the subscription and is
  rejected with HTTP 401.

`CLAUDE_AUTH=login` instead uses no Claude secret (host-prepare removes the
custom secret from `dev`): run `/login` once after each rebuild (a full-scope
login that survives `sbx stop`). Switching modes takes a recreate.

## Secrets (Infisical)

The Claude setup-token and the `gej-machine` GitHub token live in
[Infisical](https://infisical.com), in one project (the agent project),
environment `dev`, path `/`, as `CLAUDE_CODE_OAUTH_TOKEN` and
`GITHUB_GEJ_MACHINE_PAT`. The design is [docs/SECRETS.md](docs/SECRETS.md).
No secret sits in a file, on the host or in the sandbox:

- Each host logs in to Infisical as the machine identity `sbx-host`, a Viewer
  on that project and nothing else. The login (the project ID, the client ID
  and this machine's own client secret) is kept in the host's keyring (the
  Secret Service, e.g. gnome-keyring), never in the repo or a file.
- `devenv host-prepare` registers both with sbx on every `sbx env run`: the
  `github` service secret and the Claude custom secret for sandbox `dev`,
  each as a command, not a value. (`sbxenv.yaml` declares no secrets: it
  can't read `devenv.conf`. Its `bindings.github` approves the proxy using
  the github one.)
- When an agent calls GitHub or Anthropic, sbx needs the real value. It runs
  `devenv secret-get NAME` on the host, which reads the keyring, logs in to
  Infisical for a 5-minute access token, reads the one secret and hands it to
  sbx. sbx keeps it in memory and asks again after the refresh set in
  `devenv.conf`: `SECRET_REFRESH` (55 minutes by default), or a secret's own
  `SECRET_REFRESH_CLAUDE` / `SECRET_REFRESH_GITHUB`. A value is a duration
  such as `10m` or `1h30m`, or `on-demand` (a fetch, and an Infisical login,
  on every use). The sandbox only ever sees placeholders.
- **Replacing a token** is one paste into the secret on the Infisical website.
  Every machine picks it up within the refresh (55 minutes by default).
- **Retiring or losing a machine:** revoke its client secret on the website
  (`sbx-host`, Universal Auth). The other machines keep working.

### A new machine

Already set up once, on the Infisical website: the agent project with both
secrets, and the machine identity `sbx-host` (Universal Auth, Access Token TTL
and Max TTL `300`, Lockout on). Then, on the new machine:

1. Install the [host prerequisites](#host-prerequisites) and clone devenv to
   `~/devenv` ([Quick start](#quick-start-host)).
2. Collect the three values on the Infisical website, and keep the tab open:
   - **Project ID:** open the agent project, then **Project Settings**, and
     select **Copy Project ID**.
   - **Client ID:** in the organization, **Access Control**, then **Machine
     Identities**, then `sbx-host`. The Client ID is in its **Universal Auth**
     section. It is *not* the Identity ID (the one under **Options**, **Copy
     Machine Identity ID**).
   - **Client secret:** in that same Universal Auth section, **Add Client
     Secret**, named after the machine (e.g. `linux-grant`), with TTL `0` (no
     expiry). Infisical shows it only once.
   - Check that `sbx-host` can read the project: in the project, **Access
     Control**, then **Machine Identities**, it must be listed with the
     **Viewer** role. If it isn't: **Add Machine Identity to Project**,
     **Assign Existing**, `sbx-host`, role Viewer.
3. Run `~/devenv/bin/devenv secrets-init` and paste each value at its prompt
   (nothing shows as you paste). If the machine has no keyring yet, a window
   asks you to choose a keyring password after the first value: pick a real
   one, you type it after every WSL restart. It ends with:
   ```text
   Test fetch:
     GITHUB_GEJ_MACHINE_PAT: ok (40 chars, ghp_…)
     CLAUDE_CODE_OAUTH_TOKEN: ok (<n> chars, sk-ant-oat01-…)
   devenv: ✓ done; the Infisical website tab can be closed
   ```
4. Start: `cd ~/devenv && sbx env run`.

**Careful with retries.** 3 failed logins lock `sbx-host` for 5 minutes
(the count starts again once 30 seconds pass without a failure), and during
a lockout even the right values fail. After a failed test fetch, check
the values, wait 5 minutes, then run `secrets-init` again (Enter keeps the
entries you don't change). On the website, `sbx-host`, Universal Auth,
**Reset All Lockouts** ends a lockout at once. devenv itself stops after the
first failed login in a run.

**After a restart.** WSL locks the keyring every time it restarts. At the next
`sbx env run`, `devenv host-prepare` opens a pop-up window asking for the
keyring password (the one from step 3); type it and the run carries on. A
Linux desktop unlocks the keyring at login instead. A host with no display
can't show the window: host-prepare stops and says so.

**A new client secret for this machine** (revoked or lost): add one on the
website as in step 2, then run `devenv secrets-init` and press Enter for the
project ID and client ID.

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
| Secrets | Infisical; this host's Infisical login in its keyring | yes |
| Firstmate home (clone, `config/`, `data/`, `state/`) | `~/devenv/dev/firstmate` | yes |
| Claude memory | `~/devenv/dev/.devenv-state/claude-memory/<project>/`, linked from `~/.claude/projects/<project>/memory` | yes |
| Firstmate project clones | `~/fm-projects` (sandbox disk) | no: push your work |
| treehouse worktrees | `~/.treehouse` (sandbox disk) | no |
| adb (platform-tools) and the Android build toolchain (SDK packages, JDK) | `~/.local/share/android-sdk`, `~/.local/share/jdk` (sandbox disk) | no: installed again at the next create (packages added with `sdkmanager` too: add them again) |
| Android emulator image and SDK volume | the host's Docker Engine | yes (host; `devenv emulator clean` removes them) |
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

## Building Android apps

Every sandbox (and plain mode, on x86_64) has what a phone app's Gradle build
needs, so a project doesn't carry a toolchain of its own:

| What | Pinned | Where |
|---|---|---|
| JDK (Eclipse Temurin) | 21.0.12.1+1, the LTS Robolectric runs on | `~/.local/share/jdk` = `JAVA_HOME`; its `java` comes first on `PATH` |
| Android SDK (the packages below) | | `~/.local/share/android-sdk` = `ANDROID_HOME` |
| command-line tools | 22.0 (`sdkmanager`, `avdmanager` linked into `~/.local/bin`) | `cmdline-tools/latest` |
| platform | `platforms;android-37.0` (compileSdk 37) | `platforms/android-37.0` |
| build-tools | 36.0.0, the default of the Android Gradle Plugin 9.4 | `build-tools/36.0.0` |
| platform-tools | 37.0.1 (`adb`, linked into `~/.local/bin`) | `platform-tools` |

Gradle itself comes from each project's wrapper (`./gradlew`), which keeps
one copy per version in `~/.gradle`, shared by every worktree. So from a
project's `android/` folder:

```sh
./gradlew assembleDebug testDebugUnitTest
devenv emulator run -- ./gradlew connectedDebugAndroidTest   # on the host's emulator, below
```

All of it comes from `versions.env`, checked by sha256, and takes about 1 GB of
the sandbox's disk; `devenv doctor` and `devenv check` report anything missing
or at another version. The JDK uses the system's CA list for Java when there is
one, as Ubuntu's own JDKs do, because the sandbox's proxy re-signs
`github.com`, where the Gradle wrapper downloads Gradle.

**Other SDK packages.** devenv doesn't accept the
[Android SDK License Agreement](https://developer.android.com/studio/terms) for
you: it installs its packages from Google's zips directly. A project that
needs another platform or build-tools (the plugin's default moves with its
version) installs it once per sandbox with `sdkmanager --licenses`, then
`sdkmanager "build-tools;<version>"`, or asks for it to be pinned in devenv.
The Android Gradle Plugin can download missing packages itself once the
license is accepted. The command-line tools stay at 22.0 because from 23.0
`sdkmanager` hands every command to Google's Android CLI, which downloads and
updates itself and sends usage metrics by default.

Changes to the toolchain reach a sandbox at its next rebuild (or when
`provision.sh` runs again in it).

## Android emulator (opt-in)

Workers on phone apps run their instrumented and UI tests on an Android
emulator that runs on the host, in a Docker container with KVM: the sandbox
has no KVM of its own (Docker's nested virtualization for sandboxes is
macOS-only, docker/sbx-releases#497). Nothing runs until you start it, and it
never starts by itself.

It is Android 16 (API 36, Google APIs image, x86_64) on Google's emulator
37.1, headless (no window, software graphics, no audio): a phone-sized device
(1080×2400), fresh at every start, with animations off for UI tests. It
follows the Android emulator team's container recipe; devenv builds a small
image of its own and keeps the SDK in a Docker volume, from Google's
downloads pinned by sha256 in `versions.env`
([docs/HANDOFF.md](docs/HANDOFF.md) compares the maintained emulator
containers and says why). `devenv bump android-system-image <api>` moves it
to another Android version.

| Cost | |
|---|---|
| Memory | about 5 GB while it runs: 4 GB of guest RAM (`ANDROID_EMULATOR_MEMORY`; the least the API 36 image boots with) plus the emulator itself. None while stopped. |
| CPU | 4 cores (`ANDROID_EMULATOR_CORES`) while it runs |
| Disk | about 5.5 GB: the SDK volume (5.1 GB) and the image (under 0.5 GB). The first start also downloads 2.2 GB into `~/.cache/devenv/android-emulator`, deleted once unpacked. A running device adds a few GB inside its container, gone when it stops, and the emulator won't start without a few GB free on Docker's disk. |
| Time | the first start downloads, unpacks and builds (5 to 15 minutes, mostly the download); every start then boots Android, 1 to 3 minutes |

**Once per host:**

1. Docker Engine inside this Linux, not Docker Desktop (Docker Desktop's
   containers get no `/dev/kvm`). Docker's apt repository is already set up
   for sbx:
   ```sh
   sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin
   sudo usermod -aG docker $USER     # then log out and in again
   ```
   Membership in the `docker` group is as good as root on this machine.
2. Let sandboxes reach the emulator's adb port. One rule, for every sandbox,
   that survives rebuilds:
   ```sh
   sbx policy allow network localhost:15555
   ```
3. `~/devenv/bin/devenv doctor` checks both, and KVM, in its "Android
   emulator" section.

**Start and stop it on the host:**

```sh
~/devenv/bin/devenv emulator start    # returns once Android has booted
~/devenv/bin/devenv emulator status
~/devenv/bin/devenv emulator stop     # frees the memory; image and SDK stay
~/devenv/bin/devenv emulator clean    # also removes the image, SDK volume and downloads
```

**In the sandbox, a worker runs a test with:**

```sh
devenv emulator run -- ./gradlew connectedDebugAndroidTest
```

`run` connects the sandbox's adb to the emulator
(`host.docker.internal:15555`), waits its turn when another worker is using
it, and runs the command with `ANDROID_SERIAL` set to it.
`devenv emulator connect` only connects and prints the serial, for plain
`adb -s host.docker.internal:15555 …`. `devenv emulator status` says why the
emulator can't be reached: not started on the host, or no policy rule for its
port. The build itself runs in the sandbox, with the toolchain in
[Building Android apps](#building-android-apps).

**How the sandbox reaches it.** The emulator's adb port is published on the
host's `127.0.0.1:15555` only. adb speaks raw TCP, not HTTP; sbx's proxy
relays a sandbox's TCP connection to `host.docker.internal:<port>` to the
host's `localhost:<port>` when the network policy allows `localhost:<port>`
(sbx 0.30 and later), which is the rule above.

**Limits.** One emulator per host, shared by the sandbox's workers, one test
run at a time. x86_64 hosts only. No Google Play (the Google APIs image). adb
authorization is off, so any process on the host, and any sandbox the policy
lets in, can drive the device. Using it accepts the
[Android SDK License Agreement](https://developer.android.com/studio/terms).
To use another port, set `ANDROID_EMULATOR_PORT` (devenv.conf by PR, or in the
environment for one run) and allow that port instead.

## Commands

`bin/devenv` (on `PATH` inside the sandbox):

| Command | Where | What |
|---|---|---|
| `devenv doctor` | host, sandbox, plain | Full health report. On the host: sbx, KVM, policy, Tailscale (installed from Tailscale's repository, tailscaled running, signed in, MagicDNS and HTTPS certificates; on WSL also systemd and Tailscale on Windows), the keyring and both Infisical secrets (never prompts), checkout location, the Android emulator (optional), operating rule. Inside: pinned tools, GitHub identity, Claude login, herdr, Firstmate bootstrap, settings, skill links, the Android build toolchain, adb and whether the host's emulator answers. |
| `devenv check [--quiet]` | sandbox, plain | Staleness warnings: Firstmate off your fork's `main` or a failed automatic update, uncommitted changes in the devenv clone the sandbox runs from, tool versions, GitHub token expiry (via the API), `ANTHROPIC_TOKEN_EXPIRES` (if set), Firstmate config drift, herdr detection override. Shown at entry and as `⚠ devenv:N` in Claude's status line. |
| `devenv bump …` | a writable clone | Update `versions.env`: `herdr <v>`, `herdr-manifest <commit\|latest>`, `treehouse\|no-mistakes <v\|latest>`, `npm <pkg> <v\|latest>`, `node <v\|latest-lts>`, `platform-tools <v\|latest>`, `android-cmdline-tools <v\|latest>`, `android-platform <android-NN.N>`, `android-build-tools <v\|latest>`, `jdk <v\|latest>`, `android-emulator <build\|latest>`, `android-system-image <api> [tag]`, `android-base-image [image:tag]`, `--list`. Prints the diff; never commits. |
| `devenv test` | sandbox or any Docker host | Status line byte-identity, the secrets and emulator commands and the Android toolchain installers against fakes, `tailscale-setup` and doctor's Tailscale checks against fakes, `start`, `entry` and doctor's token-mode Claude sign-in checks against a temporary home and a fake `/proc`, shellcheck, `provision.sh --plain` in `ubuntu:24.04` and `ubuntu:26.04` containers (twice, to prove it's idempotent), a simulated sbx create that runs the kit's own install and startup steps, and the keyring code against a real gnome-keyring in a container. |
| `devenv start` | sandbox | Run by the kit at every start: reapply Claude settings, status line, `CLAUDE.md`, herdr config, skill and memory links, warnings. |
| `devenv entry` | sandbox | The entrypoint (via `devenv-entry`). |
| `devenv host-prepare` | host | The `lifecycle.initialize` hook: unlocks the keyring if it is locked (a pop-up window), checks both secrets, the refresh settings and the checkout location, creates `dev/`, gives the sandbox the `github` secret and sets up the Claude sign-in. |
| `devenv secrets-init` | host | Stores this machine's Infisical login (project ID, client ID, client secret) in the keyring, then test-fetches both secrets. Interactive; run it again to replace a value (Enter keeps the others). |
| `devenv secret-get NAME` | host | Prints one secret from Infisical (`GITHUB_GEJ_MACHINE_PAT` or `CLAUDE_CODE_OAUTH_TOKEN`). sbx runs it; you don't need to. |
| `devenv tailscale-setup` | host | Installs Tailscale from Tailscale's apt repository, starts tailscaled, and signs the machine in with `sudo tailscale up` (a browser sign-in, once per machine; no auth key). On WSL it first checks systemd and that Tailscale isn't running on Windows. Interactive; run it again safely. |
| `devenv emulator start\|stop\|status\|clean` | host | The opt-in Android emulator ([Android emulator](#android-emulator-opt-in)): start it (building its image and SDK volume the first time) and wait for Android to boot; stop it; report the container, boot, adb, KVM and the policy rule; remove its image, SDK volume and downloads. |
| `devenv emulator connect\|run -- CMD\|status` | sandbox, plain | Connect adb to the host's emulator and print its serial; connect and run CMD with `ANDROID_SERIAL` set, one run at a time; say whether it can be reached and why not. |

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

Claude Code, Firstmate and `gh` are not pinned: Claude Code updates itself,
Firstmate updates automatically (next section), and `provision.sh` installs
GitHub's current `gh` release from GitHub's own apt repository
(`cli.github.com`), so every sandbox create gets the latest one.

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
~/devenv/provision.sh --plain            # add --yes to skip the apt prompts
```

It installs the same pinned tools into `~/.local` (on x86_64 also `adb` and the
Android build toolchain: the JDK in `~/.local/share/jdk` and Google's SDK
packages in `~/.local/share/android-sdk`), installs `gh` from
GitHub's apt repository (adding its keyring and source), installs Node
`NODE_VERSION` if node is missing or older than `NODE_MIN_VERSION`, installs
Claude Code with its official installer if missing (the one documented
exception to checksum pinning), clones Firstmate to `~/dev/firstmate`, links
the skills into `~/.claude/skills`, and writes `~/.config/devenv/env.sh`,
sourced from `~/.bashrc`. Git identity is left alone unless you pass
`--git-identity bot`. In plain mode devenv runs from the checkout itself, and
the workspace is `~/dev` (`PLAIN_WORKSPACE_DIR`).

## Layout

```
sbxenv.yaml            sbx layer: kit, workspace, env, bindings, lifecycle
kits/devenv/           v2 sandbox kit (extends claude; clones devenv; entrypoint devenv-entry)
dev/                   the sandbox workspace (gitignored; created by host-prepare)
provision.sh           portable installer: --sbx | --plain
devenv.conf            non-secret settings
versions.env           every pin and sha256
bin/                   devenv CLI and the entrypoint shim
lib/                   shared shell code; lib/cmd/ has one file per subcommand
agents/claude/         everything Claude-specific (status line, overlay, CLAUDE.md, hooks)
android/emulator/      the opt-in host emulator's image: Dockerfile and launch.sh
firstmate/config/      starting copy of Firstmate's config
firstmate/data/        starting copy of Firstmate's data (this project's own registration)
herdr/                 herdr config, and its Claude detection rules (see below)
skills/                grill-me and grilling, verbatim
tests/                 container smoke test, sbx simulation, status line identity test, secrets tests (fakes, real keyring), Tailscale setup tests (fakes), emulator tests (fakes, real image), Android toolchain tests (fakes), fixtures
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
- **Claude says "Not logged in · Please run /login" in a background session
  or the first mate.** `devenv doctor` fails with "a stored claude.ai login"
  or "Claude's daemon has no CLAUDE_CODE_OAUTH_TOKEN". Run `devenv start`
  (it moves the login aside), then `claude daemon stop --any` (this ends
  background sessions) and start Claude again.
- **Claude asks to `/login` or gets HTTP 401.** Run `devenv doctor` inside the
  sandbox. `CLAUDE_CODE_OAUTH_TOKEN is not set` means the custom secret didn't
  reach it: check the `devenv host-prepare` output of `sbx env run`, then
  recreate. `SBX_CRED_ANTHROPIC_MODE=apikey` means a stored `anthropic`
  secret outranks the token: remove it (`sbx secret ls`) and recreate. A
  401 with the variable set means the setup-token expired or was revoked: make
  a new one with `claude setup-token` on the host, paste it into
  `CLAUDE_CODE_OAUTH_TOKEN` on the Infisical website, and run `clear`.
- **`keyring locked; run sbx env run`** (from `devenv doctor`, or in sbx's
  daemon log when a secret refresh fails): the keyring locked when WSL
  restarted. `sbx env run` opens the window that unlocks it. If host-prepare
  says no window can open (no `DISPLAY` or `WAYLAND_DISPLAY`), run
  `sbx env run` from a terminal that can open windows (a WSLg terminal or a
  desktop session).
- **`keyring entry missing`**: this machine has no Infisical login yet, or
  only part of one. Run `~/devenv/bin/devenv secrets-init`.
- **`no Secret Service answers`**: no keyring is reachable on the session
  bus. Check that gnome-keyring is installed and running
  (`busctl --user list | grep org.freedesktop.secrets`).
- **`Infisical rejected the sbx-host login (HTTP 401)`**: a wrong client ID
  or client secret, a revoked client secret, or a lockout after 3 failed
  logins. If you just retried after a failure, wait 5 minutes (or Reset All
  Lockouts on the website) before trying again. For a revoked or lost client
  secret, see [A new machine](#a-new-machine) (last paragraph).
- **`sbx-host may not read … (HTTP 403)`**: add `sbx-host` to the agent
  project as Viewer (A new machine, step 2).
- **`Infisical has no … (HTTP 404)`**: a wrong project ID, or the secret isn't
  in environment `dev` at path `/` under that exact name.
- **`GitHub rejects GITHUB_GEJ_MACHINE_PAT (HTTP 401)`**: the token expired or
  was revoked. Make a new classic `repo` token for `gej-machine` and paste it
  into `GITHUB_GEJ_MACHINE_PAT` on the Infisical website.
- **`plain-text secret files left over`**: the old
  `~/.config/devenv/secrets/` from before Infisical. Delete it once the new
  path works (docs/SECRETS.md S13).
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
- **Tailscale on the host.** Run `~/devenv/bin/devenv doctor`: each failing
  line in its Tailscale part says how to fix it. On WSL, Tailscale traffic
  that doesn't work at all usually means Tailscale also runs on Windows
  ([Tailscale](#tailscale)).
- **`gh` is Ubuntu's older release** (`gh --version` says `Ubuntu`, and
  `gh api --slurp` is an unknown flag). Either the sandbox was created before
  devenv installed `gh` from GitHub, or `provision.sh` warned at create that
  it couldn't install it from `cli.github.com` (the create output or sbx's
  daemon log says why). Fix the cause, then rebuild the sandbox.
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
- **A Gradle build says an SDK package is missing, or that licences have not
  been accepted.** The project wants a platform or build-tools that devenv
  doesn't pin (often the Android Gradle Plugin's default build-tools after an
  upgrade): `sdkmanager --licenses`, then `sdkmanager "<package>"`, or pin it
  in devenv (`devenv bump android-build-tools <version>`).
- **`devenv emulator` in the sandbox says the network policy doesn't let it
  reach `localhost:15555`.** On the host, once:
  `sbx policy allow network localhost:15555`. **"no emulator answers"**: start
  it on the host, `~/devenv/bin/devenv emulator start`. On the host,
  `devenv emulator status` and `docker logs devenv-android-emulator` show the
  rest; `devenv emulator stop`, then `start`, gives a fresh device.
- Logs: `~/.cache/devenv/start.log`, `/var/log/sbx-kit-startup.log`,
  `~/.cache/devenv/herdr-server.log`.

## Roadmap (not built yet)

- Later secrets work ([docs/SECRETS.md](docs/SECRETS.md) §12): GitHub App
  tokens instead of the `gej-machine` PAT, SSH for git, and wiring
  Firstmate's typesafe dispatch.
- A GitHub permission system for agents: rulesets or a bot bypass list, or a
  GitHub App with short-lived tokens through host-prepare's `github` secret
  (a `secret-get`-style command) and a short `SECRET_REFRESH_GITHUB`.
- Worker effort and model profiles in Firstmate's `config/crew-dispatch.json`.
- A second worker harness (e.g. Codex): `config/crew-harness` plus its install.
- Bumping herdr past 0.8.0 once Firstmate verifies newer versions.
- v3 kits, once a v3 Claude workload is available to build on: a v3 kit can
  declare where Claude reads skills, so sbx's shared store could replace the
  links.
