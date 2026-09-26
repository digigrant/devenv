# shellcheck shell=bash
# devenv entry: the sandbox entrypoint (spec §6.6). DEVENV_ENTRY selects:
#   herdr  (default) herdr with a "firstmate" workspace running the first mate
#   claude           plain Claude in the workspace
#   shell            a login shell
# Any failure before handing over falls back to a login shell. Arguments are
# ignored: through `extends: claude` the kit may pass the parent's always-on
# claude flags (e.g. --dangerously-skip-permissions) to the entrypoint.

_entry_fallback() {
  local rc=$1
  trap - EXIT
  [ "$rc" -eq 0 ] && exit 0
  warn "devenv entry failed (exit $rc); starting a shell instead"
  exec bash -l
}

print_warnings() {
  local f="$DEVENV_CACHE/warnings" line
  [ -s "$f" ] || return 0
  while IFS= read -r line; do
    [ -n "$line" ] && printf '\033[33m⚠ devenv: %s\033[0m\n' "$line" >&2
  done < "$f"
  return 0
}

# Make sure a "firstmate" workspace exists; create it with the first mate
# running when it does not. Serialized, so two entries cannot both create one.
ensure_firstmate_workspace() {
  local ws out pane
  mkdir -p "$DEVENV_CACHE"
  exec 8>"$DEVENV_CACHE/entry.lock"
  have flock && flock -w 20 8
  ws=$(herdr_workspace_id firstmate)
  if [ -n "$ws" ]; then
    herdr workspace focus "$ws" >/dev/null 2>&1 || true
  else
    [ -d "$FM_HOME" ] || die "Firstmate home $FM_HOME is missing; run provision.sh"
    # A new first mate is about to start: bring Firstmate up to date first
    # (FIRSTMATE_AUTO_UPDATE), so it never changes under a running one.
    firstmate_sync_fork
    firstmate_update_home
    out=$(herdr workspace create --cwd "$FM_HOME" --label firstmate --focus)
    pane=$(printf '%s' "$out" | jq -r '.result.root_pane.pane_id // empty')
    [ -n "$pane" ] || die "herdr did not return a pane for the new workspace: $out"
    herdr pane run "$pane" "claude --dangerously-skip-permissions --effort $FIRSTMATE_EFFORT" >/dev/null
    log "started the first mate in herdr workspace \"firstmate\" (effort $FIRSTMATE_EFFORT)"
  fi
  exec 8>&-
}

cmd_entry() {
  local mode choice=${DEVENV_ENTRY:-herdr}
  trap '_entry_fallback $?' EXIT
  mode=$(detect_mode)
  resolve_paths "$mode"
  export PATH="$LOCAL_BIN:$DEVENV_ROOT/bin:$PATH"
  # V10 fallback: re-apply settings in case anything rewrote settings.json
  # after `devenv start` (which is detached and may also still be running).
  apply_claude_config with-integrations || warn "applying Claude settings failed"
  print_warnings
  case "$choice" in
    herdr)
      have herdr || die "herdr is not installed; run provision.sh"
      ensure_herdr_server || die "cannot start the herdr server"
      ensure_firstmate_workspace
      trap - EXIT
      exec herdr
      ;;
    claude)
      cd "$WORKSPACE" || die "cannot cd to $WORKSPACE"
      trap - EXIT
      exec claude --dangerously-skip-permissions
      ;;
    shell)
      trap - EXIT
      exec bash -l
      ;;
    *)
      warn "DEVENV_ENTRY=$choice is not valid; use herdr, claude or shell. Starting a shell."
      trap - EXIT
      exec bash -l
      ;;
  esac
}
