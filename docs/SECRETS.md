# devenv — Secrets manager (Infisical)

| | |
|---|---|
| **Status** | Design approved by the owner on 2026-09-27. **Built** on 2026-09-27 (branch `fm/devenv-devenv-infisical-secrets-manager-df`, PR https://github.com/digigrant/devenv/pull/5); host verification (HOST-VERIFY §8.3 onward) pending. It replaced D7's plain-text secret files; SPEC.md now describes the result. Where the build differs from this text, an **As built** note says so. |
| **Written** | 2026-09-27, from a design interview with the owner, with facts checked on the owner's host |
| **Readers** | The agent implementing it (§6), and the owner (§7, §8) |
| **Researched against** | sbx v0.45.1, Infisical CLI 0.43.137, Infisical Cloud (US), Ubuntu 26.04 on WSL2 |

---

## 0. Rules for the implementing agent

1. **The decisions in §4 are settled.** Don't reopen them. If a probe (§5) or a check fails and this document has no answer, stop and ask the owner: explain the issue in plain terms, give the options, and recommend one.
2. **You can't run `sbx`, reach the owner's keyring, or log in to Infisical.** Build and test what you can in the sandbox. Everything else goes into [HOST-VERIFY.md](HOST-VERIFY.md) §8 and the PR description as exact host commands with the expected output.
3. The repo rules in [AGENTS.md](../AGENTS.md) and SPEC §0 and §10 apply. The code this adds runs on the host: say so in the PR.
4. **Never handle a secret value yourself,** not even in a test. Tests use fakes (§6.9).

## 1. Goal

Move the Claude setup-token and the `gej-machine` GitHub token out of the plain-text files in `~/.config/devenv/secrets/` and into Infisical, with these properties:

- **Agents see only placeholders.** Inside the sandbox there is no secret value, no Infisical token, certificate or CLI. sbx's proxy swaps in the real value on the way out, as it does today.
- **No secret value is written to disk in plain text,** passed on a command line, or left in shell history, on the host or in the sandbox. The single exception is §4 S5: each host keeps its one Infisical login in the OS secret store.
- **Reproducible on any Linux host.** A new machine needs one browser step (creating its client secret) and one command (`devenv secrets-init`). §7 walks through it.
- **Rotating a token is one paste** into the Infisical website. Every machine picks it up within 55 minutes (the refresh, S7).

## 2. Threat model

Assume an agent can be **hijacked through prompt injection**, from repo content, issues or web pages. It will then try to exfiltrate whatever it can read, and misuse whatever it can reach.

Hiding a value doesn't stop misuse. sbx attaches the GitHub token to every request the agent sends to `github.com` or `api.github.com`. What an agent can do with a credential is limited only by the credential's own scope (§11).

## 3. Facts (checked on the owner's host, 2026-09-26/27)

**sbx**
- **sbx stores command text, never values.** For a `--command` source, sbx stores only the command text, for both service secrets and custom secrets. Tested with a command printing a 2,000-character marker: the value appeared nowhere under `~/.config`, `~/.local`, `~/.cache` or `/tmp`. The command text is stored twice:
  - age-encrypted in `~/.config/com.docker.sandboxes/…/secretpass`;
  - in plain text in `~/.local/state/sandboxes/sandboxes/sandboxd/runtimes/<sandbox>.json`, under `Spec/Credentials/Sources/<name>/source`.

  **So a command must never contain a secret.** Resolved values live in sandboxd's memory and are refreshed according to `--refresh` (default `55m` for a service secret, but `on-demand`, every use, for a custom secret: checked on the host with `sbx secret ls --json` on 2026-09-28).
- **`sbxenv.yaml` `secrets.<service>.command` is stored the same way:** the running `dev` sandbox records `github` as `{type: command, source: cat "$HOME/.config/devenv/secrets/github", refresh: 55m}`.
- **Command sources run from a temporary directory on the host** (SPEC §2.2), so they need absolute paths. sbx's own note: "Put any required environment variables directly in the command or wrapper script."
- **The daemon can probably reach the keyring.** sandboxd (`sbx daemon start`) has `DBUS_SESSION_BUS_ADDRESS`, `XDG_RUNTIME_DIR` and `WSL_INTEROP` in its environment, so a command it runs should reach the Secret Service. Probe P3 confirms this.
- **The global `anthropic` secret is OAuth, not a value.** sbx lists it as `(oauth configured)`, from the older `claude-dev` setup. Global secrets also reach `dev`, and this one masks the setup-token (§11). Removing it is the owner's host action, not devenv's (§4 S11).

**Infisical**
- **The CLI's own login offers weak protection when logged in as a user:**
  - Its login is kept in a file vault (`~/infisical-keyring/`) that opens without a passphrase (`INFISICAL_VAULT_FILE_PASSPHRASE` is unset, and a non-interactive fetch worked).
  - Every fetch writes an AES-encrypted copy of the whole folder to `~/.infisical/secrets-backup/`, and the decryption key sits in that same vault.

  Whether it does the same when authenticated as a machine identity is **unknown**; probe P2 finds out.
- **The CLI accepts credentials from the environment:** `INFISICAL_UNIVERSAL_AUTH_CLIENT_ID`, `INFISICAL_UNIVERSAL_AUTH_CLIENT_SECRET` and `INFISICAL_TOKEN`. They don't have to be passed as flags.
- **The free plan limits access control:** 3 projects and 5 identities. Custom roles and trusted-IP lists are paid features, so a machine identity's access is per project, using a built-in role such as Viewer.
- **How Universal Auth works:**
  - An identity has one client ID and can have several client secrets, each revocable on its own.
  - Access tokens last 30 days by default. The TTL (lifetime) is configurable.
  - Lockout is on by default: 3 failed logins lock the identity for 5 minutes. **Anyone who has the client ID can trigger that lockout.**
- **Rejected Infisical alternatives:**
  - `infisical secrets agent-proxy connect` puts an `INFISICAL_TOKEN` in the agent's environment.
  - `agent-proxy run` sandboxes with bubblewrap instead of sbx.
  - `infisical agent-vault` would put a session token and a certificate in the sandbox, and would chain a second TLS-intercepting proxy behind sbx's, which neither tool documents.

**Other**
- **The `gej-machine` token is narrow.** It's a classic PAT with scope `repo` only and Write (not Admin) access to 6 `digigrant/*` repos. `digigrant` is a free personal account, so branches of its private repos (`claude-shared`, `jai-notes`) can't be protected.
- **Firstmate's typesafe dispatch** reads `TYPESAFE_API_KEY` and sends it only as a request header to `https://api.typesafe.ai`. sbx's placeholder swap therefore works for it.
- **`secret-tool` isn't installed on the host yet.** It comes in the `libsecret-tools` package. `gnome-keyring-daemon` is running under WSL, but no keyring exists yet.

## 4. Decisions

| # | Decision |
|---|---|
| S1 | **Threat model:** a hijacked agent (§2). |
| S2 | **Only sbx's proxy injects credentials.** Infisical is the source on the host, read by `command:` (`sbxenv.yaml`) or `--command` (`host-prepare`). Nothing from Infisical enters the sandbox. **As built (2026-09-28):** only `--command`, since both secrets are set by `host-prepare` (S9). |
| S3 | **One Infisical project for agent credentials:** the existing project that already holds `CLAUDE_CODE_OAUTH_TOKEN` and `GITHUB_GEJ_MACHINE_PAT`, environment `dev`, path `/`. It holds exactly these three: `CLAUDE_CODE_OAUTH_TOKEN`, `GITHUB_GEJ_MACHINE_PAT`, `TYPESAFE_API_KEY_FIRSTMATE`. The owner deletes `TEST`. **Rule for future secrets:** "Should an agent in a sandbox be able to use this?" Yes means this project, as a development-grade, narrowly scoped credential. No means a different project, which `sbx-host` can't read. |
| S4 | **The host logs in as the machine identity `sbx-host`** (Universal Auth), a **Viewer** on that project and nothing else. **One client secret per machine,** named after it (e.g. `wsl-desktop`, `linux-grant`). Client secrets never expire; the owner revokes a machine's secret when it is retired or lost. **Access tokens:** TTL and max TTL of 300 seconds; lockout left on. **No periodic tokens:** they still need something stored, add a renewal process, and die if a machine is off longer than the period, which means a new client secret from the website. |
| S5 | **Secret zero lives in the Secret Service.** The client ID, client secret and project ID are stored with `secret-tool` on every host (Linux only). None of them go in the repo, because the client ID alone lets anyone lock the identity out (§3). On a Linux desktop the keyring unlocks at login. On WSL or a headless host, `host-prepare` asks for the keyring password once per boot. |
| S6 | **A fetch leaves nothing behind.** `devenv secret-get NAME` prints one value on stdout. It writes no file, puts no secret on a command line, and discards its access token. It uses the Infisical CLI only if probe P2 shows that the CLI writes nothing under a machine identity; otherwise it calls the REST API with `curl`, once to log in and once to read the secret. Every fetch logs in fresh. |
| S7 | **Cache:** sbx's default `55m` refresh. Resolved values live only in sandboxd's memory. **As built (2026-09-28):** a custom secret's default is `on-demand`, so the Claude secret was fetched on every use. The owner made the refresh configurable: `SECRET_REFRESH` in `devenv.conf` (default `55m`) for every secret from Infisical, overridden per secret by `SECRET_REFRESH_CLAUDE` / `SECRET_REFRESH_GITHUB`; `host-prepare` passes the Claude one to `set-custom --refresh`. |
| S8 | **Claude:** unchanged mechanism (SPEC D8). The setup-token stays the `CLAUDE_CODE_OAUTH_TOKEN` custom secret for `api.anthropic.com`, set by `host-prepare`. Only its command changes, from `cat <file>` to `devenv secret-get CLAUDE_CODE_OAUTH_TOKEN`. |
| S9 | **GitHub:** unchanged identity (SPEC D9). `sbxenv.yaml`'s `github` command becomes `devenv secret-get GITHUB_GEJ_MACHINE_PAT`. **As built (2026-09-28, owner's decision):** `sbxenv.yaml` has no `secrets:` block any more, because it can't read `devenv.conf`'s refresh settings (it expands only `${{ env.* }}` references). `host-prepare` sets the sandbox's `github` service secret itself: `sbx secret set github --sandbox dev --command '<absolute devenv> secret-get GITHUB_GEJ_MACHINE_PAT' --refresh <SECRET_REFRESH_GITHUB or SECRET_REFRESH>`, on every `sbx env run`. `sbxenv.yaml` keeps `bindings.github`, which approves the proxy using it. `sbx env rm` still deletes it with the sandbox's scope. |
| S10 | **Typesafe:** stored in the project now, **not wired**, because Firstmate's typesafe dispatch stays out of scope (SPEC §1). Wiring it later takes a `host-prepare` custom secret (`TYPESAFE_API_KEY` for `api.typesafe.ai`) and a network allowance for that host. |
| S11 | **Scope: the devenv `dev` sandbox only,** with sandbox-scoped secrets as today. devenv never touches `claude-dev`, other sandboxes, global secrets (including the global `anthropic` OAuth) or global sbx settings (including SSH agent forwarding). **Added 2026-09-29:** that global OAuth reaches `dev`, makes the proxy override the setup-token and seeds a stored login that breaks Claude's daemon (§11). devenv handles the sandbox side (it moves the seeded login aside); whether to remove the global secret with `sbx secret rm anthropic` is the owner's call on the host, since it also signs `claude-dev` out. |
| S12 | **Network policy unchanged.** Infisical's docs (`infisical.com`) stay reachable from `dev`; the sandbox never needs Infisical's API. |
| S13 | **Cleanup, once the new path works on a host:** delete `~/.config/devenv/secrets/`; revoke the old `gej-machine` PAT; delete `~/.infisical/secrets-backup/` and run `infisical logout`. The owner manages secrets on the website. |
| S14 | **The owner does by hand:** the Infisical website steps, replacing both tokens (a new `claude setup-token` and a new `gej-machine` PAT, `repo` scope, 90 days), and a ruleset on `digigrant/firstmate`'s `main` like the one on `devenv`. |

