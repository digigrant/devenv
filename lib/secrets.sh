# shellcheck shell=bash
# Secrets from Infisical (docs/SECRETS.md). Host only.
#
# Secret zero lives in the Secret Service: three `secret-tool` entries with the
# attributes `service devenv-infisical key <k>` (k = project-id, client-id,
# client-secret). `devenv secret-get NAME`, which sbx runs as a command source,
# reads them, logs in to Infisical as the machine identity (Universal Auth),
# reads one secret over the REST API and prints it.
#
# No secret value or identity detail ever appears as a command argument or in a
# file: values stay in shell variables and reach secret-tool, jq and curl on
# stdin only (printf is a builtin, so it has no argv of its own). Nothing here
# may use `set -x` or a here-string (bash can back one with a temporary file).
#
# DEVENV_KEYRING_SERVICE overrides the `service` attribute, so a check can
# simulate missing entries without touching the real ones.

SECRETS_KEYRING_KEYS=(project-id client-id client-secret)
SECRETS_HTTP_TIMEOUT=20

keyring_service() { printf '%s' "${DEVENV_KEYRING_SERVICE:-devenv-infisical}"; }

keyring_label() {
  case "$1" in
    project-id) echo 'devenv Infisical project ID' ;;
    client-id) echo 'devenv Infisical client ID' ;;
    client-secret) echo 'devenv Infisical client secret' ;;
  esac
}

# Commands that sandboxd runs may lack the session bus address (SECRETS.md P3).
# Harmless when it is already set.
keyring_bus_default() {
  if [ -z "${DBUS_SESSION_BUS_ADDRESS:-}" ]; then
    DBUS_SESSION_BUS_ADDRESS="unix:path=${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/bus"
    export DBUS_SESSION_BUS_ADDRESS
  fi
}

# What the keyring checks need, one line per missing tool with its install
# command; nothing when all are there.
keyring_tools_missing() {
  have secret-tool || echo "secret-tool is not installed; run: sudo apt-get install -y libsecret-tools"
  have busctl || echo "busctl is not installed; run: sudo apt-get install -y systemd"
  have jq || echo "jq is not installed; run: sudo apt-get install -y jq"
  return 0
}

# keyring_state KEY: prints unlocked, locked or missing for devenv's entry KEY.
# It asks the Secret Service's SearchItems, which matches attributes without
# loading any secret and never prompts, even when the keyring is locked
# (checked against gnome-keyring: `secret-tool lookup` calls Unlock and opens
# the unlock window, and `secret-tool search` asks for every secret). When no
# Secret Service answers, prints busctl's error and returns 1.
keyring_state() {
  local out
  if ! out=$(timeout 15 busctl --user --timeout=10 --json=short call org.freedesktop.secrets \
               /org/freedesktop/secrets org.freedesktop.Secret.Service SearchItems \
               'a{ss}' 2 service "$(keyring_service)" key "$1" 2>&1 </dev/null); then
    printf '%s\n' "${out:-no answer within 15 seconds}" | grep -m 1 . || true
    return 1
  fi
  printf '%s\n' "$out" | tail -n 1 | jq -r '.data
    | if (.[0] | length) > 0 then "unlocked" elif (.[1] | length) > 0 then "locked" else "missing" end' 2>/dev/null \
    || { echo "an unexpected answer to SearchItems"; return 1; }
}

# "<key> <state>" for each of the three entries; when no Secret Service
# answers, prints why on one line and returns 1. Never prompts.
keyring_states() {
  local k s
  keyring_bus_default
  for k in "${SECRETS_KEYRING_KEYS[@]}"; do
    s=$(keyring_state "$k") || { echo "$s"; return 1; }
    printf '%s %s\n' "$k" "$s"
  done
}

# Prints why the keyring entries can't be read and returns 0, or prints
# nothing and returns 1 when all three can be read. Never prompts.
keyring_problem() {
  local p states missing
  p=$(keyring_tools_missing)
  if [ -n "$p" ]; then printf '%s\n' "$p" | head -n 1; return 0; fi
  if ! states=$(keyring_states); then
    echo "no Secret Service answers ($states); is gnome-keyring running?"; return 0
  fi
  if printf '%s\n' "$states" | grep -q ' locked$'; then
    echo "keyring locked; run sbx env run (host-prepare unlocks it)"; return 0
  fi
  missing=$(printf '%s\n' "$states" | awk '$2 == "missing" { printf "%s%s", sep, $1; sep = " " }')
  if [ -n "$missing" ]; then
    echo "keyring entry missing: $missing (service $(keyring_service)); run: ~/devenv/bin/devenv secrets-init"; return 0
  fi
  return 1
}

