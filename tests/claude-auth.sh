#!/usr/bin/env bash
# Claude sign-in in token mode (V1): a stored claude.ai login makes Claude's
# daemon drop CLAUDE_CODE_OAUTH_TOKEN, so `devenv start` and `devenv entry`
# move it out of ~/.claude/.credentials.json, and `devenv doctor` fails while
# one exists or while a running daemon lacks the variable. Runs devenv against
# a temporary HOME, TMPDIR and workspace, with the fakes first on PATH and
# DEVENV_HOST_ROOT standing a folder in for / (a fake /proc). Dummy values
# only; no real Claude, credentials, daemon or sbx is touched.
#   tests/claude-auth.sh
# pass and fail always succeed, so `test && pass || fail` is a safe if/else.
# shellcheck disable=SC2015
set -euo pipefail

ROOT=$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)
W=$(mktemp -d)
trap 'rm -rf "$W"' EXIT
mkdir -p "$W/tmp" "$W/log"
DEV=$ROOT/bin/devenv
HOME_DIR=$W/home
CRED=$HOME_DIR/.claude/.credentials.json
ASIDE=$CRED.devenv-stored-login
HR=$W/root
SBX=(IS_SANDBOX=1 SANDBOX_NAME=dev WORKSPACE_DIR="$W/ws")
TOKEN=sbx-cs-devenv-0123456789abcdef0123456789abcdef

fails=0
pass() { printf '  ok    %s\n' "$*"; }
fail() { printf '  FAIL  %s\n' "$*"; fails=$((fails + 1)); }

# run VAR=VALUE... -- ARGS: devenv without a terminal. Sets OUT, ERR, RC.
# `entry` runs with DEVENV_ENTRY=shell, which ends at once on empty input.
run() {
  local envs=()
  while [ "$1" != -- ]; do envs+=("$1"); shift; done
  shift
  RC=0
  env -i HOME="$HOME_DIR" TMPDIR="$W/tmp" PATH="$ROOT/tests/fakes:/usr/local/bin:/usr/bin:/bin" \
    FAKE_LOG="$W/log" DEVENV_HOST_ROOT="$HR" DEVENV_ENTRY=shell "${envs[@]}" \
    timeout 120 bash "$DEV" "$@" > "$W/out" 2> "$W/err" < /dev/null || RC=$?
  OUT=$(cat "$W/out"); ERR=$(cat "$W/err")
}

# The login sbx's claude kit seeds: sentinels, and scopes that don't allow
# inference. A second entry stands for a login that must survive.
KIT_LOGIN='{"accessToken":"sk-ant-oat01-proxy-managed","refreshToken":"sk-ant-ort01-proxy-managed","expiresAt":4102444800000,"scopes":null,"subscriptionType":"pro"}'
seed() {  # seed JSON: a fresh HOME whose credentials file holds JSON (none when empty)
  rm -rf "$HOME_DIR" "$W/ws" "$HR"
  mkdir -p "$HOME_DIR/.claude" "$W/ws" "$HR/proc"
  [ -z "${1:-}" ] || { printf '%s\n' "$1" > "$CRED"; chmod 600 "$CRED"; }
}
seed_login() { seed "{\"claudeAiOauth\":$KIT_LOGIN}"; }
seed_login_and_mcp() { seed "{\"claudeAiOauth\":$KIT_LOGIN,\"mcpOAuth\":{\"server\":{\"accessToken\":\"dummy-mcp\"}}}"; }

has_login() { jq -e '.claudeAiOauth.refreshToken' "$1" >/dev/null 2>&1; }
# The accounts section of doctor's report.
accounts() { printf '%s\n' "$OUT" | sed -n '/^accounts$/,/^herdr and Firstmate$/p'; }
acc_has() { accounts | grep -qF -- "$1"; }

# A fake process in the fake /proc: fake_proc PID ENV-ASSIGNMENT|- ARG...
fake_proc() {
  local pid=$1 tok=$2
  shift 2
  mkdir -p "$HR/proc/$pid"
  printf '%s\0' "$@" > "$HR/proc/$pid/cmdline"
  { printf 'PATH=/usr/bin\0HOME=/home/agent\0'; [ "$tok" = - ] || printf '%s\0' "$tok"; } > "$HR/proc/$pid/environ"
}

echo "devenv start: token mode moves the stored login aside"
seed_login_and_mcp
run "${SBX[@]}" CLAUDE_CODE_OAUTH_TOKEN="$TOKEN" -- start
[ "$RC" = 0 ] && ! has_login "$CRED" && jq -e '.mcpOAuth.server.accessToken == "dummy-mcp"' "$CRED" >/dev/null \
  && pass "the login is gone from ~/.claude/.credentials.json and the other entry stays" || fail "start: exit $RC, credentials: $(jq -c 'keys' "$CRED" 2>&1)"
