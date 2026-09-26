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

# The operating rule for the host (D28), about the workspace folder dev/ inside
# the checkout. Needs DEVENV_REAL.
operating_rule() {
  printf '%s\n' "Treat $DEVENV_REAL/dev as belonging to the sandbox: never run git, scripts or build tools in it from the host, don't cd into it with a git-aware shell prompt or open it in an editor (agents can plant git hooks, git config or scripts there), and never run \`git clean -x\` in $DEVENV_REAL (it would delete the workspace)."
}

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
# (best effort: the schema is not documented), plus ~/dev (the usual sbx
# workspace, e.g. the old claude-dev sandbox's). DEVENV_EXTRA_WORKSPACES
# (colon-separated) adds more, e.g. to test the check.
host_workspaces() {
  local extra
  printf '%s\n' "$HOME/dev"
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

# Problems with where the checkout sits, one per line; nothing when it is
# right. The checkout's own dev/ is the sandbox workspace by design (Docker's
# layout: sbxenv.yaml beside the workspace). Any other workspace must neither
# contain the checkout nor lie inside it, so the sandbox can never write to the
# code the host runs. Needs DEVENV_REAL.
checkout_overlap_problems() {
  local ws own
  own=$(readlink -m "$DEVENV_REAL/dev")
  while IFS= read -r ws; do
    [ -n "$ws" ] || continue
    [ "$(readlink -m "$ws")" = "$own" ] && continue
    if path_within "$DEVENV_REAL" "$ws"; then
      echo "the devenv checkout ($DEVENV_REAL) is inside a sandbox workspace ($ws); keep it outside, e.g. ~/devenv"
    elif path_within "$ws" "$DEVENV_REAL"; then
      echo "a sandbox workspace ($ws) is inside the devenv checkout; only $DEVENV_REAL/dev may be"
    fi
  done < <(host_workspaces | sort -u)
  return 0
}

# Ask GitHub which account the github secret file authenticates as. The token
# goes to curl through a private header file, never on a command line.
# Prints "<http-code>\t<login>\t<expiry>" ("-" when unknown).
github_secret_whoami() {
  local f=$1 tmp code login exp
  tmp=$(mktemp -d)
  chmod 700 "$tmp"
  printf 'Authorization: token %s\n' "$(tr -d '\r\n' < "$f")" > "$tmp/h"
  code=$(curl -sS -m 10 -H @"$tmp/h" -D "$tmp/hdr" -o "$tmp/body" -w '%{http_code}' https://api.github.com/user 2>/dev/null) || code=000
  login=$(sed -n 's/^ *"login": *"\([^"]*\)".*/\1/p' "$tmp/body" 2>/dev/null | head -n 1)
  exp=$(tr -d '\r' < "$tmp/hdr" 2>/dev/null | sed -n 's/^[Gg]ithub-[Aa]uthentication-[Tt]oken-[Ee]xpiration: *//p' | tail -n 1)
  rm -rf "$tmp"
  printf '%s\t%s\t%s\n' "${code:-000}" "${login:--}" "${exp:--}"
}

# Prints why a Claude setup-token file is unusable and returns 0, or prints
# nothing and returns 1 when it looks right. Never prints the token.
claude_token_file_problem() {
  local f=$1
  if [ ! -s "$f" ]; then echo "$f is empty"; return 0; fi
  if [ "$(wc -l < "$f")" -gt 1 ] || tr -d '\n' < "$f" | grep -q '[[:space:]]'; then
    echo "$f must hold just the token on one line (it has extra lines, spaces or CR characters)"; return 0
  fi
  case "$(head -c 14 "$f")" in
    sk-ant-oat01-*) return 1 ;;
    sk-ant-api*) echo "$f holds a Console API key, not a \`claude setup-token\` token (sk-ant-oat01-…)"; return 0 ;;
    *) echo "$f does not look like a \`claude setup-token\` token (sk-ant-oat01-…)"; return 0 ;;
  esac
}

# Problems with the github secret file's content or account, one per line.
# Network trouble is reported with a "warn: " prefix instead.
github_secret_problems() {
  local f=$HOME/.config/devenv/secrets/github code login exp
  [ -s "$f" ] || return 0
  if [ "$(wc -l < "$f")" -gt 1 ] || tr -d '\n' < "$f" | grep -q '[[:space:]]'; then
    echo "$f must hold just the token on one line (it has extra lines, spaces or CR characters)"
  fi
  IFS=$'\t' read -r code login exp <<<"$(github_secret_whoami "$f")"
  case "$code" in
    200) [ "$login" = "$BOT_LOGIN" ] || echo "the github secret authenticates as $login, not $BOT_LOGIN" ;;
    401) echo "GitHub rejects the github secret (HTTP 401): the token is wrong, revoked or expired" ;;
    000) echo "warn: could not reach api.github.com to check the github secret" ;;
    *)   echo "warn: api.github.com answered HTTP $code when checking the github secret" ;;
  esac
}