# The first locked entry, or nothing.
keyring_locked_key() {
  keyring_states 2>/dev/null | awk '$2 == "locked" { print $1; exit }' || true
}

# When the keyring is locked (after every WSL restart), have the Secret
# Service ask for its password and wait: a `secret-tool lookup` of a locked
# entry makes it open its own unlock window (a pop-up under WSLg or on a
# desktop). The password never passes through this shell, and the looked-up
# value goes to /dev/null. Without a display the window can't open and the
# lookup fails at once. A no-op when the keyring is unlocked or has no devenv
# entries yet (the checks after it report that).
keyring_unlock_if_locked() {
  local k
  [ -z "$(keyring_tools_missing)" ] || return 0
  k=$(keyring_locked_key)
  [ -n "$k" ] || return 0
  log "the keyring is locked (as after every restart): a window asks for the keyring password now"
  timeout 300 secret-tool lookup service "$(keyring_service)" key "$k" >/dev/null 2>&1 </dev/null || true
  if [ -z "$(keyring_locked_key)" ]; then ok "keyring unlocked"; return 0; fi
  if [ -z "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ]; then
    die "the keyring is locked and no window can ask for its password here (no DISPLAY or WAYLAND_DISPLAY); run sbx env run in a terminal that can open windows (WSLg or a desktop session)"
  fi
  die "the keyring is still locked (the password window was closed or timed out); run sbx env run again"
}

# keyring_read KEY: prints the entry's value. Only after keyring_problem said
# the entries are there and unlocked. The timeout is a backstop: should the
# keyring lock in between, the lookup would open the unlock window.
keyring_read() {
  local v
  v=$(timeout 10 secret-tool lookup service "$(keyring_service)" key "$1" </dev/null 2>/dev/null) || return 1
  [ -n "$v" ] || return 1
  printf '%s' "$v"
}

# keyring_store KEY: stores stdin as the entry's value (replacing it). With no
# keyring yet, the Secret Service first opens a window asking for a new
# keyring password, hence the long timeout.
keyring_store() {
  timeout 300 secret-tool store --label="$(keyring_label "$1")" service "$(keyring_service)" key "$1"
}

# A value for a double-quoted string in a curl config file.
curl_cfg_quote() {
  local s=$1
  s=${s//\\/\\\\}
  s=${s//\"/\\\"}
  printf '"%s"' "$s"
}

# The names secret-get may fetch (a guard against typos).
secret_name_allowed() {
  [ -n "$1" ] && { [ "$1" = "$SECRET_GITHUB" ] || [ "$1" = "$SECRET_CLAUDE" ]; }
}

# infisical_get NAME: prints NAME's value from Infisical, followed by a
# newline (like `cat` of the old secret file). Dies with one line on stderr on
# any failure.
infisical_get() {
  local name=$1 p pid cid csec body resp code token url q
  p=$(keyring_problem) && die "$p"
  pid=$(keyring_read project-id) || die "could not read the keyring entry project-id"
  cid=$(keyring_read client-id) || die "could not read the keyring entry client-id"
  csec=$(keyring_read client-secret) || die "could not read the keyring entry client-secret"
  case "$pid$cid$csec" in *[[:space:]]*) die "a keyring entry holds spaces or line breaks; run devenv secrets-init again" ;; esac
  have jq || die "jq is not installed; run: sudo apt-get install -y jq"
  have curl || die "curl is not installed; run: sudo apt-get install -y curl"
  local base=${INFISICAL_DOMAIN%/}

  # 1. Log in (Universal Auth). The JSON body goes to curl on stdin.
  body=$(printf '%s\n%s\n' "$cid" "$csec" | jq -Rnc '[inputs] | {clientId: .[0], clientSecret: .[1]}') \
    || die "could not build the Infisical login request"
  if ! resp=$(printf '%s' "$body" | curl -sS --max-time "$SECRETS_HTTP_TIMEOUT" -X POST \
                -H 'Content-Type: application/json' --data-binary @- -w '\n%{http_code}' \
                "$base/api/v1/auth/universal-auth/login" 2>/dev/null); then
    die "could not reach $base to log in to Infisical"
  fi
  body='' csec=''
  code=${resp##*$'\n'}
  case "$code" in
    200) ;;
    401|403) die "Infisical rejected the sbx-host login (HTTP $code): a wrong client ID or client secret, a revoked client secret, or a lockout after 3 failed logins (wait 5 minutes, then retry)" ;;
    429) die "Infisical refused the sbx-host login (HTTP 429): too many attempts or a lockout; wait 5 minutes, then retry" ;;
    *) die "the Infisical login failed (HTTP $code)" ;;
  esac
  token=$(printf '%s' "${resp%$'\n'*}" | jq -r '.accessToken // empty' 2>/dev/null) || token=''
  resp=''
  [ -n "$token" ] || die "the Infisical login returned no access token"

  # 2. Read the one secret. URL (it holds the project ID) and Authorization
  # header go to curl as a config file on stdin.
  q=$(printf '%s\n%s\n%s\n%s\n' "$name" "$pid" "$INFISICAL_ENV" "$INFISICAL_PATH" \
      | jq -Rnr '[inputs | @uri] | "\(.[0])?projectId=\(.[1])&environment=\(.[2])&secretPath=\(.[3])&viewSecretValue=true&expandSecretReferences=true&includeImports=true"') \
    || die "could not build the Infisical request"
  url="$base/api/v4/secrets/$q"
  if ! resp=$(printf 'url = %s\nheader = %s\n' "$(curl_cfg_quote "$url")" "$(curl_cfg_quote "Authorization: Bearer $token")" \
                | curl -sS --max-time "$SECRETS_HTTP_TIMEOUT" -w '\n%{http_code}' --config - 2>/dev/null); then
    die "could not reach $base to read $name"
  fi
  token='' url='' q=''
  code=${resp##*$'\n'}
  case "$code" in
    200) ;;
    401) die "Infisical rejected the access token when reading $name (HTTP 401)" ;;
    403) die "sbx-host may not read $name (HTTP 403): add it to the agent project as Viewer" ;;
    404) die "Infisical has no $name in environment $INFISICAL_ENV, path $INFISICAL_PATH of the project (HTTP 404), or the project ID is wrong" ;;
    *) die "reading $name from Infisical failed (HTTP $code)" ;;
  esac
  printf '%s' "${resp%$'\n'*}" | jq -er 'if .secret.secretValueHidden == true then error("hidden")
                                        else .secret.secretValue // error("none") end
                                        | if . == "" then error("empty") else . end' 2>/dev/null \
    || die "Infisical returned no value for $name (hidden from sbx-host, or empty)"
}

