# shellcheck shell=bash
# devenv start: re-apply configuration at every sandbox start (spec §6.5).
# Runs as the agent user from the kit's setup.startup, detached from the
# session. Idempotent and quick; network checks have timeouts. It never fails
# the startup dispatcher: problems are reported as warnings.

# The built-in claude kit's startup commands run from the same dispatcher,
# before this kit's (they are ordered by kit). Wait, briefly, until each of
# them has logged ok/fail in the current dispatcher run (V10). Returns at once
# outside sbx.
wait_for_sbx_startup() {
  local log=/var/log/sbx-kit-startup.log root=/etc/durable-startup.d i f pending run
  [ -r "$log" ] && [ -d "$root" ] || return 0
  for i in $(seq 1 60); do
    run=$(awk '/^=== dispatcher run /{ buf = "" } { buf = buf $0 "\n" } END { printf "%s", buf }' "$log")
    pending=0
    for f in "$root"/*claude*/*-cmd.sh; do
      [ -e "$f" ] || continue
      printf '%s' "$run" | grep -qE "^(ok|fail) $f" || pending=1
    done
    [ "$pending" = 0 ] && return 0
    sleep 0.5
  done
  warn "built-in claude kit startup still running after 30s; continuing"
}

cmd_start() {
  local mode t0
  t0=$(date +%s)
  mode=$(detect_mode)
  resolve_paths "$mode"
  export PATH="$LOCAL_BIN:$DEVENV_ROOT/bin:$PATH"
  [ "$mode" = sbx ] && wait_for_sbx_startup
  apply_claude_config with-integrations || warn "applying Claude settings failed"
  install_herdr_config || warn "installing herdr config failed"
  link_claude_memory || warn "linking Claude memory failed"
  if [ "$mode" = plain ] || [ "$DEVENV_SKILLS" = link ]; then link_skills || warn "linking skills failed"; fi
  cmd_check --quiet || true
  log "start done in $(( $(date +%s) - t0 ))s"
  return 0
}
