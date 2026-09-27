# shellcheck shell=bash
# devenv secrets-init: store this machine's Infisical login in the keyring
# (docs/SECRETS.md §6.3). Host only, interactive. Prompts for the project ID,
# client ID and client secret with echo off and pipes each straight into
# `secret-tool store`, then test-fetches both secrets and prints only their
# names, lengths and shapes. Running it again replaces the entries: that is how
# a machine gets a new client secret (Enter keeps an entry that exists).
#
# If the machine has no keyring yet, the first `secret-tool store` makes the
# Secret Service open a window asking for a new keyring password (a pop-up
# under WSLg or on a desktop; HOST-VERIFY §8.2, P1).

secrets_init_prompt() {
  case "$1" in
    project-id) echo "Project ID (the agent project: Project Settings)" ;;
    client-id) echo "Client ID (sbx-host identity, Universal Auth; not the Identity ID)" ;;
    client-secret) echo "Client secret (sbx-host identity, Universal Auth, Add Client Secret)" ;;
  esac
}

cmd_secrets_init() {
  local k v p states have_key n
  [ $# -eq 0 ] || die "usage: devenv secrets-init"
  [ "$(detect_mode)" = sbx ] && die "secrets-init runs on the host, not inside a sandbox"
  [ -t 0 ] || die "secrets-init is interactive: run it in a terminal on the host"
  p=$(keyring_tools_missing)
  [ -z "$p" ] || die "$(printf '%s\n' "$p" | head -n 1)"
  have curl || die "curl is not installed; run: sudo apt-get install -y curl"
  keyring_bus_default
  keyring_unlock_if_locked
  states=$(keyring_states) || die "no Secret Service answers ($states); is gnome-keyring running?"
  log "storing this machine's Infisical login in the keyring (service $(keyring_service))"
  log "paste each value from the Infisical website; nothing is shown as you paste"
  if ! printf '%s\n' "$states" | grep -q ' unlocked$'; then
    log "if this machine has no keyring yet, a window asks you to choose a keyring password after the first value"
  fi
  for k in "${SECRETS_KEYRING_KEYS[@]}"; do
    have_key=0
    printf '%s\n' "$states" | grep -qxF "$k unlocked" && have_key=1
    while :; do
      if [ "$have_key" = 1 ]; then n=" [Enter keeps the stored one]"; else n=''; fi
      IFS= read -rs -p "$(secrets_init_prompt "$k")$n: " v || die "no input"
      printf '\n' >&2
      v=${v//$'\r'/}
      v=${v#"${v%%[![:space:]]*}"}; v=${v%"${v##*[![:space:]]}"}
      if [ -z "$v" ] && [ "$have_key" = 1 ]; then log "kept the stored $k"; break; fi
      if [ -z "$v" ]; then warn "empty; paste the value"; continue; fi
      case "$v" in *[[:space:]]*) warn "that has spaces inside; paste just the value"; v=''; continue ;; esac
      printf '%s' "$v" | keyring_store "$k" \
        || die "secret-tool store failed for $k (with no keyring yet, a window should have asked for a new keyring password)"
      v=''
      ok "stored $k"
      break
    done
  done
  # One login per fetch. Stop at the first failure: 3 failed logins lock
  # sbx-host for 5 minutes.
  echo "Test fetch:"
  for n in "$SECRET_GITHUB" "$SECRET_CLAUDE"; do
    if ! secret_fetch_or_error "$n"; then
      echo "  $n: FAILED: $SECRET_ERROR"
      die "the test fetch failed; check the values on the Infisical website and run devenv secrets-init again (after 3 failed logins, wait 5 minutes)"
    elif v=$(printf '%s' "$SECRET_VALUE" | secret_shape_problem "$n"); then
      SECRET_VALUE=''
      echo "  $n: FAILED: $v"
      die "$n in Infisical is not the right kind of token; replace it on the Infisical website"
    fi
    echo "  $n: ok (${#SECRET_VALUE} chars, $(printf '%s' "$SECRET_VALUE" | secret_shape_label))"
  done
  SECRET_VALUE='' v=''
  ok "done; the Infisical website tab can be closed"
}
