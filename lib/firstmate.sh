# shellcheck shell=bash
# Automatic Firstmate updates (FIRSTMATE_AUTO_UPDATE in devenv.conf). Needs
# lib/common.sh, load_config and resolve_paths.
#
#   1. firstmate_sync_fork: fast-forward the fork (FIRSTMATE_REPO) from
#      FIRSTMATE_UPSTREAM on GitHub, only when the fork is strictly behind.
#      A fork with commits of its own is never merged; the sync stops and
#      `devenv check` warns.
#   2. firstmate_update_home: Firstmate's own updater (bin/fm-update.sh,
#      fast-forward only) brings $FM_HOME up to the fork's main.
#
# `devenv entry` runs both just before it starts a first mate, so a running
# first mate is never updated under its feet. Each prints one status line,
# never fails its caller, and records its last result in the cache for
# `devenv check`.

# owner/repo from a GitHub URL.
gh_slug() {
  local u=${1%/}
  u=${u%.git}
  printf '%s' "${u#https://github.com/}"
}

_fm_record() {  # <file> <line>: print the status line and keep it for devenv check
  mkdir -p "$DEVENV_CACHE"
  printf '%s\n' "$2" | tee "$DEVENV_CACHE/$1" >&2
}

firstmate_sync_fork() {
  local fork up cmp status ahead behind out
  [ "$FIRSTMATE_AUTO_UPDATE" = on ] && [ -n "${FIRSTMATE_UPSTREAM:-}" ] || return 0
  fork=$(gh_slug "$FIRSTMATE_REPO")
  up=$(gh_slug "$FIRSTMATE_UPSTREAM")
  if ! have gh || ! cmp=$(timeout 15 gh api "repos/$up/compare/main...${fork%%/*}:main" 2>/dev/null </dev/null); then
    _fm_record firstmate-sync "firstmate sync: skipped (could not compare $fork with $up)"
    return 0
  fi
  status=$(printf '%s' "$cmp" | jq -r '.status // empty')
  ahead=$(printf '%s' "$cmp" | jq -r '.ahead_by // 0')
  behind=$(printf '%s' "$cmp" | jq -r '.behind_by // 0')
  case "$status" in
    identical|ahead)
      _fm_record firstmate-sync "firstmate sync: $fork is up to date with $up" ;;
    behind)
      if out=$(timeout 30 gh api -X POST "repos/$fork/merge-upstream" -f branch=main 2>&1 </dev/null); then
        _fm_record firstmate-sync "firstmate sync: fast-forwarded $fork by $behind commits from $up"
      elif printf '%s' "$out" | grep -qi workflow; then
        _fm_record firstmate-sync "firstmate sync: failed: the new upstream commits change workflow files, and the gej-machine token lacks the \`workflow\` scope (add it, or click Sync fork on GitHub)"
      else
        _fm_record firstmate-sync "firstmate sync: failed: $(printf '%s' "$out" | tail -n 1)"
      fi ;;
    diverged)
      _fm_record firstmate-sync "firstmate sync: stopped: $fork has $ahead commits that $up doesn't (fast-forward only); rebase the fork on $up to resume" ;;
    *)
      _fm_record firstmate-sync "firstmate sync: skipped (unexpected compare status '${status:-none}')" ;;
  esac
  return 0
}

firstmate_update_home() {
  local out line
  [ "$FIRSTMATE_AUTO_UPDATE" = on ] || return 0
  [ -f "$FM_HOME/bin/fm-update.sh" ] || return 0
  if ! out=$(cd "$FM_HOME" && FM_HOME=$FM_HOME timeout 120 bash bin/fm-update.sh 2>&1 </dev/null); then
    _fm_record firstmate-update "firstmate update: failed: $(printf '%s' "$out" | tail -n 1)"
    return 0
  fi
  line=$(printf '%s\n' "$out" | grep -m1 '^firstmate: ' || true)
  line=${line#firstmate: }
  _fm_record firstmate-update "firstmate update: ${line:-done}"
  return 0
}
