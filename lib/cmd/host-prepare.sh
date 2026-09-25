# shellcheck shell=bash
# devenv host-prepare: the sbxenv.yaml lifecycle.initialize hook (spec §6.9).
# Runs on the host before every `sbx env run`:
#   - doctor-lite: fail fast on missing/unsafe secret files, or a checkout
#     that overlaps a sandbox workspace;
#   - sync devenv/skills into sbx's shared skills store (V4);
#   - stage the provisioning payload into the kit when DEVENV_STAGE_PAYLOAD=on (V7).
# It never writes anywhere the sandbox can write.

# Uses path_within/host_workspaces (doctor.sh) and cmd_skills_sync
# (skills-sync.sh); bin/devenv sources both.

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
  local tok=$HOME/.config/devenv/secrets/anthropic phf=$HOME/.config/devenv/claude-oauth-placeholder ph out
  case "$CLAUDE_AUTH" in
    token)
      [ -f "$tok" ] || die "missing $tok: put the \`claude setup-token\` token there (see README), or set CLAUDE_AUTH=login"
      [ "$(stat -c %a "$tok")" = 600 ] || die "$tok is mode $(stat -c %a "$tok"); run: chmod 600 $tok"
      [ "$(stat -c %U "$tok")" = "$(id -un)" ] || die "$tok is not owned by $(id -un)"
      local tp
      if tp=$(claude_token_file_problem "$tok"); then die "$tp"; fi
      ph=$(claude_token_placeholder)
      if ! out=$(sbx secret set-custom --sandbox "$CONF_SANDBOX_NAME" --host api.anthropic.com \
                 --env CLAUDE_CODE_OAUTH_TOKEN --placeholder "$ph" --command "cat $(printf '%q' "$tok")" 2>&1 </dev/null); then
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

stage_payload() {
  local dest="$DEVENV_ROOT/kits/devenv/files/home/.local/share/devenv-payload"
  rm -rf "$dest.new"
  mkdir -p "$dest.new"
  (cd "$DEVENV_ROOT" && tar -cf - --exclude=.git --exclude=kits --exclude=.sbxenv.rendered.yaml .) | tar -xf - -C "$dest.new"
  rm -rf "$dest"
  mv "$dest.new" "$dest"
  log "staged the provisioning payload in ${dest#"$DEVENV_ROOT"/} (V7 fallback)"
}

cmd_host_prepare() {
  local f mode ws real
  [ "$(detect_mode)" = sbx ] && die "host-prepare runs on the host, not inside a sandbox"
  for f in github; do
    f="$HOME/.config/devenv/secrets/$f"
    [ -f "$f" ] || die "missing secret file $f (see README: Secrets)"
    mode=$(stat -c %a "$f")
    [ "$mode" = 600 ] || die "$f is mode $mode; run: chmod 600 $f"
    [ "$(stat -c %U "$f")" = "$(id -un)" ] || die "$f is not owned by $(id -un)"
    [ -s "$f" ] || die "$f is empty"
  done
  real=$(readlink -f "$DEVENV_ROOT")
  DEVENV_REAL=$real
  while IFS= read -r ws; do
    [ -n "$ws" ] || continue
    if path_within "$real" "$ws" || path_within "$ws" "$real"; then
      die "the devenv checkout ($real) overlaps a sandbox workspace ($ws); keep it outside, e.g. ~/devenv"
    fi
  done < <(host_workspaces | sort -u)
  local t
  while IFS= read -r t; do
    [ -n "$t" ] || continue
    case "$t" in "warn: "*) warn "${t#warn: }" ;; *) die "$t" ;; esac
  done <<<"$(github_secret_problems)"
  ok "secrets and checkout location look right"
  sync_claude_auth
  if [ "$DEVENV_SKILLS" = store ]; then
    cmd_skills_sync || warn "skills were not synced into the sbx store; see docs/HOST-VERIFY.md (V4) for the fallback"
  fi
  [ "$DEVENV_STAGE_PAYLOAD" = on ] && stage_payload
  return 0
}
