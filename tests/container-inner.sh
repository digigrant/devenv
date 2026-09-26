#!/usr/bin/env bash
# Runs inside the throwaway container started by tests/container-smoke.sh,
# as root. Not meant to be run anywhere else.
# Command strings are single-quoted on purpose (the tester's shell expands
# them), pass/bad always succeed, and the sourced files exist only inside the
# container.
# shellcheck disable=SC1091,SC2015,SC2016
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
. /etc/os-release
echo "container: $PRETTY_NAME ($(uname -m))"

fail=0
pass() { echo "ok   $*"; }
bad()  { echo "FAIL $*"; fail=1; }

apt-get update -qq
if [ -n "${PROXY_CA_CERT_B64:-}" ]; then
  apt-get install -y -qq --no-install-recommends ca-certificates >/dev/null
  printf '%s' "$PROXY_CA_CERT_B64" | base64 -d > /usr/local/share/ca-certificates/sbx-proxy.crt
  update-ca-certificates >/dev/null 2>&1
  export NODE_EXTRA_CA_CERTS=/etc/ssl/certs/ca-certificates.crt
fi
apt-get install -y -qq --no-install-recommends sudo >/dev/null
useradd -m -s /bin/bash tester
echo 'tester ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/tester

keep=HTTP_PROXY,HTTPS_PROXY,NO_PROXY,http_proxy,https_proxy,no_proxy,NODE_EXTRA_CA_CERTS
as_tester() { sudo -u tester -H --preserve-env="$keep" bash -c "$1"; }

snapshot() {
  as_tester 'cd ~ && find . \( -path ./.cache -o -path ./.npm -o -path ./.local/state \) -prune -o \( -type f -o -type l \) -print \
    | sort | while read -r f; do if [ -L "$f" ]; then echo "L $(readlink "$f") $f"; else echo "$(sha256sum "$f" | cut -c1-16) $f"; fi; done'
}

provision='bash /devenv/provision.sh --plain --yes --git-identity skip --skip-claude-install'

echo "== first run"
if as_tester "$provision" > /tmp/run1.log 2>&1; then pass "provision.sh (first run)"
else bad "provision.sh (first run)"; tail -n 40 /tmp/run1.log; exit 1; fi
snapshot > /tmp/snap1

echo "== second run"
if as_tester "$provision" > /tmp/run2.log 2>&1; then pass "provision.sh (second run)"
else bad "provision.sh (second run)"; tail -n 40 /tmp/run2.log; fi
snapshot > /tmp/snap2
if diff -u /tmp/snap1 /tmp/snap2; then pass "second run changed nothing in \$HOME"
else bad "second run changed files in \$HOME (diff above)"; fi
if grep -E 'installed|cloned|changed\)' /tmp/run2.log | grep -v 'already installed' | grep -v 'set to'; then
  bad "second run reported changes (lines above)"
else
  pass "second run reported no changes"
fi

echo "== assertions"
. /devenv/versions.env
env_sh='. ~/.config/devenv/env.sh'
check_version() {  # <label> <command> <want>
  local got
  got=$(as_tester "$env_sh; $2" 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -n 1 || true)
  [ "$got" = "$3" ] && pass "$1 $got" || bad "$1 is ${got:-missing}, want $3"
}
check_version herdr 'herdr --version' "$HERDR_VERSION"
check_version treehouse 'treehouse --version' "$TREEHOUSE_VERSION"
check_version no-mistakes 'no-mistakes --version' "$NO_MISTAKES_VERSION"
check_version gh-axi 'jq -r .version "$(npm root -g)/gh-axi/package.json"' "$NPM_GH_AXI"
check_version chrome-devtools-axi 'jq -r .version "$(npm root -g)/chrome-devtools-axi/package.json"' "$NPM_CHROME_DEVTOOLS_AXI"
check_version tasks-axi 'jq -r .version "$(npm root -g)/tasks-axi/package.json"' "$NPM_TASKS_AXI"
check_version quota-axi 'jq -r .version "$(npm root -g)/quota-axi/package.json"' "$NPM_QUOTA_AXI"
node_v=$(as_tester "$env_sh; node --version" | tr -d v)
[ "$(printf '%s\n%s\n' "$node_v" "$NODE_MIN_VERSION" | sort -V | head -n 1)" = "$NODE_MIN_VERSION" ] \
  && pass "node $node_v" || bad "node $node_v < $NODE_MIN_VERSION"
