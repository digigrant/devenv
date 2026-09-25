# shellcheck shell=bash
# devenv check [--quiet]: staleness warnings (spec §6.7).
#
# Writes one warning per line to ~/.cache/devenv/warnings (an empty file when
# all is well); without --quiet it also prints them. Always exits 0: warnings
# are advice, not failures. Network checks time out after 5 seconds.

_CHECK_WARNINGS=()
_CHECK_NOTES=()
_check_warn() { _CHECK_WARNINGS+=("$*"); }
_check_note() { _CHECK_NOTES+=("$*"); }

# Whole days from now until DATE (negative when past).
days_until() {
  local t
  t=$(date -d "$1" +%s 2>/dev/null) || return 1
  echo $(( (t - $(date +%s)) / 86400 ))
}

check_firstmate_pin() {
  local head pin=$FIRSTMATE_COMMIT n
  if [ ! -d "$FM_HOME/.git" ]; then
    _check_warn "firstmate home missing ($FM_HOME) — run provision.sh"
    return
  fi
  head=$(git -C "$FM_HOME" rev-parse HEAD 2>/dev/null) || { _check_warn "firstmate: cannot read HEAD in $FM_HOME"; return; }
  [ "$head" = "$pin" ] && return
  if ! git -C "$FM_HOME" cat-file -e "$pin^{commit}" 2>/dev/null; then
    _check_warn "firstmate pin ${pin:0:12} is not in the local clone — run: git -C \"\$FM_HOME\" fetch"
  elif git -C "$FM_HOME" merge-base --is-ancestor "$pin" "$head"; then
    n=$(git -C "$FM_HOME" rev-list --count "$pin..$head")
    _check_warn "firstmate $n commits ahead of pin — run: devenv bump firstmate"
  elif git -C "$FM_HOME" merge-base --is-ancestor "$head" "$pin"; then
    n=$(git -C "$FM_HOME" rev-list --count "$head..$pin")
    _check_warn "firstmate $n commits behind pin — update it with /updatefirstmate"
  else
    _check_warn "firstmate diverged from pin"
  fi
}

# Normalize a git remote URL for comparison: no trailing slash or .git.
_repo_url_norm() { local u=${1%/}; printf '%s' "${u%.git}"; }

check_firstmate_origin() {
  local origin
  [ -d "$FM_HOME/.git" ] || return
  origin=$(git -C "$FM_HOME" remote get-url origin 2>/dev/null) || { _check_warn "firstmate clone has no origin remote"; return; }
  if [ "$(_repo_url_norm "$origin")" != "$(_repo_url_norm "$FIRSTMATE_REPO")" ]; then
    _check_warn "firstmate origin is $origin, devenv.conf says $FIRSTMATE_REPO — run: git -C \"\$FM_HOME\" remote set-url origin $FIRSTMATE_REPO"
  fi
}

check_tool_versions() {
  local t pin cur
  for t in "${DEVENV_BINARIES[@]}"; do
    pin=$(bin_pin "$t"); cur=$(bin_installed_version "$t")
    if [ -z "$cur" ]; then _check_warn "$t not installed (pinned $pin) — run provision.sh"
    elif [ "$cur" != "$pin" ]; then _check_warn "$t $cur installed, pinned $pin — run provision.sh"; fi
  done
  for t in "${DEVENV_NPM_PACKAGES[@]}"; do
    pin=$(npm_pin "$t"); cur=$(npm_installed_version "$t")
    if [ -z "$cur" ]; then _check_warn "$t not installed (pinned $pin) — run provision.sh"
    elif [ "$cur" != "$pin" ]; then _check_warn "$t $cur installed, pinned $pin — run provision.sh"; fi
  done
  cur=$(node_installed_version)
  if [ -z "$cur" ]; then _check_warn "node not installed (need >= $NODE_MIN_VERSION)"
  elif ! version_ge "$cur" "$NODE_MIN_VERSION"; then _check_warn "node $cur is older than $NODE_MIN_VERSION"; fi
}

check_herdr_manifest() {
  local installed=$HOME/.config/herdr/agent-detection/claude.toml
  if [ "$HERDR_VERSION" != "$HERDR_CLAUDE_MANIFEST_HERDR" ]; then
    _check_warn "herdr Claude detection override was tested with herdr $HERDR_CLAUDE_MANIFEST_HERDR, pinned herdr is $HERDR_VERSION — run: devenv bump herdr-manifest latest"
  fi
  if [ ! -f "$installed" ] || [ "$(file_sha256 "$installed")" != "$HERDR_CLAUDE_MANIFEST_SHA256" ]; then
    _check_warn "herdr Claude detection override not installed — run: devenv start"
  fi
}

