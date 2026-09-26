# shellcheck shell=bash
# Shared helpers for provision.sh and bin/devenv. Sourced, never executed.
# The caller sets DEVENV_ROOT (the devenv checkout) before sourcing.

: "${DEVENV_ROOT:?DEVENV_ROOT must be set before sourcing lib/common.sh}"

DEVENV_BLOCK_BEGIN='# >>> devenv >>>'
DEVENV_BLOCK_END='# <<< devenv <<<'

# Environment variables that pass through when provision.sh drops from root to
# the agent user, so downloads keep working behind the sandbox proxy.
DEVENV_PASSTHROUGH_ENV=(
  WORKSPACE_DIR IS_SANDBOX SANDBOX_NAME DEVENV_DIR FM_HOME DEVENV_ENTRY
  DEVENV_ENV_FILE DEVENV_SYSTEM_PREFIX DEVENV_SKIP_CLAUDE_INSTALL NPM_CONFIG_PREFIX
  HTTP_PROXY HTTPS_PROXY NO_PROXY http_proxy https_proxy no_proxy
  NODE_USE_ENV_PROXY NODE_EXTRA_CA_CERTS SSL_CERT_FILE REQUESTS_CA_BUNDLE
  PROXY_CA_CERT_B64 GH_TOKEN SBX_CRED_ANTHROPIC_MODE
)

# ---------------------------------------------------------------- logging
if [ -t 2 ]; then
  _c_dim=$'\033[2m' _c_yel=$'\033[33m' _c_red=$'\033[31m' _c_grn=$'\033[32m' _c_off=$'\033[0m'
else
  _c_dim='' _c_yel='' _c_red='' _c_grn='' _c_off=''
fi
log()  { printf '%sdevenv:%s %s\n' "$_c_dim" "$_c_off" "$*" >&2; }
ok()   { printf '%sdevenv:%s %s✓%s %s\n' "$_c_dim" "$_c_off" "$_c_grn" "$_c_off" "$*" >&2; }
warn() { printf '%sdevenv: warning:%s %s\n' "$_c_yel" "$_c_off" "$*" >&2; }
die()  { printf '%sdevenv: error:%s %s\n' "$_c_red" "$_c_off" "$*" >&2; exit 1; }

have() { command -v "$1" >/dev/null 2>&1; }

# Run a command as root: directly when already root, otherwise through sudo.
as_root() {
  if [ "$(id -u)" -eq 0 ]; then "$@"; else sudo "$@"; fi
}

# ---------------------------------------------------------------- versions
# First x.y.z found on stdin.
extract_version() { grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -n 1; }

# version_ge A B: true when A >= B (dotted numeric versions).
version_ge() {
  [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | head -n 1)" = "$2" ]
}

# ---------------------------------------------------------------- platform
# Suffix used by the *_SHA256_<ARCH> keys in versions.env.
arch_key() {
  case "$(uname -m)" in
    x86_64|amd64) echo X86_64 ;;
    aarch64|arm64) echo AARCH64 ;;
    *) die "unsupported architecture: $(uname -m) (need x86_64 or aarch64)" ;;
  esac
}
# herdr's release asset naming.
arch_herdr() { case "$(arch_key)" in X86_64) echo x86_64 ;; AARCH64) echo aarch64 ;; esac; }
# Go-style naming used by treehouse and no-mistakes.
arch_go() { case "$(arch_key)" in X86_64) echo amd64 ;; AARCH64) echo arm64 ;; esac; }
# Node's naming.
arch_node() { case "$(arch_key)" in X86_64) echo x64 ;; AARCH64) echo arm64 ;; esac; }

# sbx when running inside a Docker Sandbox, plain otherwise.
detect_mode() {
  if [ "${IS_SANDBOX:-}" = 1 ] || [ -n "${SANDBOX_NAME:-}" ]; then echo sbx; else echo plain; fi
}

# ---------------------------------------------------------------- config
# Expand a literal leading ~ or $HOME in a config value.
expand_home() {
  local s=$1
  s=${s//\$\{HOME\}/$HOME}
  s=${s//\$HOME/$HOME}
  case "$s" in "~") s=$HOME ;; "~/"*) s="$HOME/${s#\~/}" ;; esac
  printf '%s' "$s"
}

# Source devenv.conf and versions.env. A few settings can be overridden from
# the environment (for tests and one-off runs), and SANDBOX_NAME keeps its
# runtime value: the configured name is available as CONF_SANDBOX_NAME.
load_config() {
  local k kv saved=() had_sandbox_name=0 runtime_sandbox_name=${SANDBOX_NAME:-}
  local keep=(WARN_DAYS DEVENV_STATUSLINE_WARNINGS ANTHROPIC_TOKEN_EXPIRES CLAUDE_AUTH
              FIRSTMATE_REPO FIRSTMATE_AUTO_UPDATE PLAIN_WORKSPACE_DIR)
  [ -n "${SANDBOX_NAME+x}" ] && had_sandbox_name=1
  for k in "${keep[@]}"; do
    [ -n "${!k+x}" ] && saved+=("$k=${!k}")
  done
  [ -r "$DEVENV_ROOT/devenv.conf" ] || die "missing $DEVENV_ROOT/devenv.conf"
  [ -r "$DEVENV_ROOT/versions.env" ] || die "missing $DEVENV_ROOT/versions.env"
  # shellcheck source=../devenv.conf
  . "$DEVENV_ROOT/devenv.conf"
  # shellcheck source=../versions.env
  . "$DEVENV_ROOT/versions.env"
  CONF_SANDBOX_NAME=$SANDBOX_NAME
  if [ "$had_sandbox_name" = 1 ]; then SANDBOX_NAME=$runtime_sandbox_name; else unset SANDBOX_NAME; fi
  for kv in "${saved[@]}"; do
    printf -v "${kv%%=*}" '%s' "${kv#*=}"
  done
  FM_PROJECTS_DIR_RAW=$FM_PROJECTS_DIR
  FM_PROJECTS_DIR=$(expand_home "$FM_PROJECTS_DIR")
  PLAIN_WORKSPACE_DIR=$(expand_home "$PLAIN_WORKSPACE_DIR")
}

