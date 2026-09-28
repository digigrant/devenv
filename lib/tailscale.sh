# shellcheck shell=bash
# Tailscale on the host (spec §6.14): installed from Tailscale's own apt
# repository and signed in once per machine by `devenv tailscale-setup`, and
# checked by `devenv doctor`. Sign-in is the interactive browser sign-in of
# `sudo tailscale up`: devenv never uses an auth key and stores no Tailscale
# secret (tailscaled keeps the machine's own node key, as it does on any
# machine that runs Tailscale).
#
# On WSL 2, tailscaled runs as a systemd service, so systemd must be the
# distro's init, and Tailscale must not run on Windows at the same time: WSL's
# Tailscale traffic doesn't work through Windows' Tailscale
# (https://tailscale.com/docs/install/windows/wsl2).
#
# Files are read and written through host_path, so tests can stand a folder
# in for / (DEVENV_HOST_ROOT): /etc/os-release, /etc/wsl.conf, /proc/version,
# /run/systemd/system, and the apt key and source.

TS_APT_URL=https://pkgs.tailscale.com/stable
# Where Tailscale's instructions, and its tailscale-archive-keyring package,
# keep the key; the source names it in signed-by.
TS_APT_KEYRING=/usr/share/keyrings/tailscale-archive-keyring.gpg
TS_APT_LIST=/etc/apt/sources.list.d/tailscale.list
TS_CONSOLE=https://console.tailscale.com/admin
TS_WINDOWS_SERVICE=Tailscale

# os_release KEY: KEY's value in /etc/os-release, without quotes.
os_release() {
  sed -n "s/^$1=//p" "$(host_path /etc/os-release)" 2>/dev/null | head -n 1 \
    | sed -e 's/^"\(.*\)"$/\1/' -e "s/^'\(.*\)'$/\1/"
}

# "<os> <codename>" (e.g. "ubuntu noble"): the folder of Tailscale's apt
# repository for this release, chosen as Tailscale's installer does. Fails
# on anything but Ubuntu (or a derivative that names its Ubuntu release) and
# Debian.
ts_apt_release() {
  local id codename
  codename=$(os_release UBUNTU_CODENAME)
  if [ -n "$codename" ]; then echo "ubuntu $codename"; return 0; fi
  id=$(os_release ID) codename=$(os_release VERSION_CODENAME)
  case "$id" in ubuntu|debian) [ -n "$codename" ] && { echo "$id $codename"; return 0; } ;; esac
  return 1
}

# The apt source for OS CODENAME, as Tailscale's <codename>.tailscale-keyring.list.
ts_apt_source() {
  printf '# Tailscale packages for %s %s\ndeb [signed-by=%s] %s/%s %s main\n' \
    "$1" "$2" "$TS_APT_KEYRING" "$TS_APT_URL" "$1" "$2"
}

# true when systemd is this machine's init (sd_booted's own test).
ts_systemd_running() { [ -d "$(host_path /run/systemd/system)" ]; }

# Why tailscaled can't run without systemd, and the fix.
ts_systemd_problem() {
  local conf
  conf=$(host_path /etc/wsl.conf)
  if ! is_wsl; then
    echo "systemd isn't this machine's init, and tailscaled runs as a systemd service; see https://tailscale.com/docs/install/linux"
  elif grep -qiE '^[[:space:]]*systemd[[:space:]]*=[[:space:]]*true' "$conf" 2>/dev/null; then
    echo "systemd isn't running in this WSL distro although /etc/wsl.conf sets systemd=true, so tailscaled can't run: run wsl.exe --shutdown in Windows PowerShell and open the distro again; if systemd still isn't running, update WSL (wsl --update in PowerShell; systemd needs WSL 0.67.6 or newer)"
  elif grep -qiE '^[[:space:]]*\[boot\]' "$conf" 2>/dev/null; then
    echo "systemd isn't running in this WSL distro, so tailscaled can't run: add systemd=true under [boot] in /etc/wsl.conf (sudoedit /etc/wsl.conf), then run wsl.exe --shutdown in Windows PowerShell and open the distro again"
  else
    echo "systemd isn't running in this WSL distro, so tailscaled can't run: run printf '\n[boot]\nsystemd=true\n' | sudo tee -a /etc/wsl.conf, then wsl.exe --shutdown in Windows PowerShell, and open the distro again"
  fi
}

# The Windows Tailscale service, asked through WSL's interop: running,
# stopped, absent or unknown (sc.exe didn't answer, e.g. interop is off).
# sc.exe prints the state as "<n>  RUNNING", and error 1060 for a service
# that doesn't exist.
ts_windows_state() {
  local sc out
  sc=$(command -v sc.exe 2>/dev/null) || sc=/mnt/c/Windows/System32/sc.exe
  out=$(timeout 10 "$sc" query "$TS_WINDOWS_SERVICE" 2>&1 </dev/null | tr -d '\r') || true
  if grep -qE ':[[:space:]]*[0-9]+[[:space:]]+(RUNNING|START_PENDING|CONTINUE_PENDING|PAUSE_PENDING|PAUSED)' <<<"$out"; then echo running
  elif grep -qE ':[[:space:]]*[0-9]+[[:space:]]+(STOPPED|STOP_PENDING)' <<<"$out"; then echo stopped
  elif grep -q 'FAILED 1060' <<<"$out"; then echo absent
  else echo unknown; fi
}