check_github_token() {
  local tok hdr code exp days auth=()
  tok=${GH_TOKEN:-${GITHUB_TOKEN:-}}
  if [ -z "$tok" ] && have gh; then tok=$(timeout 3 gh auth token 2>/dev/null || true); fi
  if [ -z "$tok" ] && [ "$(detect_mode)" != sbx ]; then
    _check_note "github: no token found (gh auth token); expiry not checked"
    return
  fi
  [ -n "$tok" ] && auth=(-H "Authorization: token $tok")
  if ! hdr=$(curl -sS -m 5 -o /dev/null -D - "${auth[@]}" https://api.github.com/user 2>/dev/null); then
    _check_note "github: api.github.com unreachable; expiry not checked"
    return
  fi
  hdr=$(printf '%s' "$hdr" | tr -d '\r')
  code=$(printf '%s\n' "$hdr" | awk 'toupper($1) ~ /^HTTP\// { c = $2 } END { print c }')
  case "$code" in
    200) ;;
    401) _check_warn "github token is invalid (HTTP 401) — replace the github secret on the host"; return ;;
    *) _check_note "github: api.github.com returned HTTP ${code:-?}; expiry not checked"; return ;;
  esac
  exp=$(printf '%s\n' "$hdr" | sed -n 's/^[Gg]ithub-[Aa]uthentication-[Tt]oken-[Ee]xpiration: *//p' | tail -n 1)
  if [ -z "$exp" ]; then _check_note "github token: no expiry"; return; fi
  days=$(days_until "$exp") || { _check_note "github token expiry unreadable: $exp"; return; }
  if [ "$days" -lt 0 ]; then _check_warn "github token expired ($exp)"
  elif [ "$days" -lt "$WARN_DAYS" ]; then _check_warn "github token expires in $days days ($exp)"
  else _check_note "github token expires in $days days ($exp)"; fi
}

check_anthropic_token() {
  local days
  if [ -z "$ANTHROPIC_TOKEN_EXPIRES" ]; then
    # /login refreshes itself; only the setup-token has a fixed expiry.
    [ "$CLAUDE_AUTH" = token ] && _check_note "anthropic setup-token expiry unknown (set ANTHROPIC_TOKEN_EXPIRES in devenv.conf)"
    return 0
  fi
  days=$(days_until "$ANTHROPIC_TOKEN_EXPIRES") || { _check_warn "ANTHROPIC_TOKEN_EXPIRES is not a date: $ANTHROPIC_TOKEN_EXPIRES"; return; }
  if [ "$days" -lt 0 ]; then _check_warn "anthropic token expired ($ANTHROPIC_TOKEN_EXPIRES)"
  elif [ "$days" -lt "$WARN_DAYS" ]; then _check_warn "anthropic token expires in $days days ($ANTHROPIC_TOKEN_EXPIRES)"
  else _check_note "anthropic token expires in $days days"; fi
}

check_firstmate_config() {
  local f name
  [ -d "$FM_HOME" ] || return
  for f in "$DEVENV_ROOT"/firstmate/config/*; do
    [ -f "$f" ] || continue
    name=${f##*/}
    if [ ! -f "$FM_HOME/config/$name" ]; then
      _check_warn "firstmate config/$name is missing (devenv's starting copy: $(tr -d '[:space:]' < "$f"))"
    elif ! cmp -s "$f" "$FM_HOME/config/$name"; then
      _check_warn "firstmate config/$name differs from devenv's starting copy"
    fi
  done
}

cmd_check() {
  local quiet=0 w tmp cache
  [ "${1:-}" = --quiet ] && quiet=1
  [ -n "${WORKSPACE:-}" ] || resolve_paths
  _CHECK_WARNINGS=() _CHECK_NOTES=()
  check_firstmate_pin
  check_firstmate_origin
  check_tool_versions
  check_herdr_manifest
  check_github_token
  check_anthropic_token
  check_firstmate_config
  cache="$DEVENV_CACHE/warnings"
  mkdir -p "$DEVENV_CACHE"
  tmp=$(mktemp "$cache.XXXXXX")
  for w in "${_CHECK_WARNINGS[@]}"; do printf '%s\n' "$w"; done > "$tmp"
  mv -f "$tmp" "$cache"
  rm -f "$cache.refreshing"
  [ "$quiet" = 1 ] && return 0
  for w in "${_CHECK_NOTES[@]}"; do printf '  %s\n' "$w"; done
  if [ ${#_CHECK_WARNINGS[@]} -eq 0 ]; then
    printf '%sdevenv check: no warnings%s\n' "$_c_grn" "$_c_off"
  else
    for w in "${_CHECK_WARNINGS[@]}"; do printf '%s⚠ %s%s\n' "$_c_yel" "$w" "$_c_off"; done
  fi
  return 0
}