# Prints why a fetched value doesn't look like NAME's kind of token and returns
# 0, or prints nothing and returns 1. The value arrives on stdin; the message
# never contains it.
secret_shape_problem() {
  local name=$1 v
  v=$(cat)
  case "$v" in *[[:space:]]*) echo "$name holds spaces or line breaks"; return 0 ;; esac
  case "$name" in
    "$SECRET_GITHUB")
      case "$v" in ghp_*|github_pat_*) return 1 ;; esac
      echo "$name does not look like a GitHub token (ghp_… or github_pat_…)"; return 0 ;;
    "$SECRET_CLAUDE")
      case "$v" in
        sk-ant-oat01-*) return 1 ;;
        sk-ant-api*) echo "$name holds a Console API key, not a \`claude setup-token\` token (sk-ant-oat01-…)"; return 0 ;;
      esac
      echo "$name does not look like a \`claude setup-token\` token (sk-ant-oat01-…)"; return 0 ;;
  esac
  return 1
}

# The known prefix of the value on stdin, for messages: only that constant,
# never more of the value.
secret_shape_label() {
  case "$(head -c 13)" in
    github_pat_*) echo 'github_pat_…' ;;
    ghp_*) echo 'ghp_…' ;;
    sk-ant-oat01-) echo 'sk-ant-oat01-…' ;;
    *) echo 'unknown shape' ;;
  esac
}

