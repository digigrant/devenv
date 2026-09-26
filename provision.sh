#!/usr/bin/env bash
# provision.sh: the portable devenv installer (spec §6.3).
#
#   provision.sh [--sbx|--plain] [--yes] [--git-identity bot|skip] [--skip-claude-install]
#
# --sbx     inside a Docker Sandbox (the kit's setup.install runs this as root)
# --plain   any Debian/Ubuntu machine without sbx
# Without a mode flag it detects one: --sbx when IS_SANDBOX=1 or SANDBOX_NAME
# is set. --git-identity defaults to "bot" in sbx mode and "skip" in plain
# mode. --skip-claude-install (or DEVENV_SKIP_CLAUDE_INSTALL=1) skips
# installing Claude Code in plain mode; tests use it.
#
# Every step is idempotent: a second run changes nothing and exits 0.
set -euo pipefail

DEVENV_ROOT=$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)
# shellcheck source=lib/common.sh
. "$DEVENV_ROOT/lib/common.sh"
# shellcheck source=lib/tools.sh
. "$DEVENV_ROOT/lib/tools.sh"
# shellcheck source=lib/claude.sh
. "$DEVENV_ROOT/lib/claude.sh"
# shellcheck source=lib/herdr.sh
. "$DEVENV_ROOT/lib/herdr.sh"
# shellcheck source=lib/cmd/check.sh
. "$DEVENV_ROOT/lib/cmd/check.sh"

usage() { sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//'; }

MODE='' YES=0 GIT_IDENTITY='' PHASE=all
SKIP_CLAUDE=${DEVENV_SKIP_CLAUDE_INSTALL:-0}
while [ $# -gt 0 ]; do
  case "$1" in
    --sbx) MODE=sbx ;;
    --plain) MODE=plain ;;
    --yes|-y) YES=1 ;;
    --git-identity) GIT_IDENTITY=${2:-}; shift ;;
    --git-identity=*) GIT_IDENTITY=${1#*=} ;;
    --skip-claude-install) SKIP_CLAUDE=1 ;;
    --phase) PHASE=${2:-}; shift ;;   # internal: "user" after dropping root
    -h|--help) usage; exit 0 ;;
    *) die "unknown argument: $1 (see --help)" ;;
  esac
  shift
done
MODE=${MODE:-$(detect_mode)}
if [ -z "$GIT_IDENTITY" ]; then
  if [ "$MODE" = sbx ]; then GIT_IDENTITY=bot; else GIT_IDENTITY=skip; fi
fi
case "$GIT_IDENTITY" in bot|skip) ;; *) die "--git-identity must be bot or skip" ;; esac

load_config
SYSTEM_PREFIX=${DEVENV_SYSTEM_PREFIX:-/usr/local}

# ------------------------------------------------------------------ steps

# 1. System packages. Never tmux.
step_packages() {
  local p missing=() pkgs=(git curl jq ca-certificates tar python3)
  [ "$MODE" = plain ] && pkgs+=(gh)
  if ! have dpkg-query; then
    for p in git curl jq tar; do have "$p" || die "$p is missing and this is not a Debian/Ubuntu system"; done
    return 0
  fi
  for p in "${pkgs[@]}"; do
    dpkg-query -W -f='${Status}' "$p" 2>/dev/null | grep -q 'install ok installed' || missing+=("$p")
  done
  if [ ${#missing[@]} -eq 0 ]; then ok "system packages present"; return 0; fi
  if [ "$YES" != 1 ] && [ -t 0 ]; then
    read -r -p "Install with apt: ${missing[*]}? [y/N] " a
    case "$a" in y|Y|yes) ;; *) die "cancelled" ;; esac
  fi
  log "apt-get install ${missing[*]}"
  as_root env DEBIAN_FRONTEND=noninteractive apt-get update -qq >/dev/null
  as_root env DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends "${missing[@]}" >/dev/null
  ok "installed ${missing[*]}"
}

# 2. Node >= NODE_MIN_VERSION.
step_node() {
  local v
  v=$(node_installed_version)
  if [ -n "$v" ] && version_ge "$v" "$NODE_MIN_VERSION"; then ok "node $v"; return 0; fi
  if [ "$MODE" = sbx ]; then
    die "node ${v:-missing} is older than $NODE_MIN_VERSION; the sandbox image should provide it"
  fi
  install_node
}

# 3. Pinned binaries in ~/.local/bin.
step_binaries() {
  local t
  for t in "${DEVENV_BINARIES[@]}"; do install_binary "$t"; done
}

# 4. npm globals, into the existing prefix (plain mode falls back to ~/.local).
step_npm() {
  local prefix
  have npm || die "npm not found"
  if [ "$MODE" = plain ] && [ -z "${NPM_CONFIG_PREFIX:-}" ]; then
    prefix=$(npm prefix -g)
    if [ ! -w "$prefix" ] || case ":$PATH:" in *":$prefix/bin:"*) false ;; *) true ;; esac; then
      if [ "$prefix" != "$HOME/.local" ]; then
        log "npm global prefix $prefix is not usable; using $HOME/.local"
        npm config set prefix "$HOME/.local"
        _npm_root=''
      fi
    fi
  fi
  install_npm_globals
  prefix=$(npm prefix -g)
  case ":$PATH:" in *":$prefix/bin:"*) ;; *) PATH="$prefix/bin:$PATH" ;; esac
  hash -r
}

