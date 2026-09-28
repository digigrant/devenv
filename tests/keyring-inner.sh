#!/usr/bin/env bash
# Runs inside the throwaway container started by tests/keyring.sh: as root it
# installs gnome-keyring and copies the tree, then runs itself again as the
# user `tester` inside a private D-Bus session (--user). Not meant to be run
# anywhere else. Dummy values only.
# pass and bad always succeed, so `test && pass || bad` is a safe if/else.
# shellcheck disable=SC2015
set -euo pipefail

if [ "${1:-}" != --user ]; then
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq
  if [ -n "${PROXY_CA_CERT_B64:-}" ]; then
    apt-get install -y -qq --no-install-recommends ca-certificates >/dev/null
    printf '%s' "$PROXY_CA_CERT_B64" | base64 -d > /usr/local/share/ca-certificates/sbx-proxy.crt
    update-ca-certificates >/dev/null 2>&1
  fi
  apt-get install -y -qq --no-install-recommends gnome-keyring libsecret-tools dbus dbus-user-session jq bsdutils >/dev/null
  useradd -m -s /bin/bash tester
  cp -r /src/devenv /home/tester/devenv
  rm -rf /home/tester/devenv/dev
  chown -R tester: /home/tester/devenv
  # shellcheck source=/dev/null
  echo "container: $(. /etc/os-release && echo "$PRETTY_NAME"), $(dpkg-query -W -f='gnome-keyring ${Version}, libsecret-tools ${Version}' gnome-keyring 2>/dev/null | cut -d, -f1), secret-tool $(dpkg-query -W -f='${Version}' libsecret-tools), busctl $(busctl --version | head -n 1 | cut -d' ' -f2)"
  # dbus-daemon and the prompter log to stderr; drop those lines.
  su tester -c 'env -u DISPLAY -u WAYLAND_DISPLAY dbus-run-session -- bash ~/devenv/tests/keyring-inner.sh --user' 2>&1 \
    | grep -v -E '^dbus-daemon\[|^\(gcr-prompter:|^$'
  exit 0
fi

fail=0
pass() { echo "ok   $*"; }
bad()  { echo "FAIL $*"; fail=1; }

export XDG_RUNTIME_DIR=/tmp/xdg-tester
install -d -m 700 "$XDG_RUNTIME_DIR"
DEV=$HOME/devenv/bin/devenv
export FAKE_LOG=$HOME/log FAKE_PROJECT_ID=fake-project-5f1e0c FAKE_CLIENT_ID=fake-client-id-8c2d41 \
  FAKE_CLIENT_SECRET=fake-client-secret-91ab77 FAKE_ACCESS_TOKEN=fake-access-token-77aa03 \
  FAKE_GITHUB=ghp_FAKEfakeFAKEfakeFAKEfakeFAKEfake0001 FAKE_CLAUDE=sk-ant-oat01-FAKEfakeFAKEfakeFAKEfake0002
mkdir -p "$FAKE_LOG" "$HOME/fakes"
# Only Infisical, GitHub and sbx are faked; secret-tool and busctl are real.
ln -s "$HOME/devenv/tests/fakes/curl" "$HOME/devenv/tests/fakes/sbx" "$HOME/fakes/"
export PATH=$HOME/fakes:/usr/local/bin:/usr/bin:/bin

# A login keyring with a dummy password, as a desktop login would create.
printf 'dummy-keyring-password' | gnome-keyring-daemon --unlock --components=secrets >/dev/null 2>&1
eval "$(gnome-keyring-daemon --start --components=secrets 2>/dev/null)"

LOGIN=/org/freedesktop/secrets/collection/login
lock() { busctl --user call org.freedesktop.secrets /org/freedesktop/secrets org.freedesktop.Secret.Service Lock ao 1 "$LOGIN" >/dev/null; }
locked() { busctl --user --json=short get-property org.freedesktop.secrets "$LOGIN" org.freedesktop.Secret.Collection Locked | jq -r .data; }
# The Secret Service methods called while CMD runs (what would open a window:
# Unlock and Prompt).
watch_calls() {
  : > "$HOME/mon.log"
  dbus-monitor --session "type='method_call',destination='org.freedesktop.secrets'" > "$HOME/mon.log" 2>/dev/null &
  local mon=$!
  sleep 1
  "$@"
  sleep 1
  kill "$mon" 2>/dev/null || true
  wait "$mon" 2>/dev/null || true
  CALLS=$(grep -a -oE 'member=[A-Za-z]+' "$HOME/mon.log" | sed 's/member=//' | sort -u | tr '\n' ' ')
}
run() { RC=0; "$@" > "$HOME/out" 2> "$HOME/err" < /dev/null || RC=$?; OUT=$(cat "$HOME/out"); ERR=$(cat "$HOME/err"); }

echo "== secrets-init stores through secret-tool"
RC=0
printf '%s\n%s\n%s\n' "$FAKE_PROJECT_ID" "$FAKE_CLIENT_ID" "$FAKE_CLIENT_SECRET" \
  | script -E never -qefc "bash $DEV secrets-init" /dev/null > "$HOME/out" 2>&1 || RC=$?
