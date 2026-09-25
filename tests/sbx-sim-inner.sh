#!/usr/bin/env bash
# Runs inside the container started by tests/sbx-sim.sh, as root.
# Not meant to be run anywhere else.
# The sourced files exist only inside the container, pass/bad always succeed,
# and single-quoted command strings are expanded by the agent's shell.
# shellcheck disable=SC1091,SC2015,SC2016
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
DEVENV=/home/owner/devenv
WS=/home/owner/dev
fail=0
pass() { echo "ok   $*"; }
bad()  { echo "FAIL $*"; fail=1; }

# ---- make the container look like a Docker Sandbox
apt-get update -qq
if [ -n "${PROXY_CA_CERT_B64:-}" ]; then
  apt-get install -y -qq --no-install-recommends ca-certificates >/dev/null
  printf '%s' "$PROXY_CA_CERT_B64" | base64 -d > /usr/local/share/ca-certificates/sbx-proxy.crt
  update-ca-certificates >/dev/null 2>&1
  export NODE_EXTRA_CA_CERTS=/etc/ssl/certs/ca-certificates.crt
fi
apt-get install -y -qq --no-install-recommends sudo git curl jq python3 nodejs npm ca-certificates bsdutils >/dev/null
if getent passwd 1000 >/dev/null; then userdel -r "$(id -nu 1000)" >/dev/null 2>&1 || true; fi
useradd -m -u 1000 -s /bin/bash agent
echo 'agent ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/agent
install -d -o agent -g agent "$WS" /usr/local/share/npm-global
install -o agent -g agent -m 0644 /dev/null /etc/sandbox-persistent.sh
export IS_SANDBOX=1 SANDBOX_NAME=dev WORKSPACE_DIR=$WS NPM_CONFIG_PREFIX=/usr/local/share/npm-global
export PATH="/usr/local/share/npm-global/bin:$PATH"

# The kit's snippets, taken from spec.yaml (8-space indented block scalars).
install_snippet=$(awk '/^  install:/{f=1} f && /command: \|/{c=1; next} c && /^  startup:/{exit} c && /^        /{sub(/^        /, ""); print} c && /^    - /{exit}' "$DEVENV/kits/devenv/spec.yaml")
startup_snippet=$(awk '/^  startup:/{f=1} f && /- \|$/{c=1; next} c && /^          /{sub(/^          /, ""); print}' "$DEVENV/kits/devenv/spec.yaml")
[ -n "$install_snippet" ] && [ -n "$startup_snippet" ] || { echo "FAIL could not extract the kit snippets"; exit 1; }
printf '%s\n' "$install_snippet" > /tmp/kit-install.sh
printf '%s\n' "$startup_snippet" > /tmp/kit-startup.sh
chmod 0644 /tmp/kit-install.sh /tmp/kit-startup.sh

snapshot() {
  { find /home/agent \( -path /home/agent/.cache -o -path /home/agent/.npm \) -prune -o \( -type f -o -type l \) -print
    echo /etc/sandbox-persistent.sh; echo /usr/local/bin/devenv-entry; } | sort | while read -r f; do
    if [ -L "$f" ]; then echo "L $(readlink "$f") $f"; else echo "$(sha256sum "$f" | cut -c1-16) $(stat -c %U:%a "$f") $f"; fi
  done
}

echo "== setup.install (as root, like sbx create)"
if sh /tmp/kit-install.sh > /tmp/install1.log 2>&1; then pass "kit install snippet"; else bad "kit install snippet"; tail -n 40 /tmp/install1.log; exit 1; fi
grep -q "devenv: provisioning from $DEVENV" /tmp/install1.log && pass "found the read-only checkout mount" || bad "did not provision from $DEVENV"
snapshot > /tmp/snap1

echo "== assertions"
[ "$(stat -c %U /etc/sandbox-persistent.sh)" = agent ] && pass "/etc/sandbox-persistent.sh still owned by agent" || bad "/etc/sandbox-persistent.sh owner is $(stat -c %U /etc/sandbox-persistent.sh)"
grep -q '^# >>> devenv >>>' /etc/sandbox-persistent.sh && pass "env block written" || bad "env block missing"
grep -qx "DEVENV_DEFAULT_DIR=$DEVENV" /usr/local/bin/devenv-entry && pass "entrypoint shim points at the checkout" || bad "entrypoint shim"
others=$(find /home/agent "$WS" ! -user agent | head -n 5)
[ -z "$others" ] && pass "everything in /home/agent and the workspace is owned by agent" || bad "files not owned by agent: $others"
as_agent() { sudo -u agent -H --preserve-env=IS_SANDBOX,SANDBOX_NAME,WORKSPACE_DIR,NPM_CONFIG_PREFIX,HTTP_PROXY,HTTPS_PROXY,NO_PROXY,http_proxy,https_proxy,no_proxy,NODE_EXTRA_CA_CERTS bash -c ". /etc/sandbox-persistent.sh; $1"; }
[ "$(as_agent 'git config --global user.name')" = gej-machine ] && pass "git identity is the bot" || bad "git identity"
. "$DEVENV/versions.env"
[ "$(as_agent 'herdr --version' | grep -oE '[0-9.]+$')" = "$HERDR_VERSION" ] && pass "herdr on the agent's PATH" || bad "herdr"
[ "$(as_agent 'git -C "$FM_HOME" rev-parse HEAD')" = "$FIRSTMATE_COMMIT" ] && pass "Firstmate cloned at the pin into the workspace" || bad "Firstmate"
n=$(as_agent "jq '[.hooks.SessionStart[].hooks[].command] | length' ~/.claude/settings.json")
[ "$n" = 4 ] && pass "4 SessionStart hooks" || bad "SessionStart hooks: $n"

echo "== setup.startup (as agent)"
as_agent 'bash /tmp/kit-startup.sh'
grep -q 'start done' /home/agent/.cache/devenv/start.log && pass "devenv start ran ($(grep -o 'start done in [0-9]*s' /home/agent/.cache/devenv/start.log | tail -n 1))" || { bad "devenv start"; cat /home/agent/.cache/devenv/start.log; }
[ ! -s /home/agent/.cache/devenv/warnings ] && pass "no warnings" || { bad "warnings:"; cat /home/agent/.cache/devenv/warnings; }

echo "== entrypoint (DEVENV_ENTRY=shell)"
out=$(printf 'echo ENTRY-SHELL-OK\nexit\n' | as_agent 'DEVENV_ENTRY=shell devenv-entry' 2>&1 || true)
printf '%s\n' "$out" | grep -q ENTRY-SHELL-OK && pass "devenv-entry opens a shell" || { bad "devenv-entry"; printf '%s\n' "$out" | tail -n 5; }

echo "== setup.install again (idempotent)"
if sh /tmp/kit-install.sh > /tmp/install2.log 2>&1; then pass "second install"; else bad "second install"; tail -n 20 /tmp/install2.log; fi
snapshot > /tmp/snap2
diff -u /tmp/snap1 /tmp/snap2 && pass "second install changed nothing" || bad "second install changed files (diff above)"

echo
if [ "$fail" = 0 ]; then echo "sbx simulation: PASS"; else echo "sbx simulation: FAIL"; fi
exit "$fail"