# Resolve the paths devenv works with. Needs load_config first.
#   WORKSPACE        the workspace ($WORKSPACE_DIR in sbx, PLAIN_WORKSPACE_DIR in plain mode)
#   FM_HOME          Firstmate's home (always inside the workspace unless overridden)
#   DEVENV_STATE_DIR persistent state kept in the workspace (Claude memory)
#   DEVENV_CACHE     per-user cache (warnings), DEVENV_CFG per-user config
resolve_paths() {
  local mode=${1:-$(detect_mode)}
  if [ -n "${WORKSPACE_DIR:-}" ]; then
    WORKSPACE=$WORKSPACE_DIR
  elif [ "$mode" = sbx ]; then
    die "WORKSPACE_DIR is not set; is this a Docker Sandbox with a workspace?"
  else
    WORKSPACE=$PLAIN_WORKSPACE_DIR
  fi
  FM_HOME=${FM_HOME:-$WORKSPACE/firstmate}
  DEVENV_STATE_DIR=${DEVENV_STATE_DIR:-$WORKSPACE/.devenv-state}
  DEVENV_CACHE="${XDG_CACHE_HOME:-$HOME/.cache}/devenv"
  DEVENV_CFG="${XDG_CONFIG_HOME:-$HOME/.config}/devenv"
  LOCAL_BIN="$HOME/.local/bin"
}

# ---------------------------------------------------------------- files
# Replace FILE with stdin only when the content differs. Prints "changed" or
# "same". An existing file is overwritten in place, so its owner and mode stay
# as they are (provision.sh runs as root at sandbox create, and
# /etc/sandbox-persistent.sh must stay writable by the agent user). A new file
# gets MODE. Uses sudo when FILE (or its directory) is not writable.
write_if_changed() {
  local file=$1 mode=${2:-0644} tmp dir
  tmp=$(mktemp)
  cat > "$tmp"
  if [ -f "$file" ] && cmp -s "$tmp" "$file"; then
    rm -f "$tmp"; echo same; return 0
  fi
  dir=${file%/*}
  if [ -e "$file" ]; then
    if [ -w "$file" ]; then cat "$tmp" > "$file"
    else as_root sh -c 'cat "$1" > "$2"' sh "$tmp" "$file"; fi
  elif [ -w "$dir" ]; then
    install -m "$mode" "$tmp" "$file"
  else
    as_root install -m "$mode" "$tmp" "$file"
  fi
  rm -f "$tmp"
  echo changed
}

# Insert or replace the devenv-managed block (between the markers) in FILE.
# Everything outside the markers is preserved. Prints "changed" or "same".
write_managed_block() {
  local file=$1 content=$2 mode=0644 current=''
  [ -e "$file" ] && current=$(cat "$file") && mode=$(stat -c %a "$file")
  # The block stays where it is; a file without one gets it appended.
  printf '%s\n' "$current" | DEVENV_BLOCK_CONTENT=$content \
    awk -v b="$DEVENV_BLOCK_BEGIN" -v e="$DEVENV_BLOCK_END" '
      BEGIN { c = ENVIRON["DEVENV_BLOCK_CONTENT"]; inblock = 0; placed = 0 }
      $0 == b { if (!placed) { print b; print c; print e; placed = 1 }; inblock = 1; next }
      inblock && $0 == e { inblock = 0; next }
      inblock { next }
      { print }
      END { if (!placed) { print b; print c; print e } }' \
    | sed -e '/./,$!d' | write_if_changed "$file" "$mode"
}

# ---------------------------------------------------------------- downloads
# fetch_verified URL SHA256 DEST: download to DEST and check its sha256.
# Nothing is left at DEST when the checksum does not match.
fetch_verified() {
  local url=$1 want=$2 dest=$3 got
  [ -n "$want" ] || die "no sha256 pinned for $url"
  curl -fsSL --retry 3 --connect-timeout 20 -o "$dest.part" "$url" || { rm -f "$dest.part"; die "download failed: $url"; }
  got=$(sha256sum "$dest.part" | cut -d' ' -f1)
  if [ "$got" != "$want" ]; then
    rm -f "$dest.part"
    die "sha256 mismatch for $url: expected $want, got $got"
  fi
  mv -f "$dest.part" "$dest"
}

# file_sha256 FILE
file_sha256() { sha256sum "$1" | cut -d' ' -f1; }

# Minutes since FILE was modified (large when it does not exist).
file_age_min() {
  local f=$1 now mt
  [ -e "$f" ] || { echo 999999; return; }
  now=$(date +%s); mt=$(stat -c %Y "$f")
  echo $(( (now - mt) / 60 ))
}
