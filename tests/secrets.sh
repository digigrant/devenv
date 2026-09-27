#!/usr/bin/env bash
# devenv secret-get, secrets-init, doctor and host-prepare against fakes
# (docs/SECRETS.md §6.9): tests/fakes/{secret-tool,busctl,curl,sbx} come first
# on PATH, with dummy values, a temporary HOME and TMPDIR, and a copy of this
# working tree. No real keyring, Infisical, GitHub or sbx is touched.
#   tests/secrets.sh
# pass and fail always succeed, so `test && pass || fail` is a safe if/else.
# shellcheck disable=SC2015
set -euo pipefail

ROOT=$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)
W=$(mktemp -d)
trap 'rm -rf "$W"' EXIT
mkdir -p "$W/home" "$W/tmp" "$W/log" "$W/run"
# A copy of the working tree, so host-prepare's dev/ lands there.
(cd "$ROOT" && git ls-files -co --exclude-standard -z | xargs -0 cp --parents -t "$W/run" 2>/dev/null) \
  || cp -r "$ROOT/." "$W/run"
rm -rf "$W/run/dev"
mkdir -p "$W/devenv" && mv "$W/run" "$W/devenv/checkout"
DEV=$W/devenv/checkout/bin/devenv

# Dummy values, distinctive so a leak into an argument or a file is easy to find.
export FAKE_LOG=$W/log
export FAKE_PROJECT_ID=fake-project-5f1e0c
export FAKE_CLIENT_ID=fake-client-id-8c2d41
export FAKE_CLIENT_SECRET=fake-client-secret-91ab77
export FAKE_ACCESS_TOKEN=fake-access-token-77aa03
export FAKE_GITHUB=ghp_FAKEfakeFAKEfakeFAKEfakeFAKEfake0001
export FAKE_CLAUDE=sk-ant-oat01-FAKEfakeFAKEfakeFAKEfake0002
SENSITIVE=("$FAKE_PROJECT_ID" "$FAKE_CLIENT_ID" "$FAKE_CLIENT_SECRET" "$FAKE_ACCESS_TOKEN" "$FAKE_GITHUB" "$FAKE_CLAUDE")

fails=0
pass() { printf '  ok    %s\n' "$*"; }
fail() { printf '  FAIL  %s\n' "$*"; fails=$((fails + 1)); }

# run VAR=VALUE... -- ARGS: devenv on the host (no sandbox variables), with
# only the fakes and the system on PATH. Sets OUT, ERR, RC.
run() {
  local envs=()
  while [ "$1" != -- ]; do envs+=("$1"); shift; done
  shift
  : > "$FAKE_LOG/argv"
  rm -rf "$FAKE_LOG/unlocked" "$FAKE_LOG/kr"
  RC=0
  env -i HOME="$W/home" TMPDIR="$W/tmp" PATH="$ROOT/tests/fakes:/usr/local/bin:/usr/bin:/bin" \
    XDG_RUNTIME_DIR="$W/tmp" FAKE_LOG="$FAKE_LOG" FAKE_PROJECT_ID="$FAKE_PROJECT_ID" \
    FAKE_CLIENT_ID="$FAKE_CLIENT_ID" FAKE_CLIENT_SECRET="$FAKE_CLIENT_SECRET" \
    FAKE_ACCESS_TOKEN="$FAKE_ACCESS_TOKEN" FAKE_GITHUB="$FAKE_GITHUB" FAKE_CLAUDE="$FAKE_CLAUDE" \
    "${envs[@]}" setsid bash "$DEV" "$@" > "$W/out" 2> "$W/err" < /dev/null || RC=$?
  OUT=$(cat "$W/out"); ERR=$(cat "$W/err")
}

