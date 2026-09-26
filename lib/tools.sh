# shellcheck shell=bash
# Pinned tools: version probes and installers. Needs lib/common.sh,
# load_config and resolve_paths.

DEVENV_BINARIES=(herdr treehouse no-mistakes)
DEVENV_NPM_PACKAGES=(gh-axi chrome-devtools-axi tasks-axi quota-axi)

# NPM_GH_AXI etc. for a package name.
npm_pin_var() { local v=${1//-/_}; printf 'NPM_%s' "${v^^}"; }
npm_pin() { local var; var=$(npm_pin_var "$1"); printf '%s' "${!var:-}"; }

# Pinned version of a binary tool.
bin_pin() {
  case "$1" in
    herdr) echo "$HERDR_VERSION" ;;
    treehouse) echo "$TREEHOUSE_VERSION" ;;
    no-mistakes) echo "$NO_MISTAKES_VERSION" ;;
    *) return 1 ;;
  esac
}

# Installed version of a binary tool, or empty when it is missing.
bin_installed_version() {
  local exe
  exe=$(command -v "$1" 2>/dev/null) || exe="$LOCAL_BIN/$1"
  [ -x "$exe" ] || return 0
  "$exe" --version 2>/dev/null | extract_version || true
}

node_installed_version() {
  have node || return 0
  node --version 2>/dev/null | extract_version || true
}

_npm_root=''
npm_global_root() {
  [ -n "$_npm_root" ] || _npm_root=$(npm root -g 2>/dev/null) || true
  printf '%s' "$_npm_root"
}

# Installed version of a global npm package, or empty.
npm_installed_version() {
  local root pj
  have npm || return 0
  root=$(npm_global_root)
  pj="$root/$1/package.json"
  [ -f "$pj" ] || return 0
  jq -r '.version // empty' "$pj" 2>/dev/null || true
}

# ---------------------------------------------------------------- installers
# Install an executable atomically into LOCAL_BIN.
_install_exe() {
  local src=$1 name=$2
  mkdir -p "$LOCAL_BIN"
  install -m 0755 "$src" "$LOCAL_BIN/.$name.devenv-new"
  mv -f "$LOCAL_BIN/.$name.devenv-new" "$LOCAL_BIN/$name"
}

# install_binary herdr|treehouse|no-mistakes: download, verify, install.
# Skips a tool whose --version already matches the pin.
install_binary() {
  local tool=$1 pin have_v arch sha url asset tmp
  pin=$(bin_pin "$tool")
  have_v=$(bin_installed_version "$tool")
  if [ "$have_v" = "$pin" ]; then
    ok "$tool $pin (already installed)"
    return 0
  fi
  arch=$(arch_key)
  tmp=$(mktemp -d)
  case "$tool" in
    herdr)
      sha=HERDR_SHA256_$arch
      asset="herdr-linux-$(arch_herdr)"
      url="https://github.com/herdrdev/herdr/releases/download/v$pin/$asset"
      fetch_verified "$url" "${!sha}" "$tmp/$tool"
      ;;
    treehouse|no-mistakes)
      local key=${tool//-/_}
      sha="${key^^}_SHA256_$arch"
      asset="$tool-v$pin-linux-$(arch_go).tar.gz"
      url="https://github.com/kunchenguid/$tool/releases/download/v$pin/$asset"
      fetch_verified "$url" "${!sha}" "$tmp/$asset"
      tar -xzf "$tmp/$asset" -C "$tmp" "$tool"
      ;;
  esac
  _install_exe "$tmp/$tool" "$tool"
  rm -rf "$tmp"
  ok "$tool $pin installed${have_v:+ (was $have_v)}"
}

# Install Node from the pinned nodejs.org tarball into ~/.local/opt and link
# node/npm/npx into LOCAL_BIN. Plain mode only.
install_node() {
  local arch sha name url tmp dest
  arch=$(arch_node)
  sha="NODE_SHA256_$(arch_key)"
  name="node-v$NODE_VERSION-linux-$arch"
  url="https://nodejs.org/dist/v$NODE_VERSION/$name.tar.gz"
  dest="$HOME/.local/opt/$name"
  if [ ! -x "$dest/bin/node" ]; then
    tmp=$(mktemp -d)
    fetch_verified "$url" "${!sha}" "$tmp/$name.tar.gz"
    mkdir -p "$HOME/.local/opt"
    tar -xzf "$tmp/$name.tar.gz" -C "$tmp"
    rm -rf "$dest.devenv-new"
    mv "$tmp/$name" "$dest.devenv-new"
    mv "$dest.devenv-new" "$dest"
    rm -rf "$tmp"
  fi
  mkdir -p "$LOCAL_BIN"
  local b
  for b in node npm npx; do
    ln -sfn "$dest/bin/$b" "$LOCAL_BIN/$b"
  done
  hash -r
  ok "node $NODE_VERSION installed in $dest"
}

# Install the pinned npm globals that are missing or at another version.
install_npm_globals() {
  local pkg pin cur specs=()
  for pkg in "${DEVENV_NPM_PACKAGES[@]}"; do
    pin=$(npm_pin "$pkg")
    cur=$(npm_installed_version "$pkg")
    if [ "$cur" = "$pin" ]; then
      ok "$pkg $pin (already installed)"
    else
      specs+=("$pkg@$pin")
    fi
  done
  [ ${#specs[@]} -eq 0 ] && return 0
  log "npm install -g ${specs[*]}"
  npm install -g --no-fund --no-audit --loglevel=error "${specs[@]}" >&2
  _npm_root=''
  ok "npm globals installed: ${specs[*]}"
}

# Run the tools' own Claude integration commands. Each is idempotent (V8):
# gh-axi and chrome-devtools-axi add a SessionStart hook to
# ~/.claude/settings.json (and write ~/.codex/, ~/.config/opencode/); herdr
# writes ~/.claude/hooks/herdr-agent-state.sh and a SessionStart hook.
run_integrations() {
  local out
  if have herdr; then
    out=$(timeout 20 herdr integration install claude 2>&1) || warn "herdr integration install claude failed: $out"
  fi
  if have gh-axi; then
    out=$(timeout 20 gh-axi setup hooks 2>&1) || warn "gh-axi setup hooks failed: $out"
  fi
  if have chrome-devtools-axi; then
    out=$(timeout 20 chrome-devtools-axi setup hooks 2>&1) || warn "chrome-devtools-axi setup hooks failed: $out"
  fi
  return 0
}