# Whether Tailscale on Windows is out of the way, as one line: "ok: …",
# "warn: …", or a problem. WSL only.
ts_windows_problem() {
  case "$(ts_windows_state)" in
    absent) echo "ok: Tailscale is not installed on Windows" ;;
    running) echo "Tailscale is running on Windows too, which breaks Tailscale traffic from WSL: uninstall it on Windows (Settings > Apps > Installed apps > Tailscale > Uninstall), or stop it and keep it stopped (in an administrator PowerShell: Set-Service Tailscale -StartupType Disabled; Stop-Service Tailscale)" ;;
    stopped) echo "warn: Tailscale is installed on Windows but stopped; keep it stopped while WSL runs Tailscale (it starts again with Windows unless its service is disabled), or uninstall it (Settings > Apps > Installed apps > Tailscale)" ;;
    *) echo "warn: could not ask Windows whether Tailscale runs there (sc.exe didn't answer; is WSL interop off?); make sure Tailscale on Windows is uninstalled or stopped" ;;
  esac
}

# `tailscale status --json`, or nothing when tailscaled doesn't answer.
ts_status_json() { timeout 10 tailscale status --json </dev/null 2>/dev/null || true; }

# tailscaled's state: Running, NeedsLogin, Stopped, … or nothing.
ts_backend_state() { jq -r '.BackendState // empty' <<<"$(ts_status_json)" 2>/dev/null || true; }

# The sign-in state and the tailnet settings `tailscale serve` needs later,
# one line each: "ok: …", "warn: …", or a problem. The first line is the
# sign-in state. Needs no root.
ts_signin_problems() {
  local json state url name ip tailnet exp days
  json=$(ts_status_json)
  state=$(jq -r '.BackendState // empty' <<<"$json" 2>/dev/null) || state=''
  case "$state" in
    Running) ;;
    NeedsLogin|NoState)
      url=$(jq -r '.AuthURL // empty' <<<"$json")
      echo "this machine isn't signed in to Tailscale (a one-time browser sign-in per machine); run: sudo tailscale up, and open the link it prints${url:+ (a sign-in already waits at $url)}"
      return 0 ;;
    NeedsMachineAuth) echo "signed in to Tailscale, but this machine waits for approval in the admin console: $TS_CONSOLE/machines"; return 0 ;;
    Stopped) echo "Tailscale is stopped on this machine (tailscale down); run: sudo tailscale up"; return 0 ;;
    Starting) echo "warn: tailscaled is still connecting; run devenv doctor again in a moment"; return 0 ;;
    '') echo "tailscaled doesn't answer (tailscale status --json failed); see: sudo journalctl -u tailscaled"; return 0 ;;
    *) echo "Tailscale reports the state $state; see: tailscale status"; return 0 ;;
  esac
  IFS='|' read -r name ip tailnet < <(jq -r '[(.Self.DNSName // "" | rtrimstr(".")), (.TailscaleIPs[0] // ""), (.CurrentTailnet.Name // "")] | join("|")' <<<"$json")
  name="signed in: ${name:-this machine} (${ip:-no address}) on tailnet ${tailnet:-unknown}"
  exp=$(jq -r '.Self.KeyExpiry // empty' <<<"$json")
  if [ -z "$exp" ]; then
    echo "ok: $name; key expiry disabled"
  else
    days=$(days_until "$exp" 2>/dev/null || echo 0)
    echo "ok: $name; key expires ${exp%%T*}"
    if [ "$days" -lt "$WARN_DAYS" ]; then
      echo "warn: this machine's Tailscale key expires in $days days (${exp%%T*}), and then it drops off the tailnet: run sudo tailscale up --force-reauth, or disable key expiry for it in the admin console ($TS_CONSOLE/machines)"
    fi
  fi
  if [ "$(jq -r '.CurrentTailnet.MagicDNSEnabled // false' <<<"$json")" = true ]; then
    echo "ok: MagicDNS is on for the tailnet"
  else
    echo "warn: MagicDNS is off for the tailnet; tailscale serve will need it: turn it on once in the admin console, DNS page ($TS_CONSOLE/dns)"
  fi
  if [ "$(jq -r '.CertDomains // [] | length' <<<"$json")" -gt 0 ]; then
    echo "ok: HTTPS certificates are on for the tailnet"
  else
    echo "warn: HTTPS certificates are off for the tailnet; tailscale serve will need them for https: turn them on once in the admin console, DNS page, HTTPS Certificates, Enable HTTPS ($TS_CONSOLE/dns)"
  fi
}