# 5. Claude Code. Preinstalled in sbx; plain mode uses the official installer
# (the one documented exception to "no curl | sh": it updates itself anyway).
step_claude_code() {
  if have claude; then ok "claude $(claude --version 2>/dev/null | extract_version)"; return 0; fi
  if [ "$MODE" = sbx ]; then warn "claude not found; the sbx claude kit should provide it"; return 0; fi
  if [ "$SKIP_CLAUDE" = 1 ]; then log "skipping Claude Code install (--skip-claude-install)"; return 0; fi
  local tmp
  tmp=$(mktemp)
  log "notice: installing Claude Code with its official installer (documented exception to checksum pinning)"
  curl -fsSL --retry 3 -o "$tmp" https://claude.ai/install.sh || die "could not download the Claude Code installer"
  bash "$tmp"
  rm -f "$tmp"
  hash -r
}

env_block_content() {
  printf '%s\n' "# Managed by devenv provision.sh; re-run it instead of editing. Exports only:" \
                "# never add shell-completion scripts here."
  printf 'export DEVENV_DIR=%q\n' "$DEVENV_ROOT"
  printf 'export FM_HOME=%q\n' "$FM_HOME"
  printf 'export FM_PROJECTS_OVERRIDE="%s"\n' "$FM_PROJECTS_DIR_RAW"
  printf 'export DEVENV_STATE_DIR=%q\n' "$DEVENV_STATE_DIR"
  # Keep the npm global prefix the sandbox was provisioned with, so hooks
  # started with a trimmed environment still find the npm tools.
  if [ -n "${NPM_CONFIG_PREFIX:-}" ]; then
    printf 'export NPM_CONFIG_PREFIX=%q\n' "$NPM_CONFIG_PREFIX"
    # shellcheck disable=SC2016
    printf 'case ":$PATH:" in *":%s/bin:"*) ;; *) PATH="%s/bin:$PATH" ;; esac\n' "$NPM_CONFIG_PREFIX" "$NPM_CONFIG_PREFIX"
  fi
  # shellcheck disable=SC2016
  printf '%s\n' 'case ":$PATH:" in *":$HOME/.local/bin:"*) ;; *) PATH="$HOME/.local/bin:$PATH" ;; esac'
  # shellcheck disable=SC2016
  printf 'case ":$PATH:" in *":%s/bin:"*) ;; *) PATH="%s/bin:$PATH" ;; esac\n' "$DEVENV_ROOT" "$DEVENV_ROOT"
  printf '%s\n' 'export PATH'
}

# 6. Environment block: /etc/sandbox-persistent.sh (sbx) or
# ~/.config/devenv/env.sh sourced from ~/.bashrc (plain).
step_env_block() {
  local file r
  if [ "$MODE" = sbx ]; then
    file=${DEVENV_ENV_FILE:-/etc/sandbox-persistent.sh}
  else
    file=${DEVENV_ENV_FILE:-$DEVENV_CFG/env.sh}
    mkdir -p "${file%/*}"
  fi
  r=$(write_managed_block "$file" "$(env_block_content)")
  ok "environment block in $file ($r)"
  if [ "$MODE" = plain ]; then
    r=$(write_managed_block "$HOME/.bashrc" "[ -f $(printf '%q' "$file") ] && . $(printf '%q' "$file")")
    ok "~/.bashrc sources it ($r)"
  fi
  export DEVENV_DIR=$DEVENV_ROOT FM_HOME FM_PROJECTS_OVERRIDE=$FM_PROJECTS_DIR DEVENV_STATE_DIR
  case ":$PATH:" in *":$LOCAL_BIN:"*) ;; *) PATH="$LOCAL_BIN:$PATH" ;; esac
  case ":$PATH:" in *":$DEVENV_ROOT/bin:"*) ;; *) PATH="$DEVENV_ROOT/bin:$PATH" ;; esac
}

# sbx: install the entrypoint shim the kit launches, with this checkout baked
# in as the fallback location.
step_entry_shim() {
  [ "$MODE" = sbx ] || return 0
  local r
  r=$(sed "s|^DEVENV_DEFAULT_DIR=.*|DEVENV_DEFAULT_DIR=$(printf '%q' "$DEVENV_ROOT")|" "$DEVENV_ROOT/bin/devenv-entry" \
      | write_if_changed "$SYSTEM_PREFIX/bin/devenv-entry" 0755)
  ok "entrypoint $SYSTEM_PREFIX/bin/devenv-entry ($r)"
}