# tty_run INPUT VAR=VALUE... -- ARGS: like run, on a pseudo-terminal fed INPUT
# (stdout and stderr both land in OUT).
tty_run() {
  local input=$1 envs=()
  shift
  while [ "$1" != -- ]; do envs+=("$1"); shift; done
  shift
  : > "$FAKE_LOG/argv"
  rm -rf "$FAKE_LOG/unlocked" "$FAKE_LOG/kr"
  RC=0
  printf '%s' "$input" | env -i HOME="$W/home" TMPDIR="$W/tmp" PATH="$ROOT/tests/fakes:/usr/local/bin:/usr/bin:/bin" \
    XDG_RUNTIME_DIR="$W/tmp" FAKE_LOG="$FAKE_LOG" FAKE_PROJECT_ID="$FAKE_PROJECT_ID" \
    FAKE_CLIENT_ID="$FAKE_CLIENT_ID" FAKE_CLIENT_SECRET="$FAKE_CLIENT_SECRET" \
    FAKE_ACCESS_TOKEN="$FAKE_ACCESS_TOKEN" FAKE_GITHUB="$FAKE_GITHUB" FAKE_CLAUDE="$FAKE_CLAUDE" \
    "${envs[@]}" script -E never -qefc "bash $(printf '%q' "$DEV") $*" /dev/null > "$W/out" 2>&1 || RC=$?
  OUT=$(tr -d '\r' < "$W/out"); ERR=''
}

# Universal Auth logins in the last run.
logins() { grep -c '^curl .*/api/v1/auth/universal-auth/login' "$FAKE_LOG/argv" || true; }

snapshot() { find "$W/home" "$W/tmp" -printf '%p %y %s %T@\n' | sort; }

no_leak_in_args() {
  local v
  for v in "${SENSITIVE[@]}"; do
    if grep -qF -- "$v" "$FAKE_LOG/argv"; then fail "$1: a secret or identity detail appeared in a command's arguments"; return; fi
  done
  pass "$1: no secret or identity detail in any command's arguments"
}

one_line_failure() {
  local what=$1 want=$2
  if [ "$RC" -ne 0 ] && [ -z "$OUT" ] && [ "$(printf '%s\n' "$ERR" | wc -l)" = 1 ] && printf '%s' "$ERR" | grep -qF -- "$want"; then
    pass "$what: exit $RC, one stderr line ($ERR)"
  else
    fail "$what: expected a non-zero exit, no stdout and one stderr line with '$want'; got exit $RC, stdout '${OUT:0:20}', stderr: $ERR"
  fi
}

