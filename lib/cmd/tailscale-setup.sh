# shellcheck shell=bash
# devenv tailscale-setup: install Tailscale on this host and sign it in, once
# per machine (spec §6.14). Host only, interactive, safe to run again: a run
# with nothing to do changes nothing and needs no sudo.
#   1. Stop, with the fix, when tailscaled couldn't run: systemd isn't the
#      init (on WSL: /etc/wsl.conf), or, on WSL, Tailscale runs on Windows.
#   2. Add Tailscale's apt key and source for this release and install
#      tailscale from it (tailscale_install).
#   3. Start tailscaled and enable it at boot.
#   4. When the machine isn't signed in, run `sudo tailscale up`, which prints
#      the sign-in link to open in a browser. Never an auth key.
#   5. Report the machine's name and address, and whether MagicDNS and HTTPS
#      certificates are on for the tailnet (tailscale serve will need both;
#      they are turned on once, in the admin console).
# Uses lib/tailscale.sh; bin/devenv sources it.

# Print one ts_signin_problems or ts_windows_problem line as ok or warn;
# die on a problem.
ts_report_line() {
  case "$1" in
    "ok: "*) ok "${1#ok: }" ;;
    "warn: "*) warn "${1#warn: }" ;;
    *) die "$1" ;;
  esac
}

cmd_tailscale_setup() {
  local t
  [ $# -eq 0 ] || die "usage: devenv tailscale-setup"
  [ "$(detect_mode)" = sbx ] && die "tailscale-setup runs on the host, not inside a sandbox"
  [ -t 0 ] || die "tailscale-setup is interactive (sudo and a browser sign-in): run it in a terminal on the host"
  for t in curl jq dpkg-query apt-get systemctl; do
    have "$t" || die "$t is missing; devenv installs Tailscale on Ubuntu or Debian with systemd (see README: Host prerequisites)"
  done
  ts_systemd_running || die "$(ts_systemd_problem)"
  if is_wsl; then ts_report_line "$(ts_windows_problem)"; fi
  tailscale_install
  tailscale_daemon_up
  case "$(ts_backend_state)" in
    NeedsLogin|NoState)
      log "this machine isn't signed in to Tailscale yet: a one-time sign-in in a browser"
      log "running: sudo tailscale up"
      log "open the link it prints, sign in, and it carries on"
      as_root tailscale up || die "tailscale up failed; run it again: sudo tailscale up"
      ;;
    Stopped)
      log "Tailscale is stopped on this machine (tailscale down); running: sudo tailscale up"
      as_root tailscale up || die "tailscale up failed; run it again: sudo tailscale up"
      ;;
  esac
  while IFS= read -r t; do
    [ -n "$t" ] && ts_report_line "$t"
  done < <(ts_signin_problems)
  return 0
}