# 7. Git identity.
step_git_identity() {
  [ "$GIT_IDENTITY" = bot ] || return 0
  [ "$(git config --global user.name || true)" = "$BOT_LOGIN" ] || git config --global user.name "$BOT_LOGIN"
  [ "$(git config --global user.email || true)" = "$BOT_EMAIL" ] || git config --global user.email "$BOT_EMAIL"
  ok "git identity $BOT_LOGIN <$BOT_EMAIL>"
}

# 8. Firstmate: clone the fork's main only when absent; never touch existing
# code here (automatic updates happen at first-mate start, lib/firstmate.sh).
# Starting config and data files are copied only where absent.
step_firstmate() {
  local f name
  if [ ! -e "$FM_HOME" ] || { [ -d "$FM_HOME" ] && [ -z "$(ls -A "$FM_HOME")" ]; }; then
    log "cloning Firstmate ($FIRSTMATE_REPO) into $FM_HOME"
    mkdir -p "$(dirname "$FM_HOME")"
    if ! GIT_TERMINAL_PROMPT=0 git clone --quiet "$FIRSTMATE_REPO" "$FM_HOME"; then
      # Keep going: a failed clone should not tear down the whole sandbox.
      # `devenv check` and `devenv entry` report the missing home.
      warn "could not clone Firstmate from $FIRSTMATE_REPO (GitHub access?). Fix it, then re-run: $DEVENV_ROOT/provision.sh"
      return 0
    fi
    ok "Firstmate cloned at $(git -C "$FM_HOME" rev-parse --short HEAD) (fork main)"
  elif [ -d "$FM_HOME/.git" ]; then
    ok "Firstmate present in $FM_HOME (left as is)"
  else
    warn "$FM_HOME exists but is not a git clone; leaving it alone"
  fi
  mkdir -p "$FM_HOME/config"
  for f in "$DEVENV_ROOT"/firstmate/config/*; do
    [ -f "$f" ] || continue
    name=${f##*/}
    if [ ! -e "$FM_HOME/config/$name" ]; then
      cp "$f" "$FM_HOME/config/$name"
      ok "Firstmate config/$name set to $(tr -d '[:space:]' < "$f")"
    fi
  done
  mkdir -p "$FM_HOME/data"
  for f in "$DEVENV_ROOT"/firstmate/data/*; do
    [ -f "$f" ] || continue
    name=${f##*/}
    if [ ! -e "$FM_HOME/data/$name" ]; then
      cp "$f" "$FM_HOME/data/$name"
      ok "Firstmate data/$name seeded"
    fi
  done
}

summary() {
  local t
  echo
  echo "devenv provisioned ($MODE mode)"
  printf '  %-22s %s\n' "devenv checkout" "$DEVENV_ROOT" "workspace" "$WORKSPACE" "Firstmate home" "$FM_HOME" \
    "state" "$DEVENV_STATE_DIR"
  for t in "${DEVENV_BINARIES[@]}"; do printf '  %-22s %s\n' "$t" "$(bin_installed_version "$t")"; done
  for t in "${DEVENV_NPM_PACKAGES[@]}"; do printf '  %-22s %s\n' "$t" "$(npm_installed_version "$t")"; done
  printf '  %-22s %s\n' node "$(node_installed_version)"
  if have claude; then printf '  %-22s %s\n' claude "$(claude --version 2>/dev/null | extract_version)"; fi
}

# ------------------------------------------------------------------ main

# sbx install runs as root: do the system steps, then the rest as the agent
# user (uid 1000) with its own HOME.
if [ "$MODE" = sbx ] && [ "$(id -u)" -eq 0 ] && [ "$PHASE" != user ]; then
  user=${DEVENV_USER:-$(id -nu 1000)}
  home=$(getent passwd "$user" | cut -d: -f6)
  HOME=$home resolve_paths sbx
  step_packages
  HOME=$home step_env_block
  step_entry_shim
  preserve=$(IFS=,; echo "${DEVENV_PASSTHROUGH_ENV[*]}")
  log "continuing as $user"
  exec sudo -u "$user" -H --preserve-env="$preserve" \
    bash "$DEVENV_ROOT/provision.sh" --sbx --yes --git-identity "$GIT_IDENTITY" --phase user
fi

resolve_paths "$MODE"
export PATH="$LOCAL_BIN:$PATH"
if [ "$PHASE" != user ]; then
  step_packages
fi
step_node
step_binaries
step_npm
step_claude_code
if [ "$PHASE" != user ]; then
  step_env_block
  step_entry_shim
else
  export DEVENV_DIR=$DEVENV_ROOT FM_HOME FM_PROJECTS_OVERRIDE=$FM_PROJECTS_DIR DEVENV_STATE_DIR
  PATH="$DEVENV_ROOT/bin:$PATH"
fi
step_git_identity
step_firstmate
install_herdr_config && ok "herdr config and Claude detection override in place"
apply_claude_config with-integrations && ok "Claude settings, status line and CLAUDE.md applied"
link_skills
link_claude_memory && ok "Claude memory linked to $DEVENV_STATE_DIR/claude-memory"
summary
echo
cmd_check