doctor_host() {
  local v json state f mode owner dirty branch behind
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
  local tokf=$HOME/.config/devenv/secrets/anthropic tp
  case "$CLAUDE_AUTH" in
    token)
      if [ ! -f "$tokf" ]; then _fail "$tokf is missing (CLAUDE_AUTH=token needs the \`claude setup-token\` token)"
      elif [ "$(stat -c %a "$tokf")" != 600 ]; then _fail "$tokf is mode $(stat -c %a "$tokf"); run: chmod 600 $tokf"
      elif tp=$(claude_token_file_problem "$tokf"); then _fail "$tp"
      else _pass "$tokf (0600, a setup-token)"; fi
      ;;
    login) [ -e "$tokf" ] && _info "$tokf is not used with CLAUDE_AUTH=login; you can delete it" ;;
    *) _fail "CLAUDE_AUTH in devenv.conf must be token or login" ;;
  esac
  for f in github; do
    f="$HOME/.config/devenv/secrets/$f"
    if [ ! -f "$f" ]; then _fail "$f is missing"; continue; fi
    mode=$(stat -c %a "$f"); owner=$(stat -c %U "$f")
    if [ "$mode" != 600 ]; then _fail "$f is mode $mode; run: chmod 600 $f"
    elif [ "$owner" != "$(id -un)" ]; then _fail "$f is owned by $owner"
    elif [ ! -s "$f" ]; then _fail "$f is empty"
    else _pass "$f (0600)"; fi
  done
  local gp t gh_code gh_login gh_exp
  gp=$(github_secret_problems)
  if [ -z "$gp" ] && [ -s "$HOME/.config/devenv/secrets/github" ]; then
    IFS=$'\t' read -r gh_code gh_login gh_exp <<<"$(github_secret_whoami "$HOME/.config/devenv/secrets/github")"
    _pass "github secret authenticates as $gh_login (HTTP $gh_code; expires ${gh_exp/#-/unknown})"
  fi
  while IFS= read -r t; do
    [ -n "$t" ] || continue
    case "$t" in "warn: "*) _wrn "${t#warn: }" ;; *) _fail "$t" ;; esac
  done <<<"$gp"
  if [ -n "$ANTHROPIC_TOKEN_EXPIRES" ]; then
    if [ "$(days_until "$ANTHROPIC_TOKEN_EXPIRES" 2>/dev/null || echo -1)" -lt 0 ]; then _fail "anthropic token expired ($ANTHROPIC_TOKEN_EXPIRES)"
    else _pass "anthropic token valid until $ANTHROPIC_TOKEN_EXPIRES"; fi
  elif [ "$CLAUDE_AUTH" = token ]; then
    _wrn "ANTHROPIC_TOKEN_EXPIRES is not set in devenv.conf (setup-token expiry unknown)"
  fi

  echo "devenv checkout ($DEVENV_REAL)"
  local overlap
  overlap=$(checkout_overlap_problems)
  if [ -z "$overlap" ]; then _pass "not inside any sandbox workspace; only dev/ is shared with the sandbox"
  else while IFS= read -r t; do _fail "$t"; done <<<"$overlap"; fi
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
  echo "Operating rule: $(operating_rule)"
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
    local method
    method=$(printf '%s' "$out" | sed -n 's/.*"authMethod": *"\([^"]*\)".*/\1/p' | head -n 1)
    if printf '%s' "$out" | grep -qiE '"loggedIn": *true|logged in'; then
      if [ "$CLAUDE_AUTH" = token ] && [ "$method" != oauth_token ]; then
        _wrn "Claude is logged in via ${method:-unknown}, not the setup-token (oauth_token)"
      else
        _pass "Claude is logged in (${method:-unknown})"
      fi
    elif [ "$CLAUDE_AUTH" = token ]; then _fail "Claude is not logged in with the setup-token (CLAUDE_CODE_OAUTH_TOKEN)"
    else _wrn "Claude is not logged in: run /login once in Claude (needed after every rebuild)"; fi
  fi
  if [ "$where" = sbx ]; then
    case "${SBX_CRED_ANTHROPIC_MODE:-none}" in
      apikey) _wrn "SBX_CRED_ANTHROPIC_MODE=apikey: a stored anthropic secret is injected as an API key and outranks the subscription (V1). Unless you meant to use a Console API key, remove it (sbx secret ls) and recreate" ;;
      *) _pass "SBX_CRED_ANTHROPIC_MODE=${SBX_CRED_ANTHROPIC_MODE:-none}" ;;
    esac
    if [ "$CLAUDE_AUTH" = token ]; then
      case "${CLAUDE_CODE_OAUTH_TOKEN:-}" in
        '') _fail "CLAUDE_CODE_OAUTH_TOKEN is not set: the custom secret didn't reach this sandbox (recreate it after devenv host-prepare)" ;;
        sk-ant-*) _fail "CLAUDE_CODE_OAUTH_TOKEN holds a real token inside the sandbox; it should be the sbx placeholder" ;;
        sbx-cs-*) _pass "CLAUDE_CODE_OAUTH_TOKEN is the sbx placeholder (the real token stays on the host)" ;;
        *) _wrn "CLAUDE_CODE_OAUTH_TOKEN is set but does not look like an sbx placeholder" ;;
      esac
    fi
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
