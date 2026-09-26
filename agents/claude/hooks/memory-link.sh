#!/bin/bash
# Keep Claude Code's auto-memory outside the sandbox's own disk, installed by
# devenv as ~/.claude/hooks/devenv-memory-link.sh.
#
# Claude stores memory per project in ~/.claude/projects/<slug>/memory/. This
# script makes each of those a symlink to
# $DEVENV_STATE_DIR/claude-memory/<slug>/, which lives in the host workspace
# and therefore survives `sbx rm` and a rebuild.
#
#   memory-link.sh --hook   Claude SessionStart hook: link the current project
#                           (slug from the hook's transcript_path or cwd).
#   memory-link.sh --all    Link every project that has memory, and every
#                           project the state folder already knows about.
#
# It must never fail a session: errors go to stderr and it always exits 0.
# It prints nothing on stdout, because SessionStart hook output becomes
# conversation context.
set -uo pipefail

paths="${XDG_CONFIG_HOME:-$HOME/.config}/devenv/paths.env"
# shellcheck source=/dev/null
[ -r "$paths" ] && . "$paths"
state=${DEVENV_STATE_DIR:-}
[ -n "$state" ] || exit 0
store="$state/claude-memory"
projects="$HOME/.claude/projects"

link_one() {
  local slug=$1 proj mem dst f base
  case "$slug" in ''|.|..|*/*) return 0 ;; esac
  proj="$projects/$slug"
  mem="$proj/memory"
  dst="$store/$slug"
  mkdir -p "$dst" "$proj" || return 0
  if [ -L "$mem" ]; then
    [ "$(readlink "$mem")" = "$dst" ] && return 0
    rm -f "$mem"
  elif [ -d "$mem" ]; then
    # Move real memory into the store. Never overwrite a stored file that
    # differs; keep the incoming copy beside it instead.
    for f in "$mem"/* "$mem"/.[!.]*; do
      [ -e "$f" ] || continue
      base=${f##*/}
      if [ ! -e "$dst/$base" ]; then
        mv "$f" "$dst/$base"
      elif cmp -s "$f" "$dst/$base"; then
        rm -rf "$f"
      else
        mv "$f" "$dst/$base.conflict-$(date +%Y%m%d%H%M%S)"
      fi
    done
    rmdir "$mem" 2>/dev/null || { echo "devenv: $mem not empty; left as is" >&2; return 0; }
  elif [ -e "$mem" ]; then
    echo "devenv: $mem is not a directory; left as is" >&2
    return 0
  fi
  ln -s "$dst" "$mem"
}

case "${1:---all}" in
  --hook)
    input=$(cat 2>/dev/null || true)
    slug=
    if command -v jq >/dev/null 2>&1; then
      tp=$(printf '%s' "$input" | jq -r '.transcript_path // empty' 2>/dev/null || true)
      if [ -n "$tp" ]; then
        slug=${tp%/*}
        slug=${slug##*/}
      else
        cwd=$(printf '%s' "$input" | jq -r '.cwd // empty' 2>/dev/null || true)
        [ -n "$cwd" ] && slug=$(printf '%s' "$cwd" | sed 's/[^A-Za-z0-9]/-/g')
      fi
    fi
    [ -z "$slug" ] && slug=$(printf '%s' "$PWD" | sed 's/[^A-Za-z0-9]/-/g')
    link_one "$slug" >&2
    ;;
  --all)
    mkdir -p "$store" "$projects" || exit 0
    for d in "$projects"/*/memory; do
      [ -d "$d" ] && [ ! -L "$d" ] || continue
      p=${d%/memory}
      link_one "${p##*/}"
    done
    for d in "$store"/*/; do
      [ -d "$d" ] || continue
      d=${d%/}
      link_one "${d##*/}"
    done
    ;;
  *)
    echo "usage: ${0##*/} --hook|--all" >&2
    ;;
esac
exit 0
