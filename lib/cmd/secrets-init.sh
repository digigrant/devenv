# shellcheck shell=bash
# devenv secrets-init: store this machine's Infisical login in the keyring
# (docs/SECRETS.md §6.3). Host only, interactive. Prompts for the project ID,
# client ID and client secret with echo off and pipes each straight into
# `secret-tool store`, then test-fetches both secrets and prints only their
# names, lengths and shapes. Running it again replaces the entries: that is how
# a machine gets a new client secret (Enter keeps an entry that exists).
#
# If the machine has no keyring yet, the first `secret-tool store` makes the
# Secret Service ask for a new keyring password; under WSLg or on a desktop
# that is a pop-up window (HOST-VERIFY §8.2, P1).

secrets_init_prompt() {
  case "$1" in
    project-id) echo "Infisical project ID (the agent project: Project Settings)" ;;
    client-id) echo "Client ID (sbx-host identity: Universal Auth; not the Identity ID)" ;;
    client-secret) echo "Client secret (sbx-host identity: Universal Auth, Add Client Secret)" ;;
  esac
}

cmd_secrets_init() {
  local k v scan have_key failed=0 n
  [ $# -eq 0 ] || die "usage: devenv secrets-init"
  [ "$(detect_mode)" = sbx ] && die "secrets-init runs on the host, not inside a sandbox"
  [ -t 0 ] || die "secrets-init is interactive: run it in a terminal on the host"
  have secret-tool || die "secret-tool is not installed; run: sudo apt-get install -y libsecret-tools"
  have jq || die "jq is not installed; run: sudo apt-get install -y jq"
  have curl || die "curl is not installed; run: sudo apt-get install -y curl"
  keyring_bus_default
  keyring_unlock_if_locked
  scan=$(keyring_scan)
  if printf '%s\n' "$scan" | grep -q '^secret-tool: '; then
    die "no Secret Service answers ($(printf '%s\n' "$scan" | grep -m 1 '^secret-tool: ' | cut -c14-)); is gnome-keyring running?"
  fi
  log "storing this machine's Infisical login in the keyring (service $(keyring_service))"
  log "paste each value from the Infisical website; nothing is shown as you paste"
  if [ -z "$scan" ]; then
    log "if this machine has no keyring yet, the first entry opens a window asking for a new keyring password"
  fi
  for k in "${SECRETS_KEYRING_KEYS[@]}"; do
    have_key=0
    printf '%s\n' "$scan" | grep -qxF "attribute.key = $k" && have_key=1
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
  echo "Test fetch:"
  for n in "$SECRET_GITHUB" "$SECRET_CLAUDE"; do
    if ! secret_fetch_or_error "$n"; then
      echo "  $n: FAILED: $SECRET_ERROR"; failed=1
    elif v=$(printf '%s' "$SECRET_VALUE" | secret_shape_problem "$n"); then
      echo "  $n: FAILED: $v (${#SECRET_VALUE} chars)"; failed=1
    else
      echo "  $n: ok (${#SECRET_VALUE} chars, $(printf '%s' "$SECRET_VALUE" | secret_shape_label))"
    fi
  done
  SECRET_VALUE='' v=''
  [ "$failed" = 0 ] || die "a test fetch failed; check the values on the Infisical website and run devenv secrets-init again (3 failed logins lock sbx-host for 5 minutes)"
  ok "done; the Infisical website tab can be closed"
}