# Ask GitHub which account a token authenticates as. The token arrives on
# stdin and goes to curl as a header on stdin, never on a command line or in a
# file. The expiry header is looked for in every header block (a proxy may
# add its own first). Prints "<http-code>\t<login>\t<expiry>" ("-" when unknown).
github_token_whoami() {
  local tok resp code login exp
  tok=$(tr -d '\r\n')
  resp=$(printf 'Authorization: token %s\n' "$tok" \
         | curl -sS -m 10 -H @- -D - -w '\n%{http_code}' https://api.github.com/user 2>/dev/null) || resp=$'\n000'
  tok=''
  code=${resp##*$'\n'}
  login=$(printf '%s\n' "${resp%$'\n'*}" | sed -n 's/^ *"login": *"\([^"]*\)".*/\1/p' | head -n 1)
  exp=$(printf '%s\n' "$resp" | tr -d '\r' | sed -n 's/^[Gg]ithub-[Aa]uthentication-[Tt]oken-[Ee]xpiration: *//p' | tail -n 1)
  printf '%s\t%s\t%s\n' "${code:-000}" "${login:--}" "${exp:--}"
}

# secret_fetch_or_error NAME: sets SECRET_VALUE and returns 0, or sets
# SECRET_ERROR (one line, without devenv's prefix) and returns 1. One login
# per call. Success prints nothing on stderr, and failure prints nothing on
# stdout, so one capture of both tells them apart.
secret_fetch_or_error() {
  local out
  SECRET_VALUE='' SECRET_ERROR=''
  if out=$(infisical_get "$1" 2>&1); then SECRET_VALUE=$out; return 0; fi
  SECRET_ERROR=$(printf '%s\n' "$out" | tail -n 1 | sed 's/^.*devenv: error:[^ ]* //')
  return 1
}

# Problems with the keyring and the two secrets, one per line, for doctor and
# host-prepare; nothing but "ok: …" lines when all is well. Network trouble is
# reported with a "warn: " prefix. Values stay in variables, never printed.
secrets_problems() {
  local p code login exp tp
  if p=$(keyring_problem); then echo "$p"; return 0; fi
  echo "ok: keyring entries present (service $(keyring_service): ${SECRETS_KEYRING_KEYS[*]})"
  # One login per fetch. After a failed fetch, don't try the second: 3 failed
  # logins lock sbx-host for 5 minutes.
  if ! secret_fetch_or_error "$SECRET_GITHUB"; then
    echo "fetching $SECRET_GITHUB failed: $SECRET_ERROR"
    return 0
  elif tp=$(printf '%s' "$SECRET_VALUE" | secret_shape_problem "$SECRET_GITHUB"); then
    echo "$tp"
  else
    IFS=$'\t' read -r code login exp < <(printf '%s' "$SECRET_VALUE" | github_token_whoami)
    case "$code" in
      200) if [ "$login" = "$BOT_LOGIN" ]; then
             echo "ok: $SECRET_GITHUB authenticates as $login (HTTP 200; expires ${exp/#-/unknown})"
           else echo "$SECRET_GITHUB authenticates as $login, not $BOT_LOGIN"; fi ;;
      401) echo "GitHub rejects $SECRET_GITHUB (HTTP 401): the token is wrong, revoked or expired; replace it in Infisical" ;;
      000) echo "warn: could not reach api.github.com to check $SECRET_GITHUB" ;;
      *)   echo "warn: api.github.com answered HTTP $code when checking $SECRET_GITHUB" ;;
    esac
  fi
  if [ "$CLAUDE_AUTH" = token ]; then
    if ! secret_fetch_or_error "$SECRET_CLAUDE"; then
      echo "fetching $SECRET_CLAUDE failed: $SECRET_ERROR"
    elif tp=$(printf '%s' "$SECRET_VALUE" | secret_shape_problem "$SECRET_CLAUDE"); then
      echo "$tp"
    else
      echo "ok: $SECRET_CLAUDE is a setup-token (sk-ant-oat01-…)"
    fi
  fi
  SECRET_VALUE=''
  return 0
}

# Leftovers the cleanup (SECRETS.md S13) removes, one warning per line.
secrets_leftovers() {
  local d=$HOME/.config/devenv/secrets b=$HOME/.infisical/secrets-backup
  [ -e "$d" ] && echo "plain-text secret files left over in $d; delete them (docs/SECRETS.md S13)"
  if [ -d "$b" ] && [ -n "$(ls -A "$b" 2>/dev/null)" ]; then
    echo "Infisical CLI backups left over in $b; delete them and run infisical logout (docs/SECRETS.md S13)"
  fi
  return 0
}

# devenv secret-get NAME: what sbx runs. The value on stdout and nothing else.
cmd_secret_get() {
  [ $# -eq 1 ] || die "usage: devenv secret-get NAME"
  [ "$(detect_mode)" = sbx ] && die "secret-get runs on the host, not inside a sandbox"
  secret_name_allowed "$1" || die "secret-get fetches only $SECRET_GITHUB and $SECRET_CLAUDE (devenv.conf), not '$1'"
  local v
  v=$(infisical_get "$1") || exit 1
  printf '%s\n' "$v"
}
