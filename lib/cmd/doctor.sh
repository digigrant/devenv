# shellcheck shell=bash
# The report helpers (_pass/_wrn/_fail) always succeed, so `test && _pass || _fail`
# is a safe if/else here.
# shellcheck disable=SC2015
# devenv doctor [--host|--env]: full health report (spec §6.12).
# On the host it checks the sbx prerequisites and the operating rules; in the
# sandbox (or plain mode) it checks the installed environment. Exits 1 when
# any check fails.

_DOC_FAILS=0
_DOC_WARNS=0
_pass() { printf '  %sok%s    %s\n' "$_c_grn" "$_c_off" "$*"; }
_wrn()  { printf '  %swarn%s  %s\n' "$_c_yel" "$_c_off" "$*"; _DOC_WARNS=$((_DOC_WARNS + 1)); }
_fail() { printf '  %sFAIL%s  %s\n' "$_c_red" "$_c_off" "$*"; _DOC_FAILS=$((_DOC_FAILS + 1)); }
_info() { printf '  %s\n' "$*"; }

DEVENV_OPERATING_RULE='Treat ~/dev as belonging to the sandbox: never run git, scripts or build tools in it from the host, because agents can plant git hooks or scripts there.'

# Where is this running? host (sbx available, not a sandbox), sbx, or plain.
doctor_location() {
  if [ "$(detect_mode)" = sbx ]; then echo sbx
  elif have sbx; then echo host
  else echo plain; fi
}