echo "secret-get"
before=$(snapshot)
run -- secret-get GITHUB_GEJ_MACHINE_PAT
if [ "$RC" = 0 ] && [ "$(cat "$W/out")" = "$FAKE_GITHUB" ] && [ "$(wc -c < "$W/out")" = $((${#FAKE_GITHUB} + 1)) ] && [ -z "$ERR" ]; then
  pass "GITHUB_GEJ_MACHINE_PAT: stdout is exactly the value and a newline, stderr empty"
else fail "GITHUB_GEJ_MACHINE_PAT: exit $RC, stderr: $ERR"; fi
no_leak_in_args "GITHUB_GEJ_MACHINE_PAT"
grep -q '^curl .*--config -' "$FAKE_LOG/argv" && grep -q '^curl .*--data-binary @-' "$FAKE_LOG/argv" \
  && pass "curl gets the login body and the read request on stdin" || fail "curl was not called with stdin input"
run -- secret-get CLAUDE_CODE_OAUTH_TOKEN
[ "$RC" = 0 ] && [ "$OUT" = "$FAKE_CLAUDE" ] && [ -z "$ERR" ] \
  && pass "CLAUDE_CODE_OAUTH_TOKEN: stdout is exactly the value" || fail "CLAUDE_CODE_OAUTH_TOKEN: exit $RC, stderr: $ERR"
no_leak_in_args "CLAUDE_CODE_OAUTH_TOKEN"
[ "$before" = "$(snapshot)" ] && pass "no file under HOME or TMPDIR changed" \
  || { fail "files under HOME or TMPDIR changed:"; diff <(printf '%s\n' "$before") <(snapshot) || true; }

run FAKE_KR_STATE=locked -- secret-get GITHUB_GEJ_MACHINE_PAT
one_line_failure "locked keyring" "keyring locked; run sbx env run"
grep -q '^secret-tool' "$FAKE_LOG/argv" && fail "locked keyring: secret-tool ran (a lookup opens the unlock window)" \
  || pass "locked keyring: only SearchItems asked, no secret-tool (never prompts)"
grep -q '^curl' "$FAKE_LOG/argv" && fail "locked keyring: Infisical was called" || pass "locked keyring: no login attempt"
run FAKE_KR_STATE=missing -- secret-get GITHUB_GEJ_MACHINE_PAT
one_line_failure "missing entries" "keyring entry missing: client-id client-secret"
run DEVENV_KEYRING_SERVICE=devenv-missing -- secret-get GITHUB_GEJ_MACHINE_PAT
one_line_failure "DEVENV_KEYRING_SERVICE=devenv-missing" "keyring entry missing: project-id client-id client-secret (service devenv-missing)"
run FAKE_KR_STATE=empty -- secret-get CLAUDE_CODE_OAUTH_TOKEN
one_line_failure "no entries" "keyring entry missing: project-id client-id client-secret (service devenv-infisical); run: ~/devenv/bin/devenv secrets-init"
run FAKE_KR_STATE=nobus -- secret-get GITHUB_GEJ_MACHINE_PAT
one_line_failure "no Secret Service" "no Secret Service answers (Failed to connect to user scope bus"
run FAKE_LOGIN_CODE=401 -- secret-get GITHUB_GEJ_MACHINE_PAT
one_line_failure "login HTTP 401" "rejected the sbx-host login (HTTP 401)"
run FAKE_READ_CODE=401 -- secret-get GITHUB_GEJ_MACHINE_PAT
one_line_failure "read HTTP 401" "(HTTP 401)"
run FAKE_READ_CODE=403 -- secret-get CLAUDE_CODE_OAUTH_TOKEN
one_line_failure "read HTTP 403" "add it to the agent project as Viewer"
run -- secret-get TEST
one_line_failure "unconfigured name" "fetches only GITHUB_GEJ_MACHINE_PAT and CLAUDE_CODE_OAUTH_TOKEN"
[ -s "$FAKE_LOG/argv" ] && fail "unconfigured name: the keyring or network was touched" || pass "unconfigured name: nothing was called"
run SANDBOX_NAME=dev -- secret-get GITHUB_GEJ_MACHINE_PAT
one_line_failure "inside a sandbox" "runs on the host"

echo "doctor --host"
run -- doctor --host
if printf '%s\n' "$OUT" | grep -q 'ok    keyring entries present' \
   && printf '%s\n' "$OUT" | grep -q 'ok    GITHUB_GEJ_MACHINE_PAT authenticates as gej-machine (HTTP 200; expires 2026-12-24 00:00:00 UTC)' \
   && printf '%s\n' "$OUT" | grep -q 'ok    CLAUDE_CODE_OAUTH_TOKEN is a setup-token'; then
  pass "keyring, GitHub account and setup-token checks pass"
else fail "doctor's secrets section: $(printf '%s\n' "$OUT" | sed -n '/^secrets/,/^devenv checkout/p')"; fi
no_leak_in_args "doctor"
run DEVENV_KEYRING_SERVICE=devenv-missing -- doctor --host
[ "$RC" = 1 ] && printf '%s\n' "$OUT" | grep -q 'FAIL  keyring entry missing' \
  && pass "DEVENV_KEYRING_SERVICE=devenv-missing: FAIL and exit 1 (A5)" || fail "doctor with missing entries: exit $RC"
run FAKE_READ_CODE=404 -- doctor --host
[ "$RC" = 1 ] && printf '%s\n' "$OUT" | grep -q 'FAIL  fetching GITHUB_GEJ_MACHINE_PAT failed: Infisical has no' \
  && pass "a failed fetch: FAIL and exit 1" || fail "doctor with a failed fetch: exit $RC"
run FAKE_LOGIN_CODE=401 -- doctor --host
[ "$RC" = 1 ] && [ "$(logins)" = 1 ] && pass "a rejected login: FAIL after one login attempt, not two (lockout after 3)" \
  || fail "doctor with a rejected login: exit $RC, $(logins) login attempts"
run FAKE_KR_STATE=locked -- doctor --host
[ "$RC" = 1 ] && printf '%s\n' "$OUT" | grep -q 'FAIL  keyring locked; run sbx env run' && ! grep -q '^secret-tool' "$FAKE_LOG/argv" \
  && pass "locked keyring: FAIL without opening the unlock window" || fail "doctor with a locked keyring: exit $RC"
mkdir -p "$W/home/.config/devenv/secrets" "$W/home/.infisical/secrets-backup" && touch "$W/home/.infisical/secrets-backup/x"
run -- doctor --host
printf '%s\n' "$OUT" | grep -q 'warn  plain-text secret files left over' && printf '%s\n' "$OUT" | grep -q 'warn  Infisical CLI backups left over' \
  && pass "leftover secret files and CLI backups: warnings" || fail "no leftover warnings"
rm -rf "$W/home/.config/devenv/secrets" "$W/home/.infisical"

echo "host-prepare"
run -- host-prepare
cmd=$(grep '^sbx secret set-custom' "$FAKE_LOG/argv" || true)
if [ "$RC" = 0 ] && printf '%s' "$cmd" | grep -qF -- "--command $W/devenv/checkout/bin/devenv secret-get CLAUDE_CODE_OAUTH_TOKEN"; then
  pass "sets the Claude custom secret to run devenv secret-get CLAUDE_CODE_OAUTH_TOKEN"
else fail "host-prepare: exit $RC, set-custom: ${cmd:-none}, stderr: $ERR"; fi
no_leak_in_args "host-prepare"
[ -d "$W/devenv/checkout/dev" ] && pass "created dev/" || fail "dev/ was not created"
run FAKE_LOGIN_CODE=401 -- host-prepare
[ "$RC" != 0 ] && [ "$(logins)" = 1 ] && ! grep -q '^sbx secret set-custom' "$FAKE_LOG/argv" \
  && pass "a rejected login: stops before sbx after one login attempt" || fail "host-prepare with a rejected login: exit $RC, $(logins) login attempts"
run FAKE_KR_STATE=locked FAKE_KR_PROMPT=accept DISPLAY=:0 -- host-prepare
[ "$RC" = 0 ] && printf '%s' "$ERR" | grep -q 'a window asks for the keyring password now' && printf '%s' "$ERR" | grep -q 'keyring unlocked' \
  && [ "$(grep -c '^secret-tool lookup' "$FAKE_LOG/argv")" -ge 1 ] && grep -q '^sbx secret set-custom' "$FAKE_LOG/argv" \
  && pass "locked keyring: a lookup opens the unlock window, then host-prepare carries on" \
  || fail "host-prepare with a locked keyring and an accepted window: exit $RC, stderr: $ERR"
run FAKE_KR_STATE=locked DISPLAY=:0 -- host-prepare
[ "$RC" != 0 ] && printf '%s' "$ERR" | grep -q 'the keyring is still locked' && ! grep -q '^sbx secret set-custom' "$FAKE_LOG/argv" \
  && pass "locked keyring, window closed: stops before sbx" || fail "host-prepare with a dismissed window: exit $RC, stderr: $ERR"
run FAKE_KR_STATE=locked -- host-prepare
[ "$RC" != 0 ] && printf '%s' "$ERR" | grep -q 'no window can ask for its password here (no DISPLAY or WAYLAND_DISPLAY)' \
  && pass "locked keyring without a display: clear instructions" || fail "host-prepare locked without a display: exit $RC, stderr: $ERR"
run FAKE_KR_STATE=missing -- host-prepare
[ "$RC" != 0 ] && printf '%s' "$ERR" | grep -q 'keyring entry missing' \
  && ! grep -q '^sbx secret set-custom' "$FAKE_LOG/argv" && pass "missing entries: stops before sbx" || fail "host-prepare with missing entries: exit $RC"
mkdir -p "$W/home/.config/devenv/secrets"
run -- host-prepare
printf '%s' "$ERR" | grep -q 'warning: plain-text secret files left over' && pass "warns about leftover secret files" || fail "no leftover warning"
rm -rf "$W/home/.config/devenv/secrets"

echo "secrets-init"
run -- secrets-init
one_line_failure "without a terminal" "secrets-init is interactive"
tty_run "$FAKE_PROJECT_ID"$'\n'"$FAKE_CLIENT_ID"$'\n'"$FAKE_CLIENT_SECRET"$'\n' FAKE_KR_STATE=empty -- secrets-init
if [ "$RC" = 0 ] && printf '%s\n' "$OUT" | grep -qF "GITHUB_GEJ_MACHINE_PAT: ok (${#FAKE_GITHUB} chars, ghp_…)" \
   && printf '%s\n' "$OUT" | grep -qF "CLAUDE_CODE_OAUTH_TOKEN: ok (${#FAKE_CLAUDE} chars, sk-ant-oat01-…)"; then
  pass "a new machine: stores the three values and test-fetches both secrets"
else fail "secrets-init on a new machine: exit $RC, output: $OUT"; fi
[ "$(cat "$FAKE_LOG/kr/devenv-infisical/project-id")" = "$FAKE_PROJECT_ID" ] \
  && [ "$(cat "$FAKE_LOG/kr/devenv-infisical/client-id")" = "$FAKE_CLIENT_ID" ] \
  && [ "$(cat "$FAKE_LOG/kr/devenv-infisical/client-secret")" = "$FAKE_CLIENT_SECRET" ] \
  && pass "each value reached secret-tool store exactly, on stdin" || fail "the stored values differ from the typed ones"
no_leak_in_args "secrets-init"
printf '%s\n' "$OUT" | grep -qF -e "$FAKE_GITHUB" -e "$FAKE_CLAUDE" && fail "secrets-init printed a secret" || pass "secrets-init printed no secret"
tty_run "$FAKE_PROJECT_ID"$'\n'"$FAKE_CLIENT_ID"$'\n'"fake-wrong-secret"$'\n' FAKE_KR_STATE=empty -- secrets-init
[ "$RC" != 0 ] && printf '%s\n' "$OUT" | grep -qF "GITHUB_GEJ_MACHINE_PAT: FAILED: Infisical rejected the sbx-host login (HTTP 401)" && [ "$(logins)" = 1 ] \
  && pass "a wrong client secret: FAILED after one login attempt" || fail "secrets-init with a wrong client secret: exit $RC, $(logins) logins, output: $OUT"
tty_run $'\n\n\n' -- secrets-init
[ "$RC" = 0 ] && [ "$(printf '%s\n' "$OUT" | grep -c 'kept the stored')" = 3 ] && ! grep -q '^secret-tool store' "$FAKE_LOG/argv" \
  && printf '%s\n' "$OUT" | grep -qF "GITHUB_GEJ_MACHINE_PAT: ok" && pass "run again: Enter keeps each stored entry" \
  || fail "secrets-init run again with Enter: exit $RC, output: $OUT"

echo
if [ "$fails" = 0 ]; then echo "secrets: PASS"; else echo "secrets: FAIL ($fails)"; exit 1; fi