## 5. Probes before building (host; owner runs them from HOST-VERIFY §8)

| # | Question | Decides | Result (owner, 2026-09-27) |
|---|---|---|---|
| P1 | Can `secret-tool` store and look up an entry on WSL? What happens when no keyring exists, and after a WSL restart (locked)? | How `secrets-init` creates the keyring, and how `host-prepare` unlocks it | **Pass.** The first `secret-tool store` asked for the new keyring's password in a **pop-up window** (the Secret Service's prompter under WSLg), not in the terminal. After `wsl --shutdown` the keyring is **locked**, and the next lookup opened a pop-up asking to unlock it, then printed the value. |
| P2 | Logged in as `sbx-host`, does `infisical secrets get` write anything under `$HOME`? | CLI or `curl` in `secret-get` (S6) | **No result**: at the time it wasn't clear where on the website the three values come from (README and HOST-VERIFY §8.1 now say). `secret-get` uses `curl` (S6's other branch), which meets S6 whatever P2 shows; a later P2 run is informational only. |
| P3 | Can a command that sandboxd runs read the Secret Service? | Whether `secret-get` must set `DBUS_SESSION_BUS_ADDRESS` itself; if even that fails, stop and ask | **Pass**, as is, without setting `DBUS_SESSION_BUS_ADDRESS`. The §6.4 default stays (harmless). |