[ "$(stat -c %a "$CRED")" = 600 ] && [ "$(stat -c %a "$ASIDE")" = 600 ] \
  && pass "both files are mode 600" || fail "modes: $(stat -c %a "$CRED" "$ASIDE" | tr '\n' ' ')"
[ "$(jq -c . "$ASIDE")" = "{\"claudeAiOauth\":$(printf '%s' "$KIT_LOGIN" | jq -c .)}" ] \
  && pass "the login itself is kept in .credentials.json.devenv-stored-login" || fail "the aside file: $(jq -c 'keys' "$ASIDE" 2>&1)"
printf '%s' "$ERR" | grep -qF 'moved the stored claude.ai login out of ~/.claude/.credentials.json' \
  && pass "start says what it did" || fail "start's output: $ERR"
before=$(sha256sum "$CRED" "$ASIDE")
run "${SBX[@]}" CLAUDE_CODE_OAUTH_TOKEN="$TOKEN" -- start
[ "$RC" = 0 ] && [ "$(sha256sum "$CRED" "$ASIDE")" = "$before" ] && ! printf '%s' "$ERR" | grep -qF 'moved the stored' \
  && pass "a second start changes nothing and says nothing" || fail "second start: exit $RC, $ERR"

echo "devenv entry: the same, and a file that held only the login goes away"
seed_login
run "${SBX[@]}" CLAUDE_CODE_OAUTH_TOKEN="$TOKEN" -- entry
[ "$RC" = 0 ] && [ ! -e "$CRED" ] && has_login "$ASIDE" \
  && pass "entry removed the file, keeping the login aside" || fail "entry: exit $RC, $ERR; files: $(find "$HOME_DIR/.claude" -maxdepth 1 -name '.cred*' -printf '%f ')"
printf '%s' "$ERR" | grep -qF 'moved the stored claude.ai login out of' && pass "entry says what it did" || fail "entry's output: $ERR"
run "${SBX[@]}" -- entry
[ "$RC" = 0 ] && [ ! -e "$CRED" ] && has_login "$ASIDE" && pass "entry again: nothing to do" || fail "second entry: exit $RC, $ERR"

echo "sbx mode without the variable in this shell: still moved (a bash-tool child has none)"
seed_login
run "${SBX[@]}" -- entry
[ "$RC" = 0 ] && [ ! -e "$CRED" ] && has_login "$ASIDE" && pass "sbx: moved" || fail "sbx without the variable: exit $RC, $ERR"

echo "login mode leaves everything alone"
seed_login_and_mcp
before=$(sha256sum "$CRED")
run "${SBX[@]}" CLAUDE_AUTH=login CLAUDE_CODE_OAUTH_TOKEN="$TOKEN" -- start
[ "$RC" = 0 ] && [ "$(sha256sum "$CRED")" = "$before" ] && [ ! -e "$ASIDE" ] \
  && pass "start with CLAUDE_AUTH=login: file untouched" || fail "login mode start: exit $RC, $ERR"
run "${SBX[@]}" CLAUDE_AUTH=login -- entry
[ "$RC" = 0 ] && [ "$(sha256sum "$CRED")" = "$before" ] && [ ! -e "$ASIDE" ] \
  && pass "entry with CLAUDE_AUTH=login: file untouched" || fail "login mode entry: exit $RC, $ERR"
run "${SBX[@]}" CLAUDE_AUTH=login -- doctor --env
! accounts | grep -qi 'stored claude.ai login\|Claude.s daemon' \
  && pass "doctor with CLAUDE_AUTH=login: no token-mode checks" || fail "doctor in login mode: $(accounts)"

echo "plain mode only when the variable is set"
seed_login
before=$(sha256sum "$CRED")
run -- entry
[ "$RC" = 0 ] && [ "$(sha256sum "$CRED")" = "$before" ] && [ ! -e "$ASIDE" ] \
  && pass "plain mode, no variable: a laptop's own login is untouched" || fail "plain start: exit $RC, $ERR"
run CLAUDE_CODE_OAUTH_TOKEN="$TOKEN" -- entry
[ "$RC" = 0 ] && [ ! -e "$CRED" ] && has_login "$ASIDE" && pass "plain mode with the variable: moved" || fail "plain start with the variable: exit $RC, $ERR"

echo "what is not a stored login"
seed '{"claudeAiOauth":{"accessToken":"a","refreshToken":"","scopes":["user:inference"]}}'
before=$(sha256sum "$CRED")
run "${SBX[@]}" -- entry
[ "$RC" = 0 ] && [ "$(sha256sum "$CRED")" = "$before" ] && [ ! -e "$ASIDE" ] \
  && pass "no refresh token: Claude's daemon ignores it, so devenv does too" || fail "empty refresh token: exit $RC, $ERR"
