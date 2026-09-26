#!/bin/bash
# Claude Code status line wrapper, installed by devenv as ~/.claude/statusline.sh.
#
# With no devenv warnings, this execs the owner's original script
# (~/.claude/statusline-command.sh) with the untouched stdin, so the output is
# byte-identical to running the original directly. When the warnings cache
# (~/.cache/devenv/warnings) has lines and DEVENV_STATUSLINE_WARNINGS is on,
# it appends a red "⚠ devenv:N" marker. It never waits on the network: a stale
# cache triggers a detached `devenv check --quiet` in the background.
set -uo pipefail

orig="$HOME/.claude/statusline-command.sh"
cache="${XDG_CACHE_HOME:-$HOME/.cache}/devenv/warnings"
paths="${XDG_CONFIG_HOME:-$HOME/.config}/devenv/paths.env"

mode=${DEVENV_STATUSLINE_WARNINGS:-}
DEVENV_DIR=${DEVENV_DIR:-}
if [ -r "$paths" ]; then
  env_mode=$mode
  # shellcheck source=/dev/null
  . "$paths"
  [ -n "$env_mode" ] && mode=$env_mode
fi
mode=${mode:-${DEVENV_STATUSLINE_WARNINGS:-on}}

# Refresh the warnings cache in the background when it is older than 6 hours.
# A stamp file keeps concurrent status line renders from starting many checks.
refresh() {
  local stamp="$cache.refreshing" devenv="$DEVENV_DIR/bin/devenv"
  [ -n "$DEVENV_DIR" ] && [ -x "$devenv" ] || return 0
  if [ -f "$cache" ] && [ -z "$(find "$cache" -mmin +360 2>/dev/null)" ]; then
    return 0
  fi
  if [ -f "$stamp" ] && [ -z "$(find "$stamp" -mmin +15 2>/dev/null)" ]; then
    return 0
  fi
  mkdir -p "${cache%/*}" 2>/dev/null && : > "$stamp" 2>/dev/null || return 0
  if command -v setsid >/dev/null 2>&1; then
    setsid "$devenv" check --quiet </dev/null >/dev/null 2>&1 &
  else
    nohup "$devenv" check --quiet </dev/null >/dev/null 2>&1 &
  fi
}
refresh

n=0
if [ "$mode" = on ] && [ -s "$cache" ]; then
  n=$(grep -c . "$cache" 2>/dev/null || true)
fi

if [ "${n:-0}" -eq 0 ]; then
  exec bash "$orig"
fi

# Keep the original output byte-exact, including any trailing newlines.
out=$(bash "$orig"; printf x)
out=${out%x}
printf '%s' "$out"
printf '%s' $'\033[2m | \033[0m'$'\033[31m'"⚠ devenv:$n"$'\033[0m'