## 6. What to build

### 6.1 `devenv.conf`

New non-secret settings:

```sh
INFISICAL_DOMAIN=https://app.infisical.com   # the Infisical instance
INFISICAL_ENV=dev                             # environment slug
INFISICAL_PATH=/                              # folder
SECRET_GITHUB=GITHUB_GEJ_MACHINE_PAT          # Infisical names
SECRET_CLAUDE=CLAUDE_CODE_OAUTH_TOKEN
```

The project ID, client ID and client secret are **not** settings. They live in the keyring (§6.2).

### 6.2 Keyring entries

Three `secret-tool` entries with attributes `service devenv-infisical key <k>`, where `<k>` is `client-id`, `client-secret` or `project-id`. Use labels such as `devenv Infisical client secret`. Always read with `secret-tool lookup`. Always write with `secret-tool store`, which reads the value from stdin, never from a flag.

**Test hook:** `DEVENV_KEYRING_SERVICE`, default `devenv-infisical`, overrides the `service` attribute. Setting it to an unused name lets HOST-VERIFY simulate missing entries without deleting the real ones, in the same way `DEVENV_EXTRA_WORKSPACES` simulates workspaces.

### 6.3 `devenv secrets-init` (host, interactive)

- **Refuses outside a host shell:** inside a sandbox, or when stdin isn't a TTY.
- **Checks prerequisites:** `secret-tool` is present (otherwise print the `apt` command) and a Secret Service answers. When no keyring exists, it creates one with a password, as P1 showed works.
  - **As built:** it also needs `busctl` (the `systemd` package) and `jq`. It doesn't create the keyring itself: P1 showed that the first `secret-tool store` makes the Secret Service open a window asking for the new keyring's password, so `secrets-init` says so and waits for it. A locked keyring is unlocked first, as in `host-prepare`. Enter at a prompt keeps an entry that already exists, and the test fetch stops at the first failure (one failed login, not two).
