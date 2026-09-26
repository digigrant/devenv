# Working on devenv

devenv rebuilds the owner's agent sandbox (`sbx` + Firstmate + herdr + Claude
Code). The current design, and the rules for agents, are in `docs/SPEC.md`
(read §0 first). Status, open work, and why things changed from the original
spec: `docs/HANDOFF.md`. Usage: `README.md`.

## Where you are

- Inside the sandbox, the environment runs from the clone at
  `~/fm-projects/devenv` (`$DEVENV_DIR`). Work in your own worktree on a
  branch; never edit, commit in, or switch the branch of that clone.
- Deliver by PR as `gej-machine`. Never merge; the owner reviews, merges and
  pulls on the host.

## Code that runs on the host

The owner's host runs `sbxenv.yaml` (lifecycle hook, secret commands),
`kits/devenv/spec.yaml`, and the host commands of `bin/devenv`
(`host-prepare`, `doctor`: `lib/cmd/host-prepare.sh`, `lib/cmd/doctor.sh`).
Say so in the PR when you change any of them. Host code must never read or
run anything from the workspace `dev/`, which the sandbox can write.

## Rules

- No secrets in the repo. Never allow or contact `herdr.dev`. Never put
  shell-completion scripts in `/etc/sandbox-persistent.sh`.
- `agents/claude/statusline-command.sh` and `skills/*/SKILL.md` are the
  owner's files, kept byte-for-byte; don't edit them.
- Scripts are bash with `set -euo pipefail`, safe to run repeatedly, and
  shellcheck-clean. No hardcoded `/home/<user>` paths outside docs and test
  fixtures. Pins and checksums change only through `devenv bump`.
- Keep `README.md`, `docs/HOST-VERIFY.md` and the PR description in step with
  the code.

## Checks

```sh
./bin/devenv test --no-containers   # status line identity + shellcheck, seconds
./bin/devenv test                   # plus provisioning in ubuntu 24.04/26.04 and an sbx simulation (~10 min, Docker)
```