# true when path A is B or inside B (both resolved).
path_within() {
  local a b
  a=$(readlink -m "$1"); b=$(readlink -m "$2")
  case "$a/" in "$b"/*) return 0 ;; esac
  return 1
}

# Workspaces the host's sandboxes mount, as reported by `sbx ls --json`
# (best effort: the schema is not documented), plus the one sbxenv.yaml uses.
# DEVENV_EXTRA_WORKSPACES (colon-separated) adds more, e.g. to test the check.
host_workspaces() {
  local extra
  printf '%s\n' "$(dirname "$DEVENV_REAL")/dev" "$HOME/dev"
  if [ -n "${DEVENV_EXTRA_WORKSPACES:-}" ]; then
    IFS=: read -r -a extra <<<"$DEVENV_EXTRA_WORKSPACES"
    printf '%s\n' "${extra[@]}"
  fi
  if have jq; then
    sbx ls --json 2>/dev/null | jq -r '.. | objects | (.workspace, .workspaces, .workspaceDir, .workspace_dir, .mounts)? // empty
      | if type == "array" then .[] else . end | if type == "object" then (.path // .source // empty) else . end
      | strings' 2>/dev/null || true
  fi
}

doctor_host() {
  local v json state f mode owner ws dirty branch behind
  DEVENV_REAL=$(readlink -f "$DEVENV_ROOT")
  echo "sbx"
  if ! have sbx; then
    _fail "sbx is not installed (see README: Host prerequisites)"
  else
    json=$(sbx version --json 2>/dev/null || true)
    v=$(printf '%s' "$json" | jq -r '.client.version // .version // empty' 2>/dev/null | extract_version || true)
    [ -n "$v" ] || v=$(sbx version 2>/dev/null | extract_version || true)
    if [ -z "$v" ]; then _wrn "could not read the sbx version"
    elif version_ge "$v" 0.45.0; then _pass "sbx $v"
    else _wrn "sbx $v is older than 0.45 (devenv was built against 0.45.1)"; fi
    state=$(printf '%s' "$json" | jq -r '.server.state // empty' 2>/dev/null || true)
    [ -z "$state" ] || [ "$state" = running ] && _pass "sbx daemon ${state:-reachable}" || _wrn "sbx daemon is $state (sbx daemon restart)"
    if sbx ls >/dev/null 2>&1; then _pass "sbx answers (logged in)"; else _fail "sbx ls failed; run: sbx login"; fi
    if [ -n "$(sbx policy ls 2>/dev/null | sed '1d' | grep -v '^\s*$' || true)" ]; then _pass "network policy is set up"
    else _fail "no network policy; run: sbx policy init balanced"; fi
  fi
  if [ -r /dev/kvm ] && [ -w /dev/kvm ]; then _pass "/dev/kvm is accessible"; else _fail "/dev/kvm is not accessible"; fi
  if id -nG | tr ' ' '\n' | grep -qx kvm; then _pass "user is in the kvm group"; else _wrn "user is not in the kvm group (sudo usermod -aG kvm \$USER, then log in again)"; fi
  if grep -qi microsoft /proc/version 2>/dev/null; then
    _info "note: this is WSL. Docker supports the Linux sbx inside WSL only \"best-effort\" (docker/sbx-releases#397)."
  fi

  echo "secrets"
  [ "$(stat -c %a "$HOME/.config/devenv/secrets" 2>/dev/null)" = 700 ] \
    || _wrn "~/.config/devenv/secrets should be mode 700 (install -d -m 700 ~/.config/devenv/secrets)"
  for f in anthropic github; do
    f="$HOME/.config/devenv/secrets/$f"
    if [ ! -f "$f" ]; then _fail "$f is missing"; continue; fi
    mode=$(stat -c %a "$f"); owner=$(stat -c %U "$f")
    if [ "$mode" != 600 ]; then _fail "$f is mode $mode; run: chmod 600 $f"
    elif [ "$owner" != "$(id -un)" ]; then _fail "$f is owned by $owner"
    elif [ ! -s "$f" ]; then _fail "$f is empty"
    else _pass "$f (0600)"; fi
  done
  if [ -z "$ANTHROPIC_TOKEN_EXPIRES" ]; then _wrn "ANTHROPIC_TOKEN_EXPIRES is not set in devenv.conf (expiry unknown)"
  elif [ "$(days_until "$ANTHROPIC_TOKEN_EXPIRES" 2>/dev/null || echo -1)" -lt 0 ]; then _fail "anthropic token expired ($ANTHROPIC_TOKEN_EXPIRES)"
  else _pass "anthropic token valid until $ANTHROPIC_TOKEN_EXPIRES"; fi

  echo "devenv checkout ($DEVENV_REAL)"
  local inside=0
  while IFS= read -r ws; do
    [ -n "$ws" ] || continue
    if path_within "$DEVENV_REAL" "$ws" || path_within "$ws" "$DEVENV_REAL"; then
      _fail "the devenv checkout overlaps a sandbox workspace ($ws); move it outside, e.g. ~/devenv"
      inside=1
    fi
  done < <(host_workspaces | sort -u)
  [ "$inside" = 0 ] && _pass "not inside any sandbox workspace"
  if git -C "$DEVENV_REAL" rev-parse --git-dir >/dev/null 2>&1; then
    dirty=$(git -C "$DEVENV_REAL" status --porcelain 2>/dev/null)
    [ -z "$dirty" ] && _pass "checkout is clean" || _wrn "checkout has local changes (changes should arrive by PR)"
    branch=$(git -C "$DEVENV_REAL" symbolic-ref --short -q HEAD || echo detached)
    [ "$branch" = main ] && _pass "on main" || _wrn "on $branch, not main"
    if timeout 15 git -C "$DEVENV_REAL" fetch -q origin main 2>/dev/null; then
      behind=$(git -C "$DEVENV_REAL" rev-list --count HEAD..origin/main 2>/dev/null || echo 0)
      [ "$behind" = 0 ] && _pass "up to date with origin/main" || _wrn "$behind commits behind origin/main; run: git -C ~/devenv pull"
    else
      _wrn "could not fetch origin/main"
    fi
  else
    _wrn "not a git checkout"
  fi
  echo
  echo "Operating rule: $DEVENV_OPERATING_RULE"
}

doctor_env() {
  local where=$1 t pin cur login out src
  resolve_paths "$where"
  export PATH="$LOCAL_BIN:$DEVENV_ROOT/bin:$PATH"
  echo "tools"
  for t in "${DEVENV_BINARIES[@]}"; do
    pin=$(bin_pin "$t"); cur=$(bin_installed_version "$t")
    [ "$cur" = "$pin" ] && _pass "$t $cur" || _fail "$t ${cur:-missing} (pinned $pin)"
  done
  for t in "${DEVENV_NPM_PACKAGES[@]}"; do
    pin=$(npm_pin "$t"); cur=$(npm_installed_version "$t")
    [ "$cur" = "$pin" ] && _pass "$t $cur" || _fail "$t ${cur:-missing} (pinned $pin)"
  done
  cur=$(node_installed_version)
  [ -n "$cur" ] && version_ge "$cur" "$NODE_MIN_VERSION" && _pass "node $cur" || _fail "node ${cur:-missing} (need >= $NODE_MIN_VERSION)"
  if have tmux; then _wrn "tmux is installed (devenv never installs it; Firstmate should use herdr)"; else _pass "tmux not installed"; fi
  have claude && _pass "claude $(claude --version 2>/dev/null | extract_version)" || _fail "claude not installed"

  echo "accounts"
  login=$(timeout 10 gh api user --jq .login 2>/dev/null || true)
  if [ "$login" = "$BOT_LOGIN" ]; then _pass "GitHub acts as $login"
  elif [ -n "$login" ]; then [ "$where" = sbx ] && _fail "GitHub acts as $login, expected $BOT_LOGIN" || _wrn "GitHub acts as $login (the sandbox uses $BOT_LOGIN)"
  else _fail "gh api user failed"; fi
  if timeout 10 gh auth status >/dev/null 2>&1; then _pass "gh auth status passes"
  else _fail "gh auth status fails (Firstmate bootstrap prints NEEDS_GH_AUTH)"; fi
  if have claude; then
    out=$(timeout 15 claude auth status 2>&1 || true)
    if printf '%s' "$out" | grep -qiE '"loggedIn": *true|logged in'; then _pass "Claude is logged in"
    else _wrn "Claude login unclear: $(printf '%s' "$out" | head -n 1)"; fi
  fi
  if [ "$where" = sbx ]; then
    [ "${SBX_CRED_ANTHROPIC_MODE:-}" = oauth ] && _pass "SBX_CRED_ANTHROPIC_MODE=oauth" \
      || _wrn "SBX_CRED_ANTHROPIC_MODE=${SBX_CRED_ANTHROPIC_MODE:-unset} (expected oauth with the setup-token secret; V1)"
  fi

  echo "herdr and Firstmate"
  if herdr_server_running; then
    _pass "herdr server responds"
    src=$(herdr_claude_manifest_source)
    case "$src" in "local override"*) _pass "herdr Claude detection: $src" ;; *) _wrn "herdr Claude detection: ${src:-unknown} (expected devenv's local override)" ;; esac
  else
    _wrn "herdr server is not running (devenv entry starts it)"
  fi
  if [ -d "$FM_HOME/.git" ]; then
    _pass "Firstmate home $FM_HOME"
    out=$(cd "$FM_HOME" && FM_HOME=$FM_HOME FM_BOOTSTRAP_DETECT_ONLY=1 timeout 120 bash bin/fm-bootstrap.sh 2>&1 || true)
    if [ -z "$out" ]; then _pass "Firstmate bootstrap reports nothing missing"
    else
      while IFS= read -r t; do
        case "$t" in
          MISSING*|NEEDS_GH_AUTH*|BACKEND_INVALID*) _fail "bootstrap: $t" ;;
          *) _info "bootstrap: $t" ;;
        esac
      done <<<"$out"
    fi
  else
    _fail "Firstmate home $FM_HOME is missing"
  fi

  echo "Claude settings"
  out=$(claude_config_problems)
  if [ -z "$out" ]; then _pass "overlay applied, status line sha256 matches"
  else while IFS= read -r t; do _fail "$t"; done <<<"$out"; fi

  echo "devenv check"
  cmd_check
}

cmd_doctor() {
  local where
  case "${1:-}" in
    --host) where=host ;;
    --env) where=$(detect_mode) ;;
    '') where=$(doctor_location) ;;
    *) die "usage: devenv doctor [--host|--env]" ;;
  esac
  echo "devenv doctor ($where)"
  if [ "$where" = host ]; then doctor_host; else doctor_env "$where"; fi
  echo
  if [ "$_DOC_FAILS" -gt 0 ]; then
    printf '%s%d failed, %d warnings%s\n' "$_c_red" "$_DOC_FAILS" "$_DOC_WARNS" "$_c_off"
    return 1
  fi
  printf '%sall checks passed%s (%d warnings)\n' "$_c_grn" "$_c_off" "$_DOC_WARNS"
}