- **Prompts for the values** with echo off (`read -rs`): project ID, client ID, client secret. Each is stored at once, piped into `secret-tool store`.
- **Runs a test fetch** for `$SECRET_GITHUB` and `$SECRET_CLAUDE` and prints only the name, the length and a shape check, e.g. `GITHUB_GEJ_MACHINE_PAT: ok (40 chars, ghp_…)` or `CLAUDE_CODE_OAUTH_TOKEN: ok (…, sk-ant-oat01-…)`.
- **Can be run again safely.** Running it again replaces the entries, which is how a machine gets a new client secret.

### 6.4 `devenv secret-get NAME` (host, non-interactive; what sbx runs)

- **Output contract:** the value on stdout and nothing else. Messages go to stderr; any failure exits non-zero.
- **Reading the keyring:** read the three entries into shell variables. If the keyring is locked or an entry is missing, fail with one clear line, e.g. `devenv: keyring locked; run sbx env run (host-prepare unlocks it)`. Never prompt: sandboxd has no TTY.
- **The fetch:**
  1. Log in (Universal Auth) and hold the access token in a variable.
  2. Read one secret, `NAME`, from `$INFISICAL_ENV` at `$INFISICAL_PATH` in the project.
  3. Print it.
- **No secrets on a command line and no files:**
  - `curl`: pass the login body and the `Authorization` header on stdin (`--data @-`, `-H @-`) or through `--config -`, never as arguments.
  - CLI: use the environment variables from §3.
  - No temporary files, no `set -x`, `--max-time` on every request.
