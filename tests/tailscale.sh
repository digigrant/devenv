#!/usr/bin/env bash
# devenv tailscale-setup and doctor's Tailscale checks against fakes (spec
# §6.14): tests/fakes/{tailscale,systemctl,sc.exe,apt-get,dpkg-query,sudo,curl}
# come first on PATH, DEVENV_HOST_ROOT stands a folder in for / (os-release,
# wsl.conf, /proc/version, /run/systemd/system, the apt key and source), with a
# temporary HOME and TMPDIR and a copy of this working tree. No real apt,
# systemd, Tailscale or Windows is touched.
#   tests/tailscale.sh
# pass and fail always succeed, so `test && pass || fail` is a safe if/else.
# shellcheck disable=SC2015
set -euo pipefail

ROOT=$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)
W=$(mktemp -d)
trap 'rm -rf "$W"' EXIT
mkdir -p "$W/home" "$W/tmp" "$W/log" "$W/run"
# A copy of the working tree without .git, so doctor doesn't fetch.
(cd "$ROOT" && git ls-files -co --exclude-standard -z | xargs -0 cp --parents -t "$W/run" 2>/dev/null) \
  || cp -r "$ROOT/." "$W/run"
rm -rf "$W/run/dev" "$W/run/.git"
DEV=$W/run/bin/devenv
export FAKE_LOG=$W/log
HR=$W/root
KEYRING=$HR/usr/share/keyrings/tailscale-archive-keyring.gpg
LIST=$HR/etc/apt/sources.list.d/tailscale.list

fails=0
pass() { printf '  ok    %s\n' "$*"; }
fail() { printf '  FAIL  %s\n' "$*"; fails=$((fails + 1)); }

