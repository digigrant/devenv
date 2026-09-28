# shellcheck shell=bash
# devenv host-prepare: the sbxenv.yaml lifecycle.initialize hook (spec §6.9).
# Runs on the host before every `sbx env run`:
#   - unlock the keyring when it is locked (asks for its password once);
#   - doctor-lite: fail fast when the keyring entries are missing, a secret
#     can't be fetched from Infisical or has the wrong shape or account, or
#     the checkout overlaps a sandbox workspace other than its own dev/;
#   - create the workspace folder dev/ beside sbxenv.yaml;
#   - give the sandbox its two secrets from Infisical, each with its refresh
#     from devenv.conf: the gej-machine GitHub token as the github service
#     secret, and the Claude setup-token as a custom secret (V1).
# Secret values stay in variables and are never printed. It never reads
# anything from dev/, which the sandbox can write.

# Uses path_within, host_workspaces and checkout_overlap_problems (doctor.sh)
# and the keyring, Infisical and refresh helpers (lib/secrets.sh); bin/devenv
# sources them.

# The error line from sbx's output ("error: …"), or its last line. sbx never
# shows a command source's own output unless asked (--show-error), so this
# can't carry a secret value.
sbx_error_line() {
  printf '%s\n' "$1" | grep -m 1 '^error:' || printf '%s\n' "$1" | tail -n 1
}

# The gej-machine token as this sandbox's github service secret. It is set
# here rather than in sbxenv.yaml's secrets:, which can't read devenv.conf's
# refresh settings; sbxenv.yaml's bindings.github still approves its domains.
# sbx checks the command by running it once. `sbx env rm` deletes it with the
# rest of the sandbox's scope.
sync_github_secret() {
  local refresh out cmd
  refresh=$(secret_refresh github)
  # sbx stores this command text in plain text: a path and a name only.
  cmd="$(printf '%q' "$DEVENV_REAL/bin/devenv") secret-get $SECRET_GITHUB"
  if ! out=$(sbx secret set github --sandbox "$CONF_SANDBOX_NAME" --command "$cmd" --refresh "$refresh" 2>&1 </dev/null); then
    die "sbx secret set github failed: $(sbx_error_line "$out")"
  fi
  ok "gej-machine token ($SECRET_GITHUB) available to sandbox $CONF_SANDBOX_NAME as the github secret (refresh $refresh)"
}

# The Claude setup-token as an sbx custom secret for this sandbox (V1).
# sbx keeps one custom secret per env var in a sandbox's scope, keyed by its
# placeholder: set-custom with the placeholder sbx already holds updates it,
# and any other placeholder is refused ("already exists in scope"). So the
# placeholder lives in sbx alone: host-prepare reads it back and reuses it, and
# makes a random one only when sbx has none. The sandbox's environment gets
# the placeholder when the sandbox is created, so it must not change while the
# sandbox exists; reusing it also keeps a running sandbox signed in.
CLAUDE_TOKEN_ENV=CLAUDE_CODE_OAUTH_TOKEN
CLAUDE_TOKEN_HOST=api.anthropic.com

# The placeholder sbx holds for CLAUDE_CODE_OAUTH_TOKEN in the sandbox's scope,
# or nothing. Dies when sbx fails or its answer has no custom_secrets list.
claude_token_placeholder_in_sbx() {
  local out
  out=$(sbx secret ls --sandbox "$CONF_SANDBOX_NAME" --json </dev/null) \
    || die "sbx secret ls --sandbox $CONF_SANDBOX_NAME --json failed"
  printf '%s' "$out" | jq -er --arg scope "$CONF_SANDBOX_NAME" --arg env "$CLAUDE_TOKEN_ENV" '
      if (.custom_secrets | type) == "array" then . else error("no custom_secrets") end
      | [.custom_secrets[] | select(.scope == $scope and .env == $env) | .placeholder | strings][0] // ""' 2>/dev/null \
    || die "sbx secret ls --json gave no custom_secrets list, so the Claude placeholder can't be read (sbx 0.45.1 does; has its output changed?)"
}

sync_claude_auth() {
  local old=$HOME/.config/devenv/claude-oauth-placeholder ph how refresh out cmd
  # Before sbx kept the placeholder, host-prepare kept it in this file.
  if [ -e "$old" ]; then
    rm -f "$old"
    log "removed ~/.config/devenv/claude-oauth-placeholder (sbx keeps the placeholder now)"
  fi
  case "$CLAUDE_AUTH" in
    token)
      ph=$(claude_token_placeholder_in_sbx) || exit 1
      if [ -n "$ph" ]; then
        how=reused
      else
        how=new
        ph=sbx-cs-devenv-$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n')
      fi
      refresh=$(secret_refresh claude)
      # sbx stores this command text in plain text: a path and a name only.
      cmd="$(printf '%q' "$DEVENV_REAL/bin/devenv") secret-get $SECRET_CLAUDE"
      if ! out=$(sbx secret set-custom --sandbox "$CONF_SANDBOX_NAME" --host "$CLAUDE_TOKEN_HOST" \
                 --env "$CLAUDE_TOKEN_ENV" --placeholder "$ph" --command "$cmd" --refresh "$refresh" 2>&1 </dev/null); then
        die "sbx secret set-custom failed: $(sbx_error_line "$out")"
      fi
      ok "Claude setup-token available to sandbox $CONF_SANDBOX_NAME as CLAUDE_CODE_OAUTH_TOKEN ($how placeholder, refresh $refresh)"
      ;;
    login)
      # Scoped by sandbox, host and env: without --sandbox, sbx looks only at
      # global secrets. It exits 0 when there is nothing to remove.
      if ! out=$(sbx secret rm --sandbox "$CONF_SANDBOX_NAME" --host "$CLAUDE_TOKEN_HOST" \
                 --env "$CLAUDE_TOKEN_ENV" -f 2>&1 </dev/null); then
        case "$out" in
          *"No custom secret found"*) ;;
          *) die "sbx secret rm failed: $(sbx_error_line "$out")" ;;
        esac
      fi
      if printf '%s\n' "$out" | grep -q '^Deleted '; then
        log "removed the Claude setup-token custom secret from sandbox $CONF_SANDBOX_NAME (CLAUDE_AUTH=login)"
      fi
      ;;
    *) die "CLAUDE_AUTH in devenv.conf must be token or login, not '$CLAUDE_AUTH'" ;;
  esac
}

cmd_host_prepare() {
  local real t problems
  [ "$(detect_mode)" = sbx ] && die "host-prepare runs on the host, not inside a sandbox"
  case "$CLAUDE_AUTH" in token|login) ;; *) die "CLAUDE_AUTH in devenv.conf must be token or login, not '$CLAUDE_AUTH'" ;; esac
  problems=$(secret_refresh_problems)
  [ -z "$problems" ] || die "$(head -n 1 <<<"$problems")"
  real=$(readlink -f "$DEVENV_ROOT")
  DEVENV_REAL=$real
  keyring_unlock_if_locked
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
  sync_github_secret
  sync_claude_auth
  return 0
}