- **Environment:** absolute paths only. If `DBUS_SESSION_BUS_ADDRESS` is unset, default it to `unix:path=$XDG_RUNTIME_DIR/bus`, depending on P3.
- **Accepts only the configured names** (`$SECRET_GITHUB`, `$SECRET_CLAUDE`). The identity can't read anything else anyway; this is a guard against typos.
- **Never reads or runs anything from `dev/`** (SPEC §10.3).
- **The REST endpoints** (if P2 rules out the CLI): check them against the current Infisical API reference. They are `POST /api/v1/auth/universal-auth/login`, then the single-secret read (`/api/v4/secrets/{name}` or `/api/v3/secrets/raw/{name}`, with the project ID, environment and path as parameters).
- **As built:** `curl`, since P2 has no result. Login: `POST $INFISICAL_DOMAIN/api/v1/auth/universal-auth/login` with `{clientId, clientSecret}` → `accessToken`. Read: `GET $INFISICAL_DOMAIN/api/v4/secrets/{name}?projectId=…&environment=…&secretPath=…&viewSecretValue=true&expandSecretReferences=true&includeImports=true` → `secret.secretValue` (both checked against Infisical's API reference on 2026-09-27). The output is the value and a newline, as `cat` of the old secret files gave sbx.
- **As built, the locked check:** a `secret-tool lookup` on a locked keyring makes the Secret Service open its unlock window, and `secret-tool search` asks for every secret. So `secret-get` asks the Secret Service's `SearchItems` method (`busctl --user … SearchItems`), which reports each entry as unlocked, locked or missing without loading a secret or prompting. Checked against gnome-keyring 50 in a container, watching the D-Bus calls (`tests/keyring.sh`). The lookups that follow have a 10-second timeout as a backstop.

### 6.5 `sbxenv.yaml`

```yaml
secrets:
  github:
    command: '"$HOME/devenv/bin/devenv" secret-get GITHUB_GEJ_MACHINE_PAT'
```

- **The path:** the checkout is `~/devenv` on every host (README, HOST-VERIFY step 2). If sbx expands `${{ env.fileDir }}` inside `command:`, use that instead of `$HOME/devenv`.
- **Update the comment block** above `secrets:`.
- **The change takes effect on the next create,** like any secret change (SPEC §2.2).
- **As built:** `command: '"${{ env.fileDir }}/bin/devenv" secret-get GITHUB_GEJ_MACHINE_PAT'`. Docker's environment-file reference says the directory references expand in any YAML value (sbx ≥ 0.43.0); HOST-VERIFY §8.3 checks the command sbx stored.
- **As built (2026-09-28):** the `secrets:` block is gone; `host-prepare` sets the `github` secret (S9). A change to its refresh then applies on the next `sbx env run`, not only at the next create.

### 6.6 `host-prepare`

- **Unlock first.** When the keyring is locked, prompt for its password on the TTY and unlock it, as worked out in P1. Without a TTY, fail with instructions.
  - **As built (P1):** the unlock prompt is the Secret Service's own pop-up window, so `host-prepare` never reads the password. When `SearchItems` reports the keyring locked, it runs a `secret-tool lookup` (value to `/dev/null`), which opens that window, and waits up to 3 minutes (the hook's timeout is 5). With no display the window can't open, the lookup fails at once, and `host-prepare` stops with instructions. When the keyring is unlocked it does nothing.
  - **As built:** after a failed fetch it doesn't try the second secret, so a wrong client secret costs one failed login per run, not two.
