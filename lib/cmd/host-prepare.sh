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
  for f in anthropic github; do
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
  if [ "$DEVENV_SKILLS" = store ]; then
    cmd_skills_sync || warn "skills were not synced into the sbx store; see docs/HOST-VERIFY.md (V4) for the fallback"
  fi
  [ "$DEVENV_STAGE_PAYLOAD" = on ] && stage_payload
  return 0
}