# machine OS KIND [nosystemd]: a fresh stand-in for / and fresh fakes, for a
# machine with no Tailscale. OS: ubuntu-noble | debian-trixie | fedora;
# KIND: native | wsl.
machine() {
  rm -rf "$HR" "${FAKE_LOG:?}"/*
  mkdir -p "$HR/etc/apt/sources.list.d" "$HR/usr/share/keyrings" "$HR/proc"
  case "$1" in
    ubuntu-noble) printf 'PRETTY_NAME="Ubuntu 24.04.3 LTS"\nNAME="Ubuntu"\nVERSION_ID="24.04"\nID=ubuntu\nID_LIKE=debian\nVERSION_CODENAME=noble\nUBUNTU_CODENAME=noble\n' ;;
    debian-trixie) printf 'PRETTY_NAME="Debian GNU/Linux 13 (trixie)"\nVERSION_ID="13"\nVERSION_CODENAME=trixie\nID=debian\n' ;;
    fedora) printf 'NAME="Fedora Linux"\nVERSION_ID=42\nID=fedora\n' ;;
  esac > "$HR/etc/os-release"
  case "$2" in
    native) echo "Linux version 6.8.0-45-generic (buildd@lcy02-amd64-075) (x86_64-linux-gnu-gcc-13) #45-Ubuntu SMP" ;;
    wsl) echo "Linux version 6.6.87.2-microsoft-standard-WSL2 (root@439a258ad544) (gcc (GCC) 11.2.0) #1 SMP" ;;
  esac > "$HR/proc/version"
  [ "${3:-}" = nosystemd ] || mkdir -p "$HR/run/systemd/system"
}

# Tailscale installed, running and signed in, as tailscale-setup leaves it.
installed() {
  mkdir -p "$FAKE_LOG/dpkg"
  echo 1.90.6 > "$FAKE_LOG/dpkg/tailscale"
  echo 1.90.6 > "$FAKE_LOG/dpkg/tailscale-archive-keyring"
  printf 'fake tailscale apt key for ubuntu/noble.noarmor.gpg\n' > "$KEYRING"
  printf '# Tailscale packages for ubuntu noble\ndeb [signed-by=/usr/share/keyrings/tailscale-archive-keyring.gpg] https://pkgs.tailscale.com/stable/ubuntu noble main\n' > "$LIST"
  echo "active enabled" > "$FAKE_LOG/tailscaled"
  echo "${1:-Running}" > "$FAKE_LOG/ts-state"
}

# run VAR=VALUE... -- ARGS: devenv on the host without a terminal. Sets OUT,
# ERR, RC.
run() {
  local envs=()
  while [ "$1" != -- ]; do envs+=("$1"); shift; done
  shift
  : > "$FAKE_LOG/argv"
  RC=0
  env -i HOME="$W/home" TMPDIR="$W/tmp" PATH="$ROOT/tests/fakes:/usr/local/bin:/usr/bin:/bin" \
    XDG_RUNTIME_DIR="$W/tmp" FAKE_LOG="$FAKE_LOG" DEVENV_HOST_ROOT="$HR" \
    "${envs[@]}" setsid bash "$DEV" "$@" > "$W/out" 2> "$W/err" < /dev/null || RC=$?
  OUT=$(cat "$W/out"); ERR=$(cat "$W/err")
}

# tty_run VAR=VALUE... -- ARGS: like run, on a pseudo-terminal (stdout and
# stderr both land in OUT, without colors).
tty_run() {
  local envs=()
  while [ "$1" != -- ]; do envs+=("$1"); shift; done
  shift
  : > "$FAKE_LOG/argv"
  RC=0
  env -i HOME="$W/home" TMPDIR="$W/tmp" PATH="$ROOT/tests/fakes:/usr/local/bin:/usr/bin:/bin" \
    XDG_RUNTIME_DIR="$W/tmp" FAKE_LOG="$FAKE_LOG" DEVENV_HOST_ROOT="$HR" \
    "${envs[@]}" script -E never -qefc "bash $(printf '%q' "$DEV") $*" /dev/null > "$W/out" 2>&1 < /dev/null || RC=$?
  OUT=$(tr -d '\r' < "$W/out" | sed 's/\x1b\[[0-9;]*m//g'); ERR=''
}

called() { grep -qE -- "$1" "$FAKE_LOG/argv"; }
out_has() { printf '%s\n' "$OUT" | grep -qF -- "$1"; }
# The Tailscale section of doctor's report.
ts_section() { printf '%s\n' "$OUT" | sed -n '/^Tailscale$/,/^secrets/p'; }
ts_has() { ts_section | grep -qF -- "$1"; }

one_line_failure() {
  local what=$1 want=$2
  if [ "$RC" -ne 0 ] && [ -z "$OUT" ] && [ "$(printf '%s\n' "$ERR" | wc -l)" = 1 ] && printf '%s' "$ERR" | grep -qF -- "$want"; then
    pass "$what: exit $RC, one stderr line ($ERR)"
  else
    fail "$what: expected a non-zero exit, no stdout and one stderr line with '$want'; got exit $RC, stdout '${OUT:0:40}', stderr: $ERR"
  fi
}

# A failed setup: RC non-zero, OUT has WANT, and nothing was installed.
setup_stopped() {
  local what=$1 want=$2
  if [ "$RC" -ne 0 ] && out_has "$want" && ! called '^(sudo|apt-get) ' && [ ! -e "$LIST" ]; then
    pass "$what: stops before installing anything ($want)"
  else
    fail "$what: exit $RC, output: $OUT"
  fi
}

SOURCE_NOBLE='# Tailscale packages for ubuntu noble
deb [signed-by=/usr/share/keyrings/tailscale-archive-keyring.gpg] https://pkgs.tailscale.com/stable/ubuntu noble main'

echo "tailscale-setup"
machine ubuntu-noble native
run -- tailscale-setup
one_line_failure "without a terminal" "tailscale-setup is interactive"
run SANDBOX_NAME=dev -- tailscale-setup
one_line_failure "inside a sandbox" "runs on the host, not inside a sandbox"

home_before=$(find "$W/home" -printf '%p %y %s %T@\n' | sort)
tty_run -- tailscale-setup
[ "$RC" = 0 ] && pass "a new Ubuntu machine: exit 0" || fail "a new Ubuntu machine: exit $RC, output: $OUT"
called '^curl .* https://pkgs.tailscale.com/stable/ubuntu/noble\.noarmor\.gpg$' \
  && [ "$(cat "$KEYRING" 2>/dev/null)" = "fake tailscale apt key for ubuntu/noble.noarmor.gpg" ] \
  && pass "Tailscale's key for ubuntu noble, from pkgs.tailscale.com, at /usr/share/keyrings/tailscale-archive-keyring.gpg" \
  || fail "the apt key: $(cat "$KEYRING" 2>/dev/null)"
[ "$(cat "$LIST" 2>/dev/null)" = "$SOURCE_NOBLE" ] && pass "the apt source is Tailscale's noble.tailscale-keyring.list" \
  || fail "the apt source: $(cat "$LIST" 2>/dev/null)"
called '^sudo env DEBIAN_FRONTEND=noninteractive apt-get update -qq$' \
  && called '^sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y -qq tailscale tailscale-archive-keyring$' \
  && pass "apt-get update, then apt-get install tailscale tailscale-archive-keyring, with sudo" \
  || fail "apt-get calls: $(grep apt-get "$FAKE_LOG/argv" || true)"
called '^sudo systemctl enable --now tailscaled$' && pass "starts tailscaled and enables it at boot" \
  || fail "no systemctl enable --now tailscaled: $(cat "$FAKE_LOG/argv")"
if grep -qx 'sudo tailscale up' "$FAKE_LOG/argv" && [ "$(grep -c '^tailscale up' "$FAKE_LOG/argv")" = 1 ] \
   && out_has "running: sudo tailscale up" && out_has "https://login.tailscale.com/a/fake0123abcd"; then
  pass "not signed in: says and runs exactly 'sudo tailscale up', which prints the sign-in link"
else fail "the sign-in: $(grep 'tailscale up' "$FAKE_LOG/argv" || true), output: $OUT"; fi
grep -qiE 'auth-?key|tskey' "$FAKE_LOG/argv" && fail "an auth key appeared in a command" || pass "no auth key anywhere"
out_has "signed in: devhost.tail1234.ts.net (100.101.102.103) on tailnet owner@example.com; key expires" \
  && out_has "MagicDNS is on for the tailnet" && out_has "HTTPS certificates are on for the tailnet" \
  && pass "reports the machine, its address and tailnet, MagicDNS and HTTPS certificates" || fail "the report: $OUT"
[ "$home_before" = "$(find "$W/home" -printf '%p %y %s %T@\n' | sort)" ] && [ -z "$(find "$W/tmp" -mindepth 1)" ] \
  && pass "stores nothing: no file under HOME changed, no temporary file left" || fail "files changed under HOME or TMPDIR"

tty_run -- tailscale-setup
[ "$RC" = 0 ] && ! called '^sudo ' && ! called '^tailscale up' && out_has "(already installed)" \
  && out_has "tailscaled is running and starts at boot" && out_has "signed in: devhost" \
  && pass "run again: changes nothing, no sudo, no sign-in" || fail "second run: exit $RC, argv: $(cat "$FAKE_LOG/argv"), output: $OUT"

machine debian-trixie native
tty_run -- tailscale-setup
[ "$RC" = 0 ] && called '^curl .* https://pkgs.tailscale.com/stable/debian/trixie\.noarmor\.gpg$' \
  && [ "$(sed -n 2p "$LIST")" = "deb [signed-by=/usr/share/keyrings/tailscale-archive-keyring.gpg] https://pkgs.tailscale.com/stable/debian trixie main" ] \
  && pass "Debian trixie: Tailscale's debian/trixie repository" || fail "Debian: exit $RC, source: $(cat "$LIST" 2>/dev/null), output: $OUT"
machine fedora native
tty_run -- tailscale-setup
setup_stopped "not Ubuntu or Debian" "names neither"
machine ubuntu-noble native
tty_run FAKE_TS_KEY_FAIL=1 -- tailscale-setup
setup_stopped "the key download fails" "could not download Tailscale's apt key"
[ ! -e "$KEYRING" ] && pass "the key download fails: no key written" || fail "a key was written after a failed download"
tty_run FAKE_APT_FAIL=update -- tailscale-setup
[ "$RC" != 0 ] && out_has "apt-get update failed" && ! called 'apt-get install' && ! called '^sudo systemctl' \
  && pass "apt-get update fails: stops before installing" || fail "apt-get update failure: exit $RC, output: $OUT"
machine ubuntu-noble native
tty_run FAKE_TS_UP_FAIL=1 -- tailscale-setup
[ "$RC" != 0 ] && out_has "tailscale up failed; run it again: sudo tailscale up" \
  && pass "tailscale up fails: says to run it again" || fail "tailscale up failure: exit $RC, output: $OUT"

machine ubuntu-noble native; installed Stopped
tty_run -- tailscale-setup
[ "$RC" = 0 ] && grep -qx 'sudo tailscale up' "$FAKE_LOG/argv" && out_has "stopped on this machine (tailscale down)" && out_has "signed in: devhost" \
  && pass "stopped (tailscale down): runs sudo tailscale up" || fail "stopped: exit $RC, output: $OUT"
machine ubuntu-noble native; installed NeedsMachineAuth
tty_run -- tailscale-setup
[ "$RC" != 0 ] && ! called '^tailscale up' && out_has "waits for approval in the admin console: https://console.tailscale.com/admin/machines" \
  && pass "waiting for the admin's approval: says where, and doesn't sign in again" || fail "NeedsMachineAuth: exit $RC, output: $OUT"
machine ubuntu-noble native; installed
tty_run FAKE_TS_MAGICDNS=false FAKE_TS_HTTPS=0 -- tailscale-setup
[ "$RC" = 0 ] && out_has "MagicDNS is off for the tailnet; tailscale serve will need it: turn it on once in the admin console, DNS page (https://console.tailscale.com/admin/dns)" \
  && out_has "HTTPS certificates are off for the tailnet; tailscale serve will need them for https: turn them on once in the admin console, DNS page, HTTPS Certificates, Enable HTTPS (https://console.tailscale.com/admin/dns)" \
  && pass "MagicDNS and HTTPS certificates off: warns with where to turn them on" || fail "MagicDNS/HTTPS off: exit $RC, output: $OUT"

machine ubuntu-noble wsl nosystemd
tty_run -- tailscale-setup
setup_stopped "WSL without systemd or /etc/wsl.conf" "printf '\n[boot]\nsystemd=true\n' | sudo tee -a /etc/wsl.conf, then wsl.exe --shutdown in Windows PowerShell"
printf '[user]\ndefault=grant\n[boot]\ncommand=echo hi\n' > "$HR/etc/wsl.conf"
tty_run -- tailscale-setup
setup_stopped "WSL with [boot] but no systemd=true" "add systemd=true under [boot] in /etc/wsl.conf"
printf '[boot]\nsystemd = true\n' > "$HR/etc/wsl.conf"
tty_run -- tailscale-setup
setup_stopped "WSL with systemd=true that isn't running" "update WSL (wsl --update in PowerShell"
machine ubuntu-noble native nosystemd
tty_run -- tailscale-setup
setup_stopped "native Linux without systemd" "systemd isn't this machine's init"
machine ubuntu-noble wsl
tty_run FAKE_WIN_TS=running -- tailscale-setup
setup_stopped "WSL while Tailscale runs on Windows" "Tailscale is running on Windows too, which breaks Tailscale traffic from WSL: uninstall it on Windows"
tty_run -- tailscale-setup
[ "$RC" = 0 ] && called '^sc\.exe query Tailscale$' && out_has "Tailscale is not installed on Windows" && out_has "signed in: devhost" \
  && pass "WSL with systemd, Tailscale not on Windows: installs and signs in" || fail "WSL: exit $RC, output: $OUT"
machine ubuntu-noble wsl
tty_run FAKE_WIN_TS=stopped -- tailscale-setup
[ "$RC" = 0 ] && out_has "warning: Tailscale is installed on Windows but stopped; keep it stopped" \
  && pass "WSL, Tailscale stopped on Windows: warns and carries on" || fail "Windows stopped: exit $RC, output: $OUT"
machine ubuntu-noble wsl
tty_run FAKE_WIN_TS=broken -- tailscale-setup
[ "$RC" = 0 ] && out_has "could not ask Windows whether Tailscale runs there" \
  && pass "WSL without interop: warns and carries on" || fail "no interop: exit $RC, output: $OUT"

echo "doctor --host"
machine ubuntu-noble native
run -- doctor --host
[ "$RC" = 1 ] && ts_has "FAIL  Tailscale is not installed; run: ~/devenv/bin/devenv tailscale-setup" \
  && ! called '^sc\.exe' && pass "not installed: FAIL with the fix, exit 1; native Linux asks nothing of Windows" \
  || fail "not installed: exit $RC, $(ts_section)"
installed; rm -f "$FAKE_LOG/tailscaled"
run -- doctor --host
[ "$RC" = 1 ] && ts_has "FAIL  tailscaled is not running; run: sudo systemctl enable --now tailscaled" \
  && pass "daemon stopped: FAIL with the fix" || fail "daemon stopped: exit $RC, $(ts_section)"
echo "active disabled" > "$FAKE_LOG/tailscaled"
run -- doctor --host
ts_has "warn  tailscaled is running but doesn't start at boot; run: sudo systemctl enable --now tailscaled" \
  && pass "not enabled at boot: warns with the fix" || fail "not enabled: $(ts_section)"
installed NeedsLogin
run FAKE_TS_AUTH_URL=https://login.tailscale.com/a/pending42 -- doctor --host
[ "$RC" = 1 ] && ts_has "FAIL  this machine isn't signed in to Tailscale (a one-time browser sign-in per machine); run: sudo tailscale up, and open the link it prints (a sign-in already waits at https://login.tailscale.com/a/pending42)" \
  && pass "not signed in: FAIL with the command and the waiting sign-in link" || fail "not signed in: exit $RC, $(ts_section)"
installed
run -- doctor --host
if ts_has "ok    tailscale 1.90.6, from Tailscale's apt repository" && ts_has "ok    tailscaled is running and starts at boot" \
   && ts_has "ok    signed in: devhost.tail1234.ts.net (100.101.102.103) on tailnet owner@example.com; key expires" \
   && ts_has "ok    MagicDNS is on for the tailnet" && ts_has "ok    HTTPS certificates are on for the tailnet" \
   && ! ts_section | grep -qE '^  (FAIL|warn) '; then
  pass "installed, running and signed in: every Tailscale line ok"
else fail "healthy Tailscale: $(ts_section)"; fi
! called '^sudo |^tailscale up|^systemctl enable|^apt-get' && pass "doctor changes nothing: no sudo, apt-get, systemctl enable or tailscale up" \
  || fail "doctor ran: $(cat "$FAKE_LOG/argv")"
run FAKE_TS_KEY_EXPIRY="$(date -u -d '+5 days' +%Y-%m-%dT%H:%M:%SZ)" -- doctor --host
ts_section | grep -qE "warn  this machine's Tailscale key expires in [45] days \([0-9-]+\), and then it drops off the tailnet: run sudo tailscale up --force-reauth, or disable key expiry" \
  && pass "key expiring within WARN_DAYS: warns" || fail "key expiry: $(ts_section)"
run FAKE_TS_KEY_EXPIRY=none -- doctor --host
ts_has "key expiry disabled" && pass "key expiry disabled: said so" || fail "no key expiry: $(ts_section)"
run FAKE_TS_MAGICDNS=false FAKE_TS_HTTPS=0 -- doctor --host
ts_has "warn  MagicDNS is off for the tailnet" && ts_has "warn  HTTPS certificates are off for the tailnet" \
  && pass "MagicDNS and HTTPS certificates off: warnings" || fail "MagicDNS/HTTPS off: $(ts_section)"
rm -f "$LIST"
run -- doctor --host
ts_has "warn  tailscale 1.90.6 is installed, but /etc/apt/sources.list.d/tailscale.list (Tailscale's apt repository) is missing, so apt won't update it" \
  && pass "installed without Tailscale's apt source: warns" || fail "no apt source: $(ts_section)"

machine ubuntu-noble wsl nosystemd; installed
run -- doctor --host
[ "$RC" = 1 ] && ts_has "FAIL  systemd isn't running in this WSL distro, so tailscaled can't run" \
  && ! ts_has "tailscaled is not running" && ! called '^tailscale ' \
  && pass "WSL without systemd: FAIL with the fix, and no daemon or sign-in checks" || fail "WSL no systemd: exit $RC, $(ts_section)"
machine ubuntu-noble wsl; installed
run -- doctor --host
ts_has "ok    systemd is running in this WSL distro" && ts_has "ok    Tailscale is not installed on Windows" \
  && ! ts_section | grep -qE '^  (FAIL|warn) ' && pass "WSL, set up: systemd and Windows checks ok" || fail "WSL healthy: $(ts_section)"
run FAKE_WIN_TS=running -- doctor --host
[ "$RC" = 1 ] && ts_has "FAIL  Tailscale is running on Windows too, which breaks Tailscale traffic from WSL: uninstall it on Windows (Settings > Apps > Installed apps > Tailscale > Uninstall), or stop it and keep it stopped (in an administrator PowerShell: Set-Service Tailscale -StartupType Disabled; Stop-Service Tailscale)" \
  && pass "WSL, Tailscale running on Windows: FAIL with the fix" || fail "Windows running: exit $RC, $(ts_section)"
run FAKE_WIN_TS=stopped -- doctor --host
ts_has "warn  Tailscale is installed on Windows but stopped" && pass "WSL, Tailscale stopped on Windows: warning" || fail "Windows stopped: $(ts_section)"
run FAKE_WIN_TS=broken -- doctor --host
ts_has "warn  could not ask Windows whether Tailscale runs there" && pass "WSL without interop: warning" || fail "no interop: $(ts_section)"

echo
if [ "$fails" = 0 ]; then echo "tailscale: PASS"; else echo "tailscale: FAIL ($fails)"; exit 1; fi