- **Replace the secret-file checks with:**
  - the three keyring entries exist;
  - `devenv secret-get` succeeds for `$SECRET_GITHUB`, and for `$SECRET_CLAUDE` in token mode;
  - the GitHub value authenticates as `$BOT_LOGIN`, reusing the existing check but passing the token to `curl` on stdin, never through a file;
  - the Claude value looks like `sk-ant-oat01-`.

  All values stay in variables and are never printed.
- **The Claude custom secret** keeps the same `set-custom` call, placeholder file and `CLAUDE_AUTH` handling. Only `--command` changes, to `'"<absolute devenv>" secret-get CLAUDE_CODE_OAUTH_TOKEN'`.
  - **As built (2026-09-28):** the placeholder file is gone. sbx keeps one custom secret per env var in a scope and refuses a second placeholder for it, so a host file that no longer matched sbx broke `sbx env run`. `host-prepare` now reads the placeholder sbx holds (`sbx secret ls --sandbox dev --json`), reuses it, and makes one only when there is none; it adds `--refresh` (S7). `CLAUDE_AUTH=login` removes the secret with `sbx secret rm --sandbox dev --host api.anthropic.com --env CLAUDE_CODE_OAUTH_TOKEN -f` (without `--sandbox`, rm looked only at global secrets and removed nothing).
- **The GitHub secret** (as built, 2026-09-28): `host-prepare` sets it with `sbx secret set github --sandbox dev --command … --refresh …` before the Claude secret (S9), and stops with sbx's error line if that fails. The check that `sbxenv.yaml`'s `github` command names `$SECRET_GITHUB` is gone with that command.
- **Warn** while `~/.config/devenv/secrets/` still exists: `plain-text secret files left over; delete them (docs/SECRETS.md S13)`.

### 6.7 `doctor`

- **On the host:**
  - Replace SPEC §6.12's "Secret files" checks with the `host-prepare` checks above, plus the existing token-expiry note.
  - Warn about leftovers in `~/.config/devenv/secrets/` and a non-empty `~/.infisical/secrets-backup/`.
  - Rework AC13's secret-file case: doctor must **fail** when a keyring entry is missing or the fetch fails, tested with `DEVENV_KEYRING_SERVICE` (§6.2). The other AC13 cases stay.
- **In the sandbox:** unchanged. Placeholders only.

### 6.8 Docs

