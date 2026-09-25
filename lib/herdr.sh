# shellcheck shell=bash
# herdr configuration and server helpers. Needs lib/common.sh and load_config.

HERDR_CONFIG_DIR=${HERDR_CONFIG_DIR:-$HOME/.config/herdr}

# Install herdr/config.toml and the Claude detection override. A user's
# config.toml that differs is kept as config.toml.bak before it is replaced.
# A running server is told to reload whatever changed.
install_herdr_config() {
  local cfg=$HERDR_CONFIG_DIR/config.toml src=$DEVENV_ROOT/herdr/config.toml
  local man=$HERDR_CONFIG_DIR/agent-detection/claude.toml msrc=$DEVENV_ROOT/herdr/agent-detection/claude.toml
  local cfg_changed man_changed
  mkdir -p "$HERDR_CONFIG_DIR/agent-detection"
  if [ -f "$cfg" ] && ! cmp -s "$cfg" "$src"; then
    cp -p "$cfg" "$cfg.bak"
    log "kept your previous herdr config as $cfg.bak"
  fi
  cfg_changed=$(write_if_changed "$cfg" 0644 < "$src")
  [ "$(file_sha256 "$msrc")" = "$HERDR_CLAUDE_MANIFEST_SHA256" ] \
    || die "$msrc does not match HERDR_CLAUDE_MANIFEST_SHA256 in versions.env"
  man_changed=$(write_if_changed "$man" 0644 < "$msrc")
  if herdr_server_running; then
    [ "$cfg_changed" = changed ] && herdr server reload-config >/dev/null 2>&1
    [ "$man_changed" = changed ] && herdr server reload-agent-manifests >/dev/null 2>&1
  fi
  return 0
}

herdr_server_running() {
  have herdr || return 1
  herdr status server --json 2>/dev/null | jq -e '.running == true' >/dev/null 2>&1
}

# Start the herdr server detached from this process, so it outlives the
# terminal that started it, and wait until it answers.
ensure_herdr_server() {
  local i
  herdr_server_running && return 0
  mkdir -p "$DEVENV_CACHE"
  setsid herdr server >>"$DEVENV_CACHE/herdr-server.log" 2>&1 </dev/null &
  for i in $(seq 1 50); do
    herdr_server_running && return 0
    sleep 0.2
  done
  warn "herdr server did not start; see $DEVENV_CACHE/herdr-server.log"
  return 1
}

# ID of the first workspace with the given label, or empty.
herdr_workspace_id() {
  herdr workspace list 2>/dev/null \
    | jq -r --arg l "$1" '[.result.workspaces[]? | select(.label == $l)][0].workspace_id // empty'
}

# Which manifest herdr uses for claude: "local override" when devenv's is active.
herdr_claude_manifest_source() {
  herdr server agent-manifests --json 2>/dev/null \
    | jq -r '[(.result.manifests // .manifests // [])[] | select(.agent == "claude")][0] | "\(.source_kind) \(.active_version)"' 2>/dev/null
}