OUT=$(tr -d '\r' < "$HOME/out")
[ "$RC" = 0 ] && printf '%s\n' "$OUT" | grep -qF "GITHUB_GEJ_MACHINE_PAT: ok (${#FAKE_GITHUB} chars, ghp_…)" \
  && printf '%s\n' "$OUT" | grep -qF "CLAUDE_CODE_OAUTH_TOKEN: ok" \
  && pass "secrets-init stored the three entries and both test fetches passed" || bad "secrets-init: exit $RC: $OUT"
[ "$(secret-tool lookup service devenv-infisical key client-secret)" = "$FAKE_CLIENT_SECRET" ] \
  && pass "secret-tool lookup returns the stored client secret exactly" || bad "the stored client secret differs"

echo "== secret-get, unlocked"
run bash "$DEV" secret-get GITHUB_GEJ_MACHINE_PAT
[ "$RC" = 0 ] && [ "$OUT" = "$FAKE_GITHUB" ] && [ -z "$ERR" ] && pass "prints exactly the value" || bad "secret-get: exit $RC, stderr: $ERR"
bus=$(printf '%s' "$DBUS_SESSION_BUS_ADDRESS" | sed -n 's/^unix:path=\([^,]*\).*/\1/p')
if [ -n "$bus" ]; then
  ln -sf "$bus" "$XDG_RUNTIME_DIR/bus"
  run env -u DBUS_SESSION_BUS_ADDRESS bash "$DEV" secret-get CLAUDE_CODE_OAUTH_TOKEN
  [ "$RC" = 0 ] && [ "$OUT" = "$FAKE_CLAUDE" ] && pass "without DBUS_SESSION_BUS_ADDRESS it finds \$XDG_RUNTIME_DIR/bus" \
    || bad "secret-get without DBUS_SESSION_BUS_ADDRESS: exit $RC, stderr: $ERR"
fi
run env DEVENV_KEYRING_SERVICE=devenv-missing bash "$DEV" secret-get GITHUB_GEJ_MACHINE_PAT
[ "$RC" != 0 ] && [ "$ERR" = "devenv: error: keyring entry missing: project-id client-id client-secret (service devenv-missing); run: ~/devenv/bin/devenv secrets-init" ] \
  && pass "DEVENV_KEYRING_SERVICE=devenv-missing: entries missing" || bad "missing entries: exit $RC, stderr: $ERR"
run env DBUS_SESSION_BUS_ADDRESS=unix:path=/nonexistent bash "$DEV" secret-get GITHUB_GEJ_MACHINE_PAT
[ "$RC" != 0 ] && printf '%s' "$ERR" | grep -q '^devenv: error: no Secret Service answers (' && [ "$(printf '%s\n' "$ERR" | wc -l)" = 1 ] \
  && pass "no session bus: one line ($ERR)" || bad "no session bus: exit $RC, stderr: $ERR"

echo "== secret-get, locked"
lock
[ "$(locked)" = true ] && pass "the login keyring is locked" || bad "could not lock the login keyring"
watch_calls run bash "$DEV" secret-get GITHUB_GEJ_MACHINE_PAT
[ "$RC" != 0 ] && [ -z "$OUT" ] && [ "$ERR" = "devenv: error: keyring locked; run sbx env run (host-prepare unlocks it)" ] \
  && pass "fails with the one-line message" || bad "secret-get on a locked keyring: exit $RC, stderr: $ERR"
case " $CALLS" in
  *" Unlock "*|*" Prompt "*) bad "secret-get asked the Secret Service to unlock (calls: $CALLS)" ;;
  *" SearchItems "*) pass "only SearchItems, no Unlock or Prompt (calls: $CALLS)" ;;
  *) bad "no SearchItems seen (calls: $CALLS)" ;;
esac
[ "$(locked)" = true ] && pass "the keyring is still locked" || bad "the keyring got unlocked"

echo "== host-prepare, locked, no display"
watch_calls run bash "$DEV" host-prepare
[ "$RC" != 0 ] && printf '%s' "$ERR" | grep -q 'no window can ask for its password here (no DISPLAY or WAYLAND_DISPLAY)' \
  && pass "stops with instructions" || bad "host-prepare without a display: exit $RC, stderr: $ERR"
case " $CALLS" in
  *" Unlock "*" Prompt "*|*" Prompt "*" Unlock "*) pass "it asked the Secret Service to open its unlock window (calls: $CALLS)" ;;
  *) bad "no Unlock and Prompt (calls: $CALLS)" ;;
esac
grep -q '^sbx secret set-custom' "$FAKE_LOG/argv" 2>/dev/null && bad "sbx was called" || pass "sbx was not called"

echo "== host-prepare, unlocked"
# Stands in for the owner typing the password into the window.
printf 'dummy-keyring-password' | gnome-keyring-daemon --replace --unlock --components=secrets >/dev/null 2>&1 &
sleep 2
[ "$(locked)" = false ] && pass "the keyring is unlocked" || bad "could not unlock the keyring"
: > "$FAKE_LOG/argv"
run bash "$DEV" host-prepare
[ "$RC" = 0 ] && grep -q '^sbx secret set-custom .*secret-get CLAUDE_CODE_OAUTH_TOKEN' "$FAKE_LOG/argv" \
  && pass "checks pass and the Claude custom secret is set" || bad "host-prepare: exit $RC, stderr: $ERR"

echo
if [ "$fail" = 0 ]; then echo "keyring: PASS"; else echo "keyring: FAIL"; exit 1; fi