- **SPEC:**
  - D7, §2.2 (the facts in §3 here), §4.1 flow, §4.2 table, §6.1, §6.9, §6.12;
  - AC1, AC13 and AC14 (AC14's `git grep` gains nothing new, since the IDs never enter the repo);
  - §10 invariants: add §10 here;
  - §1 and §11: this document replaces the "secrets manager" items.
- **README:** Quick start, Claude sign-in, Troubleshooting (locked keyring, lockout, revoked client secret) and Roadmap. Add a **new-machine section** that follows §7.
- **HOST-VERIFY:** rewrite steps 3 and 4 around `devenv secrets-init`; §8 becomes the checks in §8 here.
- **HANDOFF:** record the change.

### 6.9 Tests (`devenv test`)

- **Harness:** shellcheck for everything new. Test `secret-get` with a fake `secret-tool` and a fake `infisical` or `curl` earlier on `PATH`, using dummy values and a temporary `HOME`.
- **Assertions:**
  - stdout is exactly the value;
  - no file under the temporary `HOME` or `$TMPDIR` changes;
  - a locked or missing keyring and an HTTP 401 each exit non-zero with one stderr line;
  - an unconfigured name is refused.
- **By code review, not tests:** no secret ever appears as an argument.

## 7. A new Linux host, start to finish (owner)

**Already set up, once, on the Infisical website:** the agent project (S3) and `sbx-host` (S4).

**On the new machine, once:**
1. Install `sbx` and `libsecret-tools`, and clone devenv to `~/devenv` (README).
2. **Create this machine's key:** on the Infisical website, open `sbx-host`, go to Universal Auth and create a client secret named after the machine. Infisical shows it once. This is the only browser step, and it happens once per machine.
3. **Store it:** run `~/devenv/bin/devenv secrets-init` and paste the project ID, client ID and client secret at its prompts. It prints `ok` for each secret, and the website tab can be closed.
4. **Start:** `cd ~/devenv && sbx env run`.

**From then on, unattended:** when an agent calls GitHub or Anthropic, sbx needs the real value. It runs `devenv secret-get` on the host, which reads the keyring, logs in to Infisical, gets a 5-minute access token, reads the one secret, hands it to sbx's memory and discards the token. This happens at most once per refresh period per secret (`SECRET_REFRESH`, 55 minutes by default; S7).

**After a reboot:** a Linux desktop needs nothing. On WSL, a pop-up window asks for the keyring password at the next `sbx env run` (`host-prepare` opens it). A host with no display can't show that window: `host-prepare` stops and says so.

**Replacing a token:** paste the new value into the Infisical website. Every machine picks it up within the refresh period (55 minutes by default).

**Retiring or losing a machine:** revoke its client secret under `sbx-host` on the website. The other machines keep working.

## 8. Migration on the current host (order matters)

1. **Owner, on the Infisical website:**
   - Create `sbx-host` (Universal Auth; access-token TTL and max TTL 300; lockout on).
   - Add it to the agent project as **Viewer**.
   - Create a client secret named after this machine (e.g. `wsl-desktop`).
   - Delete `TEST`.
2. **Owner: replace both tokens in Infisical, not on disk.**
   - Claude: `claude setup-token` in a host terminal. Paste the token into `CLAUDE_CODE_OAUTH_TOKEN` on the website, then run `clear` to wipe the terminal's scrollback.
   - GitHub: a new classic PAT for `gej-machine` (`repo` only, 90 days) goes into `GITHUB_GEJ_MACHINE_PAT`.
   - Keep the old files and the old PAT until step 6, because the running `dev` still uses them.
3. **Owner: probes P1–P3** (HOST-VERIFY §8). Paste the output into the PR.
4. **Agent: build §6** on a branch; the PR lists the host code it changes.
5. **Owner: try it.**
   1. Check out the branch.
   2. Run `devenv secrets-init`.
   3. Run `sbx env rm`, then `sbx env run --kit-arg ref=<branch>`. The `github` command only changes on create.
   4. Run the checks in HOST-VERIFY §8.
6. **Owner: clean up** (S13):
   1. Delete `~/.config/devenv/secrets/`.
   2. Revoke the old PAT in `gej-machine`'s GitHub settings.
   3. Delete `~/.infisical/secrets-backup/` and run `infisical logout`.
   4. Run `devenv doctor` again, which should show no leftover warnings.
7. **Owner, any time:** a ruleset on `digigrant/firstmate`'s `main` (PR required; no force-push or deletion). `gej-machine` has Write access only, so it can't set this up.

## 9. Acceptance (commands in HOST-VERIFY §8.3)

- **A1 — the sandbox holds only placeholders.** In `dev`, `GH_TOKEN` and `CLAUDE_CODE_OAUTH_TOKEN` are sbx placeholders. `gh api user` answers `gej-machine`, and Claude answers with `authMethod: oauth_token`. Neither is enough alone, because the proxy may be signing requests with sbx's OAuth login instead: a request to `api.anthropic.com/api/oauth/profile` with no credential must not return 200, there is no stored claude.ai login, and any running Claude daemon has `CLAUDE_CODE_OAUTH_TOKEN` (`devenv doctor` checks the last two).
- **A2 — no plain-text copy.** After S13, neither live value appears in any file under `~/.config`, `~/.local`, `~/.cache`, `~/.infisical`, `~/devenv` or `/tmp`. The check reads each value into `grep -F -f -` on stdin, so the value never appears in a command.
- **A3 — rebuilds need only the keyring.** With no secret files present, `sbx env rm` followed by `sbx env run` builds a working `dev`.
- **A4 — reboots and refreshes work.** After a WSL restart, `sbx env run` asks once for the keyring password and then works. Fetches still succeed more than an hour later, past the 55-minute refresh.
- **A5 — doctor checks the new path.** Host `devenv doctor` is all `ok` with no leftover warnings, and fails with `DEVENV_KEYRING_SERVICE=devenv-missing`.
- **A6 — no identity details in the repo.** The keyring's project ID and client ID match nothing in `git grep`; they are passed to it on stdin.
- **A7 — no secrets in commands.** By code review, no secret appears as an argument in `secret-get`, `secrets-init`, `host-prepare` or `doctor`.

## 10. Security invariants (added to SPEC §10)

1. **Nothing sensitive leaves the keyring.** No secret value and no identity detail (project ID, client ID, client secret) appears in the repo, on a command line, in shell history or in a file. The only copy at rest on a host is its Secret Service entry.
2. **Nothing from Infisical enters the sandbox.**
3. **`sbx-host` reads only the agent project,** as Viewer.
4. **Every `command:` and `--command` holds only a path and a secret name,** because sbx stores command text in plain text (§3).

## 11. Accepted risks

- **What a hijacked agent can still do with the credentials:**
  - push to any branch the rulesets leave open. That includes `main` on `claude-shared` and `jai-notes`, which can't be protected on GitHub Free, and on `firstmate` until its ruleset exists;
  - create repos under `gej-machine`, which the classic `repo` scope allows, and push code there;
  - send data to any of the ~190 hosts the network policy allows.
- **The keyring is only as safe as the host.** Anything running as the owner on an unlocked host can read it, as with any OS secret store. The keyring protects against copies of the disk, backups and other users.
- **Global sbx secrets still reach `dev`,** for example the global `anthropic` OAuth. They are outside this design (S11), but they defeat it: the proxy injects that OAuth credential on every request to `api.anthropic.com`, even one with no credential or a bogus placeholder, so the setup-token can't be observed working, and sbx's `claude` kit seeds a stored login from it. devenv moves the seeded login aside (`devenv start` and `entry`), and A1 detects the masking; removing the global secret is the owner's host action (HOST-VERIFY V1).

## 12. Later (not now)

- **GitHub App tokens:** replace the PAT with an App on selected repos, minting 1-hour installation tokens in a `secret-get`-style command under sbx's 55-minute refresh. The App's private key would live in the agent project.
- **SSH for git** (the owner's own task):
  - `gh` still needs a token for PRs and the API, so SSH adds a second credential rather than replacing one.
  - SSH agent forwarding is a global sbx setting (S11).
  - An SSH key on github.com lasts until it's removed.
- **Typesafe dispatch:** wire `TYPESAFE_API_KEY` as in S10.