# Every Tailscale check for the host's doctor, one per line: "ok: …",
# "warn: …", or a problem, each with its fix. Needs no root and changes
# nothing.
tailscale_problems() {
  local v systemd=1
  if ! ts_systemd_running; then
    ts_systemd_problem
    systemd=0
  elif is_wsl; then
    echo "ok: systemd is running in this WSL distro"
  fi
  is_wsl && ts_windows_problem
  v=$(deb_pkg_version tailscale)
  if [ -z "$v" ]; then
    echo "Tailscale is not installed; run: ~/devenv/bin/devenv tailscale-setup"
    return 0
  fi
  if [ -f "$(host_path "$TS_APT_LIST")" ]; then
    echo "ok: tailscale $v, from Tailscale's apt repository"
  else
    echo "warn: tailscale $v is installed, but $TS_APT_LIST (Tailscale's apt repository) is missing, so apt won't update it; run: ~/devenv/bin/devenv tailscale-setup"
  fi
  [ "$systemd" = 1 ] || return 0
  if ! systemctl is-active --quiet tailscaled 2>/dev/null; then
    echo "tailscaled is not running; run: sudo systemctl enable --now tailscaled"
    return 0
  fi
  if [ "$(systemctl is-enabled tailscaled 2>/dev/null)" = enabled ]; then
    echo "ok: tailscaled is running and starts at boot"
  else
    echo "warn: tailscaled is running but doesn't start at boot; run: sudo systemctl enable --now tailscaled"
  fi
  ts_signin_problems
}

# Add Tailscale's apt key and source for this release, and install tailscale
# and tailscale-archive-keyring (which keeps the key current) from it, as
# Tailscale documents. Changes nothing when all of that is in place.
tailscale_install() {
  local rel os codename tmp key list src v r_key r_list
  rel=$(ts_apt_release) \
    || die "Tailscale's apt repository has Ubuntu and Debian releases, and /etc/os-release names neither; install Tailscale by hand: https://tailscale.com/docs/install/linux"
  read -r os codename <<<"$rel"
  key=$(host_path "$TS_APT_KEYRING") list=$(host_path "$TS_APT_LIST")
  src=$(ts_apt_source "$os" "$codename")
  tmp=$(mktemp)
  if ! curl -fsSL --retry 3 --connect-timeout 20 -o "$tmp" "$TS_APT_URL/$os/$codename.noarmor.gpg"; then
    rm -f "$tmp"
    die "could not download Tailscale's apt key from $TS_APT_URL/$os/$codename.noarmor.gpg (is $os $codename a release Tailscale has packages for? see https://pkgs.tailscale.com/stable/)"
  fi
  v=$(deb_pkg_version tailscale)
  if cmp -s "$tmp" "$key" && [ "$(cat "$list" 2>/dev/null)" = "$src" ] && [ -n "$v" ] \
     && [ -n "$(deb_pkg_version tailscale-archive-keyring)" ]; then
    rm -f "$tmp"
    ok "tailscale $v, from Tailscale's apt repository (already installed)"
    return 0
  fi
  log "adding Tailscale's apt repository ($TS_APT_URL/$os $codename) and installing tailscale; sudo may ask for your password"
  [ -d "${key%/*}" ] || as_root install -d -m 0755 "${key%/*}"
  r_key=$(write_if_changed "$key" 0644 < "$tmp")
  rm -f "$tmp"
  r_list=$(printf '%s\n' "$src" | write_if_changed "$list" 0644)
  ok "Tailscale apt source $TS_APT_LIST ($r_list), key $TS_APT_KEYRING ($r_key)"
  as_root env DEBIAN_FRONTEND=noninteractive apt-get update -qq >/dev/null \
    || die "apt-get update failed; fix it, then run devenv tailscale-setup again"
  as_root env DEBIAN_FRONTEND=noninteractive apt-get install -y -qq tailscale tailscale-archive-keyring >/dev/null \
    || die "apt-get install tailscale failed; fix it, then run devenv tailscale-setup again"
  v=$(deb_pkg_version tailscale)
  [ -n "$v" ] || die "apt-get finished, but the tailscale package isn't installed; see: apt-cache policy tailscale"
  ok "tailscale $v installed from Tailscale's apt repository"
}

# Start tailscaled now and at every boot.
tailscale_daemon_up() {
  if systemctl is-active --quiet tailscaled 2>/dev/null && [ "$(systemctl is-enabled tailscaled 2>/dev/null)" = enabled ]; then
    ok "tailscaled is running and starts at boot"
    return 0
  fi
  as_root systemctl enable --now tailscaled || die "could not start tailscaled; see: sudo journalctl -u tailscaled"
  ok "tailscaled started, and starts at boot"
}