for t in gh-axi chrome-devtools-axi tasks-axi quota-axi; do
  as_tester "$env_sh; command -v $t" >/dev/null && pass "$t on PATH" || bad "$t not on PATH"
done

if dpkg -s tmux >/dev/null 2>&1 || as_tester "command -v tmux" >/dev/null; then bad "tmux is installed"; else pass "tmux not installed"; fi
as_tester 'grep -qx "version_check = false" ~/.config/herdr/config.toml && grep -qx "manifest_check = false" ~/.config/herdr/config.toml && grep -qx "onboarding = false" ~/.config/herdr/config.toml' \
  && pass "herdr update/manifest checks and onboarding off" || bad "herdr config"
got=$(as_tester 'sha256sum ~/.config/herdr/agent-detection/claude.toml' | cut -d' ' -f1)
[ "$got" = "$HERDR_CLAUDE_MANIFEST_SHA256" ] && pass "herdr Claude detection override installed" || bad "herdr detection override: $got"

s='~/.claude/settings.json'
as_tester "jq -e '.statusLine.command == \"bash \\\"\$HOME/.claude/statusline.sh\\\"\"' $s" >/dev/null && pass "statusLine set" || bad "statusLine not set"
. /devenv/devenv.conf
for m in $CLAUDE_EFFORT_MODELS; do
  as_tester "jq -e --arg m $m '.modelSettings[\$m].effortLevel == \"$CLAUDE_EFFORT_DEFAULT\"' $s" >/dev/null \
    && pass "effort $CLAUDE_EFFORT_DEFAULT for $m" || bad "effort for $m"
done
n=$(as_tester "jq '[.hooks.SessionStart[].hooks[].command] | length' $s")
u=$(as_tester "jq '[.hooks.SessionStart[].hooks[].command] | unique | length' $s")
[ "$n" = "$u" ] && [ "$n" -ge 4 ] && pass "$n SessionStart hooks, none duplicated" || bad "SessionStart hooks: $n total, $u unique"
got=$(as_tester 'sha256sum ~/.claude/statusline-command.sh' | cut -d' ' -f1)
[ "$got" = dc324500a5e54bc7905816cd92039c6519e4bcd3303d40a023e0686cde7e27c4 ] && pass "status line script sha256" || bad "status line sha256 $got"
for sk in grill-me grilling; do
  [ "$(as_tester "readlink ~/.claude/skills/$sk")" = "/devenv/skills/$sk" ] && pass "skill $sk linked" || bad "skill $sk not linked"
done
as_tester 'test -d ~/dev/firstmate/.git' && pass "Firstmate cloned into ~/dev/firstmate" || bad "Firstmate not cloned"
[ "$(as_tester 'git -C ~/dev/firstmate remote get-url origin')" = "$FIRSTMATE_REPO" ] && pass "Firstmate cloned from $FIRSTMATE_REPO" || bad "Firstmate origin"
[ "$(as_tester 'git -C ~/dev/firstmate rev-parse HEAD')" = "$(as_tester 'git -C ~/dev/firstmate rev-parse origin/main')" ] && pass "Firstmate at the fork's main" || bad "Firstmate not at the fork's main"
[ "$(as_tester 'tr -d "[:space:]" < ~/dev/firstmate/config/backend')" = herdr ] && pass "Firstmate backend herdr" || bad "Firstmate backend"
[ -z "$(as_tester 'git config --global user.name || true')" ] && pass "git identity untouched (--git-identity skip)" || bad "git identity was set"

if as_tester "$env_sh; devenv check" > /tmp/check.log 2>&1; then pass "devenv check exits 0"; else bad "devenv check exit code"; fi
if as_tester 'test ! -s ~/.cache/devenv/warnings'; then pass "no warnings"; else bad "warnings:"; as_tester 'cat ~/.cache/devenv/warnings'; fi

echo
if [ "$fail" = 0 ]; then echo "container smoke ($PRETTY_NAME): PASS"; else echo "container smoke ($PRETTY_NAME): FAIL"; fi
exit "$fail"
