# shellcheck shell=bash
# devenv host-prepare: the sbxenv.yaml lifecycle.initialize hook (spec §6.9).
# Runs on the host before every `sbx env run`:
#   - unlock the keyring when it is locked (asks for its password once);
#   - doctor-lite: fail fast when the keyring entries are missing, a secret
#     can't be fetched from Infisical or has the wrong shape or account, or
#     the checkout overlaps a sandbox workspace other than its own dev/;
#   - create the workspace folder dev/ beside sbxenv.yaml;
#   - give the sandbox the Claude setup-token as a custom secret (V1).
# Secret values stay in variables and are never printed. It never reads
# anything from dev/, which the sandbox can write.

# Uses path_within, host_workspaces and checkout_overlap_problems (doctor.sh)
# and the keyring and Infisical helpers (lib/secrets.sh); bin/devenv sources
# them.

# The Claude setup-token as an sbx custom secret for this sandbox (V1).
# The placeholder is random, created once, and kept on the host (never in the
# repo, which agents can read), so re-running set-custom ("create or update")
# changes nothing for a sandbox that already carries it.
claude_token_placeholder() {
  local f=$HOME/.config/devenv/claude-oauth-placeholder
  if [ ! -s "$f" ]; then
    mkdir -p "${f%/*}"
    (umask 077; printf 'sbx-cs-devenv-%s\n' "$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n')" > "$f")
  fi
  tr -d '\r\n' < "$f"
}

sync_claude_auth() {
  local phf=$HOME/.config/devenv/claude-oauth-placeholder ph out cmd
  case "$CLAUDE_AUTH" in
    token)
      ph=$(claude_token_placeholder)
      # sbx stores this command text in plain text: a path and a name only.
      cmd="$(printf '%q' "$DEVENV_REAL/bin/devenv") secret-get $SECRET_CLAUDE"
      if ! out=$(sbx secret set-custom --sandbox "$CONF_SANDBOX_NAME" --host api.anthropic.com \
                 --env CLAUDE_CODE_OAUTH_TOKEN --placeholder "$ph" --command "$cmd" 2>&1 </dev/null); then
        die "sbx secret set-custom failed: $(printf '%s' "$out" | tail -n 1)"
      fi
      ok "Claude setup-token available to sandbox $CONF_SANDBOX_NAME as CLAUDE_CODE_OAUTH_TOKEN (placeholder)"
      ;;
    login)
      if [ -s "$phf" ]; then
        sbx secret rm --placeholder "$(tr -d '\r\n' < "$phf")" -f >/dev/null 2>&1 </dev/null || true
        rm -f "$phf"
        log "removed the Claude setup-token custom secret (CLAUDE_AUTH=login)"
      fi
      ;;
    *) die "CLAUDE_AUTH in devenv.conf must be token or login, not '$CLAUDE_AUTH'" ;;
  esac
}

# The github command in sbxenv.yaml names the secret itself; it must match
# SECRET_GITHUB, or secret-get refuses it and the sandbox gets no token.
sbxenv_github_command_problem() {
  grep -qE "^[[:space:]]*command:.*secret-get $SECRET_GITHUB'?[[:space:]]*\$" "$DEVENV_REAL/sbxenv.yaml" && return 1
  echo "sbxenv.yaml's github command does not run \`devenv secret-get $SECRET_GITHUB\` (SECRET_GITHUB in devenv.conf)"
}

cmd_host_prepare() {
  local real p t problems
  [ "$(detect_mode)" = sbx ] && die "host-prepare runs on the host, not inside a sandbox"
  case "$CLAUDE_AUTH" in token|login) ;; *) die "CLAUDE_AUTH in devenv.conf must be token or login, not '$CLAUDE_AUTH'" ;; esac
  real=$(readlink -f "$DEVENV_ROOT")
  DEVENV_REAL=$real
  keyring_unlock_if_locked
  if p=$(sbxenv_github_command_problem); then die "$p"; fi
  while IFS= read -r t; do
    [ -n "$t" ] || continue
    case "$t" in "ok: "*) ;; "warn: "*) warn "${t#warn: }" ;; *) die "$t" ;; esac
  done < <(secrets_problems)
  while IFS= read -r t; do
    [ -n "$t" ] && warn "$t"
  done < <(secrets_leftovers)
  problems=$(checkout_overlap_problems)
  [ -z "$problems" ] || die "$(head -n 1 <<<"$problems")"
  ok "Infisical secrets and checkout location look right"
  if [ ! -d "$real/dev" ]; then
    mkdir -p "$real/dev"
    ok "created the workspace $real/dev"
  fi
  sync_claude_auth
  return 0
}
