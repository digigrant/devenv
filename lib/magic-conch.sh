# shellcheck shell=bash
# The Magic Conch hub (spec D36, §6.16), as the sandbox and plain mode see it,
# and the probe that `devenv check`, `devenv doctor` and `devenv hub` use. The
# hub itself runs on the host (lib/cmd/hub.sh). Needs lib/common.sh and
# load_config.
#
# The hub has two listeners, each published on the host's 127.0.0.1 only: the
# phone listener (MAGIC_CONCH_PHONE_PORT), which only `tailscale serve` may
# reach, and the session listener (MAGIC_CONCH_SESSION_PORT), which sandboxes
# reach at host.docker.internal once the host's network policy allows
# localhost:<port>.

MC_PROTOCOL=1.0   # the Magic Conch protocol version the probes speak

# Where the hub's listeners are: the host, seen from a sandbox, or this machine.
mc_host() { if [ "$(detect_mode)" = sbx ]; then echo host.docker.internal; else echo 127.0.0.1; fi; }

# mc_probe URL METHOD [HEADER]: call the hub the way a client does (with the
# protocol header, and no key) and print what answers, one line:
#   hub <status> <code>  the hub itself (its answers carry the
#                        Magic-Conch-Protocol header), with its error code
#   blocked <reason>     a sandbox's proxy: the network policy denies the port
#   down <reason>        nothing listens there
#   other <status>       something else
# From a sandbox the call goes through the proxy, which answers a port the
# policy denies with 403 and the reason, and an allowed port where nothing
# listens with a 5xx and "connection refused".
mc_probe() {
  local url=$1 method=$2 out code rest head body args
  args=(-sS -m "${DEVENV_HUB_PROBE_TIMEOUT:-5}" -X "$method" -H "Magic-Conch-Protocol: $MC_PROTOCOL" -D - -w '\n%{http_code}')
  [ -z "${3:-}" ] || args+=(-H "$3")
  out=$(curl "${args[@]}" "$url" 2>/dev/null </dev/null) || true
  code=${out##*$'\n'} rest=${out%$'\n'*}
  [ "$rest" != "$out" ] || rest=''
  case "$code" in ''|000) echo "down nothing answers"; return 0 ;; esac
  head=$(printf '%s\n' "$rest" | tr -d '\r' | sed '/^$/q')
  body=$(printf '%s\n' "$rest" | tr -d '\r' | sed '1,/^$/d')
  if printf '%s\n' "$head" | grep -qi '^magic-conch-protocol:'; then
    echo "hub $code $(printf '%s' "$body" | jq -r '.error.code // "-"' 2>/dev/null || echo -)"
  elif [ "$code" = 403 ] && printf '%s\n' "$body" | grep -qiE 'blocked|approval required'; then
    echo "blocked $(printf '%s\n' "$body" | grep -m 1 .)"
  elif [ "${code:0:1}" = 5 ] && printf '%s\n' "$body" | grep -qiE 'connection refused|dial tcp'; then
    echo "down $(printf '%s\n' "$body" | grep -m 1 .)"
  else
    echo "other $code"
  fi
}

# What answers at the session listener (POST /v1/session/hello without a
# key: the hub answers 401) and at the phone listener (GET /v1/info without
# Tailscale's identity header: the hub answers 403 not_owner).
mc_probe_session() { mc_probe "http://$1:$MAGIC_CONCH_SESSION_PORT/v1/session/hello" POST; }
mc_probe_phone() { mc_probe "http://$1:$MAGIC_CONCH_PHONE_PORT/v1/info" GET; }

# One line per finding, for doctor in a sandbox or plain mode: "ok: …",
# "warn: …", "fail: …" or "info: …". In a sandbox it also checks that the
# phone listener is out of reach: only tailscale serve may reach it (the
# hub trusts the identity header serve sets, lock 1 of the protocol).
mc_env_report() {
  local host s p
  host=$(mc_host)
  s=$(mc_probe_session "$host")
  case "$s" in
    hub\ *) echo "ok: the hub's session listener answers at http://$host:$MAGIC_CONCH_SESSION_PORT" ;;
    blocked\ *) echo "info: no hub reachable: the network policy doesn't let this sandbox reach localhost:$MAGIC_CONCH_SESSION_PORT (on a host that runs the hub, allow it once with: sbx policy allow network localhost:$MAGIC_CONCH_SESSION_PORT)" ;;
    down\ *)
      if [ "$(detect_mode)" = sbx ]; then
        echo "warn: the network policy lets this sandbox reach localhost:$MAGIC_CONCH_SESSION_PORT, but no hub answers there; on the host, run: devenv hub start"
      else
        echo "info: no hub answers at $host:$MAGIC_CONCH_SESSION_PORT (it runs on a host: devenv hub start)"
      fi ;;
    *) echo "warn: something other than the hub answers at http://$host:$MAGIC_CONCH_SESSION_PORT (${s#other })" ;;
  esac
  [ "$(detect_mode)" = sbx ] || return 0
  p=$(mc_probe_phone "$host")
  case "$p" in
    blocked\ *) echo "ok: the hub's phone listener is out of this sandbox's reach (localhost:$MAGIC_CONCH_PHONE_PORT is denied; only tailscale serve may reach it)" ;;
    *) echo "fail: the network policy lets this sandbox reach localhost:$MAGIC_CONCH_PHONE_PORT, the hub's phone listener, which only tailscale serve may reach; on the host, remove the rule that allows it (sbx policy ls shows it)" ;;
  esac
}

# devenv check's hub warnings (sandbox only): a hub the policy lets this
# sandbox reach that doesn't answer, and a phone listener within reach.
check_magic_conch_hub() {
  local host s p
  [ "$(detect_mode)" = sbx ] || return 0
  host=$(mc_host)
  s=$(mc_probe_session "$host")
  case "$s" in
    hub\ *) _check_note "the Magic Conch hub answers at http://$host:$MAGIC_CONCH_SESSION_PORT" ;;
    down\ *) _check_warn "the Magic Conch hub doesn't answer at $host:$MAGIC_CONCH_SESSION_PORT, although the network policy allows it; on the host: devenv hub start" ;;
  esac
  p=$(mc_probe_phone "$host")
  case "$p" in
    blocked\ *) ;;
    *) _check_warn "this sandbox can reach the Magic Conch hub's phone listener (localhost:$MAGIC_CONCH_PHONE_PORT), which only tailscale serve may reach; remove that network policy rule on the host" ;;
  esac
}