seed '{"mcpOAuth":{"s":{"accessToken":"dummy-mcp"}}}'
before=$(sha256sum "$CRED")
run "${SBX[@]}" -- entry
[ "$RC" = 0 ] && [ "$(sha256sum "$CRED")" = "$before" ] && [ ! -e "$ASIDE" ] && pass "only other entries: untouched" || fail "mcp only: exit $RC, $ERR"
seed 'not json {'
before=$(sha256sum "$CRED")
run "${SBX[@]}" -- entry
[ "$RC" = 0 ] && [ "$(sha256sum "$CRED")" = "$before" ] && [ ! -e "$ASIDE" ] && pass "not JSON: untouched, no failure" || fail "invalid JSON: exit $RC, $ERR"
seed ''
run "${SBX[@]}" -- entry
[ "$RC" = 0 ] && [ ! -e "$CRED" ] && [ ! -e "$ASIDE" ] && pass "no credentials file: nothing created" || fail "no file: exit $RC, $ERR"

echo "devenv doctor (sandbox)"
seed_login
run "${SBX[@]}" CLAUDE_CODE_OAUTH_TOKEN="$TOKEN" -- doctor --env
acc_has 'FAIL  a stored claude.ai login is in ~/.claude/.credentials.json' && [ "$RC" = 1 ] \
  && pass "a stored login: FAIL, exit 1" || fail "doctor with a stored login: exit $RC; $(accounts)"
run "${SBX[@]}" -- doctor --env
acc_has 'FAIL  a stored claude.ai login is in ~/.claude/.credentials.json' \
  && pass "a stored login: FAIL without the variable in doctor's own shell too" || fail "doctor without the variable: $(accounts)"

seed_login
run "${SBX[@]}" CLAUDE_CODE_OAUTH_TOKEN="$TOKEN" -- entry
run "${SBX[@]}" CLAUDE_CODE_OAUTH_TOKEN="$TOKEN" -- doctor --env
acc_has 'ok    no stored claude.ai login in ~/.claude/.credentials.json' && acc_has 'ok    no Claude daemon is running' \
  && ! acc_has 'Claude'"'"'s daemon (pid' \
  && pass "after entry: no stored login, no daemon" || fail "doctor after entry: $(accounts)"

fake_proc 4001 "CLAUDE_CODE_OAUTH_TOKEN=$TOKEN" claude daemon run --origin transient --spawned-by '{"pid":2019}'
fake_proc 4002 - claude --resume 0b1f
fake_proc 4003 - bash -c 'claude daemon run'
run "${SBX[@]}" -- doctor --env
acc_has "ok    Claude's daemon (pid 4001) has CLAUDE_CODE_OAUTH_TOKEN" \
  && pass "a daemon with the variable: ok (a session and a shell are not daemons)" || fail "daemon with the variable: $(accounts)"
[ "$(printf '%s\n' "$OUT" | grep -c 'FAIL  Claude.s daemon')" = 0 ] && pass "no FAIL for it" || fail "unexpected FAIL: $(accounts)"

fake_proc 4004 - /home/agent/.local/share/claude/versions/2.1.284 daemon run --origin transient
run "${SBX[@]}" -- doctor --env
acc_has "FAIL  Claude's daemon (pid 4004) has no CLAUDE_CODE_OAUTH_TOKEN" && [ "$RC" = 1 ] \
  && ! acc_has 'pid 4001) has no' && ! acc_has 'pid 4002' && ! acc_has 'pid 4003' \
  && pass "a daemon without it (started from the versions path): FAIL, exit 1, only that one" || fail "daemon without the variable: exit $RC; $(accounts)"
acc_has 'claude daemon stop --any' && pass "the failure names the fix" || fail "no fix in: $(accounts)"

fake_proc 4004 'CLAUDE_CODE_OAUTH_TOKEN=' claude daemon run
run "${SBX[@]}" -- doctor --env
acc_has "FAIL  Claude's daemon (pid 4004) has no CLAUDE_CODE_OAUTH_TOKEN" \
  && pass "an empty variable counts as missing" || fail "empty variable: $(accounts)"

fake_proc 4004 - claude daemon run
chmod 000 "$HR/proc/4004/environ"
run "${SBX[@]}" -- doctor --env
[ "$(id -u)" = 0 ] || ! acc_has 'pid 4004' && pass "an environment that can't be read is not reported" || fail "unreadable environment: $(accounts)"
chmod 600 "$HR/proc/4004/environ"

seed_login
fake_proc 4004 - claude daemon run
run "${SBX[@]}" CLAUDE_CODE_OAUTH_TOKEN="$TOKEN" -- doctor --env
[ "$(accounts | grep -c 'FAIL  a stored claude.ai login')" = 1 ] && acc_has 'FAIL  Claude'"'"'s daemon (pid 4004)' \
  && pass "both problems together: two FAIL lines" || fail "both problems: $(accounts)"

if [ "$fails" = 0 ]; then echo "claude sign-in: PASS"; else echo "claude sign-in: FAIL ($fails)"; fi
exit "$((fails > 0))"
