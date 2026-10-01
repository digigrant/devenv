# shellcheck shell=bash
# devenv hub: the Magic Conch hub on the host (spec D36, §6.16).
#
# On the host (Docker Engine, and Tailscale signed in, with MagicDNS and HTTPS certificates):
#   devenv hub start          build its image and fetch its Whisper model when needed, start it (and
#                             at every boot), and put its phone listener on the tailnet (tailscale serve)
#   devenv hub stop           stop it and remove its container; its data stays
#   devenv hub status         the container, both listeners, tailscale serve and the network policy
#   devenv hub admin ARGS...  the hub's administration tool: pairing-code, devices, revoke-device,
#                             add-session, default-session, sessions, replace-session-key, revoke-session
#   devenv hub clean          stop it, and remove its images, model, downloads and tailscale serve entry;
#                             its data stays
# In the sandbox (or plain mode):
#   devenv hub status         whether the hub's session listener answers, and what to do when it doesn't
#
# Host code: it reads nothing from the workspace dev/. The hub runs in a
# container as the host user, read-only apart from its data folder, with no
# capabilities, on its own Docker network. Its phone listener is published on
# the host's 127.0.0.1 only, and `tailscale serve` puts it on the tailnet over
# HTTPS; its session listener is published on 127.0.0.1 only, and sandboxes
# reach it at host.docker.internal once the host's network policy allows
# localhost:<session port>. The hub's source comes from the private repo
# MAGIC_CONCH_REPO, downloaded with the gej-machine token from Infisical (on
# curl's stdin); everything else it needs is pinned in versions.env. Uses
# lib/magic-conch.sh, lib/tailscale.sh and lib/secrets.sh.

HUB_NAME=devenv-magic-conch-hub     # the container, the image repository and the Docker network
HUB_LABEL=devenv.magic-conch-hub    # label on its images (image), container (container) and network (network)
HUB_PHONE_CPORT=8430                # the listeners' ports inside the container (magic-conch/hub/Dockerfile)
HUB_SESSION_CPORT=8431
HF_URL=https://huggingface.co

hub_usage() { sed -n '4,15p' "$DEVENV_ROOT/lib/cmd/hub.sh" | sed 's/^# \{0,1\}//'; }

# The hub's data folder: its database (paired phones, key hashes, the queues
# and the text history) and audio waiting for transcription. The hub's own
# default place; owner-only, and never removed by devenv.
hub_data_dir() { printf '%s' "${XDG_DATA_HOME:-$HOME/.local/share}/magic-conch-hub"; }
# The pinned Whisper model, and the folder that holds every model devenv kept.
hub_models_dir() { printf '%s' "${XDG_DATA_HOME:-$HOME/.local/share}/devenv/whisper"; }
hub_model_dir() { printf '%s/%s-%s' "$(hub_models_dir)" "${MAGIC_CONCH_WHISPER_REPO##*/}" "${MAGIC_CONCH_WHISPER_REVISION:0:12}"; }
hub_cache() { printf '%s' "$DEVENV_CACHE/magic-conch-hub"; }

# The image, tagged by what goes into it; a new pin or recipe means a new one.
hub_image() {
  printf '%s:%s' "$HUB_NAME" "$( { cat "$DEVENV_ROOT/magic-conch/hub/Dockerfile"
    printf '%s\n' "$MAGIC_CONCH_REPO" "$MAGIC_CONCH_COMMIT" "$MAGIC_CONCH_SHA256" "$MAGIC_CONCH_BASE_IMAGE" "$MAGIC_CONCH_UV_IMAGE"; } \
    | sha256sum | cut -c1-12)"
}

# The pinned model's files, one "<file> <sha256>" per line.
hub_model_files() {
  local fs
  read -r -a fs <<<"$MAGIC_CONCH_WHISPER_FILES"
  printf '%s\n' "${fs[@]}" | tr ':' ' '
}

hub_settings_problems() {
  local k v
  for k in MAGIC_CONCH_PHONE_PORT MAGIC_CONCH_SESSION_PORT; do
    v=${!k:-}
    if ! [[ $v =~ ^[0-9]+$ ]] || [ "$v" -lt 1024 ] || [ "$v" -gt 65535 ]; then
      echo "$k in devenv.conf must be a number from 1024 to 65535, not '$v'"
    fi
  done
  [ "${MAGIC_CONCH_PHONE_PORT:-}" != "${MAGIC_CONCH_SESSION_PORT:-}" ] \
    || echo "MAGIC_CONCH_PHONE_PORT and MAGIC_CONCH_SESSION_PORT in devenv.conf must differ"
  return 0
}

hub_docker_problem() { docker_engine_problem "which publishes ports on Windows, out of reach of tailscale serve in this Linux" "Magic Conch hub"; }

hub_host_only() {
  [ "$(detect_mode)" != sbx ] || die "devenv hub $1 runs on the host, not in a sandbox (here: devenv hub status)"
}

# "<status> <health>" of the container ("running healthy", "running
# starting", "restarting", "exited"), or nothing when there is none.
hub_container_state() {
  docker inspect -f '{{.State.Status}}{{if .State.Health}} {{.State.Health.Status}}{{end}}' "$HUB_NAME" 2>/dev/null </dev/null || true
}
hub_container_label() {
  docker inspect -f "{{index .Config.Labels \"$HUB_LABEL.config\"}}" "$HUB_NAME" 2>/dev/null </dev/null || true
}

# ---------------------------------------------------------------- tailnet
# Read what the hub needs from `tailscale status --json` into HUB_TS_NAME
# (this machine's MagicDNS name), HUB_TS_LOGIN (the login of the user it is
# signed in as: the phone listener serves that login only, lock 2 of the
# protocol) and HUB_TS_LABEL (the hub's name, from the machine's). When
# something is missing, sets HUB_TS_PROBLEM to it and its fix, and returns 1.
hub_tailnet_read() {
  local json state tagged https magic
  HUB_TS_NAME='' HUB_TS_LOGIN='' HUB_TS_LABEL='' HUB_TS_PROBLEM=''
  if ! have tailscale; then HUB_TS_PROBLEM="Tailscale is not installed; run: $DEVENV_ROOT/bin/devenv tailscale-setup"; return 1; fi
  json=$(ts_status_json)
  state=$(printf '%s' "$json" | jq -r '.BackendState // empty' 2>/dev/null) || state=''
  if [ "$state" != Running ]; then
    HUB_TS_PROBLEM="this machine isn't signed in to Tailscale (${state:-no answer from tailscaled}); see the Tailscale section of devenv doctor"
    return 1
  fi
  IFS=$'\t' read -r HUB_TS_NAME HUB_TS_LOGIN HUB_TS_LABEL tagged https magic < <(printf '%s' "$json" | jq -r '
    (.Self.DNSName // "" | rtrimstr(".")) as $n
    | [$n, (.User[(.Self.UserID // 0 | tostring)].LoginName // ""), (.Self.HostName // "" | .[0:40]),
       ((.Self.Tags // []) | length > 0 | tostring), (any((.CertDomains // [])[]; . == $n) | tostring),
       (.CurrentTailnet.MagicDNSEnabled // false | tostring)] | @tsv')
  if [ -z "$HUB_TS_NAME" ] || [ "$magic" != true ]; then
    HUB_TS_PROBLEM="MagicDNS is off for the tailnet, and phones reach the hub by this machine's MagicDNS name: turn it on once in the admin console's DNS page ($TS_CONSOLE/dns)"
    return 1
  fi
  if [ "$https" != true ]; then
    HUB_TS_PROBLEM="HTTPS certificates are off for the tailnet, and tailscale serve needs them: turn them on once in the admin console, DNS page, HTTPS Certificates, Enable HTTPS ($TS_CONSOLE/dns)"
    return 1
  fi
  if [ "$tagged" = true ] || [ -z "$HUB_TS_LOGIN" ] || [ "$HUB_TS_LOGIN" = tagged-devices ]; then
    HUB_TS_PROBLEM="this machine is a tagged device, so it names no owner login for the hub to accept; devenv takes the owner's Tailscale login from the user the machine is signed in as: remove its tags and sign it in as yourself (sudo tailscale up --force-reauth)"
    return 1
  fi
  [ -n "$HUB_TS_LABEL" ] || HUB_TS_LABEL=Hub
  return 0
}

# The phone listener's address on the tailnet, as tailscale serve publishes it.
hub_url() { printf 'https://%s:%s' "$HUB_TS_NAME" "$MAGIC_CONCH_PHONE_PORT"; }

# What tailscale serve does with the hub's ports, one line:
#   ok                 https port <phone> goes to the phone listener on 127.0.0.1
#   absent             nothing is served on the phone port
#   other <target>     the phone port is served to something else
#   funnel             Funnel is on for the phone port: the public internet reaches it
#   session            something is served on, or to, the session port
#   unknown <why>      tailscale serve status failed
hub_serve_state() {
  local json
  if ! json=$(timeout 10 tailscale serve status --json </dev/null 2>&1); then
    echo "unknown $(printf '%s\n' "$json" | grep -m 1 . || echo 'tailscale serve status failed')"
    return 0
  fi
  [ -n "$json" ] || json='{}'
  printf '%s' "$json" | jq -r --arg p "$MAGIC_CONCH_PHONE_PORT" --arg s "$MAGIC_CONCH_SESSION_PORT" '
    (.TCP // {}) as $tcp | (.Web // {}) as $web | (.AllowFunnel // {}) as $fun
    | [$web[] | (.Handlers // {})[] | .Proxy // empty] as $proxies
    | ([$web | to_entries[] | select(.key | endswith(":" + $p)) | .value.Handlers["/"].Proxy // empty] | first // "") as $t
    | if $tcp[$s] != null or any($proxies[]; test(":" + $s + "(/.*)?$"))
         or any($fun | to_entries[]; (.key | endswith(":" + $s)) and .value) then "session"
      elif any($fun | to_entries[]; (.key | endswith(":" + $p)) and .value) then "funnel"
      elif $tcp[$p] == null then "absent"
      elif ($tcp[$p].HTTPS == true) and ($t == "http://127.0.0.1:" + $p or $t == "http://localhost:" + $p) then "ok"
      else "other " + (if $t == "" then ($tcp[$p] | tostring) else $t end) end' 2>/dev/null \
    || echo "unknown tailscale serve status --json printed something devenv can't read"
}

# The fix for a serve state other than ok and absent, one line.
hub_serve_problem() {
  case "$1" in
    funnel) echo "Tailscale Funnel is on for port $MAGIC_CONCH_PHONE_PORT, so the public internet reaches the hub's phone listener: turn it off: sudo tailscale funnel --https=$MAGIC_CONCH_PHONE_PORT off" ;;
    session) echo "tailscale serve publishes the hub's session listener (port $MAGIC_CONCH_SESSION_PORT), which must stay on this host: remove that entry (tailscale serve status shows it; e.g. sudo tailscale serve --https=$MAGIC_CONCH_SESSION_PORT off)" ;;
    other\ *) echo "tailscale serve already sends https port $MAGIC_CONCH_PHONE_PORT to ${1#other } instead of the hub; remove it (sudo tailscale serve --https=$MAGIC_CONCH_PHONE_PORT off), or choose another MAGIC_CONCH_PHONE_PORT" ;;
    unknown\ *) echo "could not read tailscale serve's configuration (${1#unknown })" ;;
  esac
}

# ---------------------------------------------------------------- building
# Download the hub's source: GitHub's tarball of MAGIC_CONCH_REPO at
# MAGIC_CONCH_COMMIT, checked against MAGIC_CONCH_SHA256. The repository is
# private: the request carries the $BOT_LOGIN token, fetched from Infisical
# ($SECRET_GITHUB) and handed to curl on stdin, never on a command line or in
# a file. GitHub redirects the download to codeload.github.com with a
# short-lived token in the link, and curl doesn't pass the header on to
# another host.
hub_fetch_source() {
  local dest=$1 got
  keyring_unlock_if_locked
  secret_fetch_or_error "$SECRET_GITHUB" \
    || die "the hub's source is in the private repository $MAGIC_CONCH_REPO, which devenv downloads with the $BOT_LOGIN token from Infisical, and fetching $SECRET_GITHUB failed: $SECRET_ERROR"
  log "downloading the hub's source ($MAGIC_CONCH_REPO at ${MAGIC_CONCH_COMMIT:0:12})"
  if ! printf 'Authorization: token %s\n' "$SECRET_VALUE" \
       | curl -fsSL --retry 3 --connect-timeout 20 -H @- -o "$dest.part" \
           "https://api.github.com/repos/$MAGIC_CONCH_REPO/tarball/$MAGIC_CONCH_COMMIT" 2>/dev/null; then
    SECRET_VALUE=''
    rm -f "$dest.part"
    die "downloading $MAGIC_CONCH_REPO at $MAGIC_CONCH_COMMIT failed (can $BOT_LOGIN still read that repository?)"
  fi
  SECRET_VALUE=''
  got=$(file_sha256 "$dest.part")
  if [ "$got" != "$MAGIC_CONCH_SHA256" ]; then
    rm -f "$dest.part"
    die "sha256 mismatch for $MAGIC_CONCH_REPO at $MAGIC_CONCH_COMMIT: expected $MAGIC_CONCH_SHA256, got $got (if GitHub changed how it packs tarballs, check the commit and run devenv bump magic-conch $MAGIC_CONCH_COMMIT)"
  fi
  mv -f "$dest.part" "$dest"
}

# hub_remove_old_images KEEP: remove devenv's hub images other than KEEP (all
# of them when KEEP is empty). One in use stays.
hub_remove_old_images() {
  local x
  docker image ls --filter "label=$HUB_LABEL=image" --format '{{.Repository}}:{{.Tag}}' 2>/dev/null </dev/null \
  | while IFS= read -r x; do
      [ -n "$x" ] && [ "$x" != "$1" ] || continue
      docker image rm "$x" >/dev/null 2>&1 </dev/null && log "removed the hub image $x"
    done
  return 0
}

# Build the image from a temporary context holding the Dockerfile and the
# hub's folder of the tarball.
hub_ensure_image() {
  local image=$1 cache tgz ctx top
  docker image inspect "$image" >/dev/null 2>&1 </dev/null && return 0
  cache=$(hub_cache)
  tgz=$cache/magic-conch-$MAGIC_CONCH_COMMIT.tar.gz
  mkdir -p "$cache"
  if ! { [ -f "$tgz" ] && [ "$(file_sha256 "$tgz")" = "$MAGIC_CONCH_SHA256" ]; }; then
    hub_fetch_source "$tgz"
  fi
  ok "the hub's source matches versions.env ($MAGIC_CONCH_REPO at ${MAGIC_CONCH_COMMIT:0:12})"
  ctx=$(mktemp -d)
  top=$(tar -tzf "$tgz" 2>/dev/null | head -n 1) || true
  top=${top%%/*}
  if [ -z "$top" ] || ! tar -xzf "$tgz" -C "$ctx" --strip-components=1 "$top/hub" 2>/dev/null \
     || [ ! -f "$ctx/hub/uv.lock" ] || [ ! -f "$ctx/hub/src/magic_conch_hub/__main__.py" ]; then
    rm -rf "$ctx"
    die "$MAGIC_CONCH_REPO at ${MAGIC_CONCH_COMMIT:0:12} has no hub/ folder with uv.lock and src/magic_conch_hub"
  fi
  cp "$DEVENV_ROOT/magic-conch/hub/Dockerfile" "$ctx/"
  log "building the hub image $image (its Python dependencies from the hub's uv.lock; a minute or two)"
  if ! docker build -q -t "$image" --label "$HUB_LABEL=image" \
       --build-arg "BASE_IMAGE=$MAGIC_CONCH_BASE_IMAGE" --build-arg "UV_IMAGE=$MAGIC_CONCH_UV_IMAGE" \
       "$ctx" >/dev/null </dev/null; then
    rm -rf "$ctx"
    die "building the hub image failed (docker build's output is above)"
  fi
  rm -rf "$ctx" "$tgz"
  ok "hub image $image built"
}

# The Whisper model: each file of MAGIC_CONCH_WHISPER_REPO at the pinned
# revision, downloaded from Hugging Face and checked against its sha256. A
# folder whose marker names these pins isn't checked again.
hub_ensure_model() {
  local dir want f sha
  dir=$(hub_model_dir)
  want=$(hub_model_files)
  [ -n "$want" ] || die "MAGIC_CONCH_WHISPER_FILES in versions.env names no files"
  [ "$(cat "$dir/.devenv-model" 2>/dev/null)" = "$want" ] && return 0
  mkdir -p "$dir"
  log "downloading the Whisper model $MAGIC_CONCH_WHISPER_REPO into $dir (once; medium.en is about 1.5 GB)"
  while read -r f sha; do
    [ -f "$dir/$f" ] && [ "$(file_sha256 "$dir/$f")" = "$sha" ] && continue
    fetch_verified "$HF_URL/$MAGIC_CONCH_WHISPER_REPO/resolve/$MAGIC_CONCH_WHISPER_REVISION/$f" "$sha" "$dir/$f"
  done <<<"$want"
  printf '%s\n' "$want" > "$dir/.devenv-model"
  ok "Whisper model $MAGIC_CONCH_WHISPER_REPO matches versions.env"
}

# Remove models other than the pinned one (once no container uses them).
hub_remove_old_models() {
  local d keep
  keep=$(hub_model_dir)
  for d in "$(hub_models_dir)"/*; do
    [ -d "$d" ] && [ "$d" != "$keep" ] || continue
    rm -rf "$d" && log "removed the old Whisper model $d"
  done
  return 0
}

# The data folder, made owner-only (0700), and owned by the user the
# container runs as.
hub_ensure_data() {
  local d m
  d=$(hub_data_dir)
  if [ ! -d "$d" ]; then
    mkdir -p "${d%/*}"
    mkdir -m 0700 "$d"
    ok "made the hub's data folder $d (owner-only)"
  fi
  [ -O "$d" ] || die "$d belongs to $(stat -c %U "$d"), not to you; the hub runs as you and must own its data folder"
  m=$(stat -c %a "$d")
  if [ "$m" != 700 ]; then chmod 0700 "$d"; ok "made $d owner-only (it was $m)"; fi
}

# Problems with the data folder, one per line; nothing when it is right or
# doesn't exist yet.
hub_data_problems() {
  local d m
  d=$(hub_data_dir)
  [ -e "$d" ] || return 0
  [ -d "$d" ] || { echo "$d is not a folder"; return 0; }
  [ -O "$d" ] || echo "$d belongs to $(stat -c %U "$d"), not to you, and the hub runs as you"
  m=$(stat -c %a "$d")
  [ "$m" = 700 ] || echo "$d is mode $m, not owner-only (700); run: chmod 700 $d (devenv hub start does it)"
  return 0
}

hub_ensure_network() {
  docker network inspect "$HUB_NAME" >/dev/null 2>&1 </dev/null && return 0
  docker network create --label "$HUB_LABEL=network" "$HUB_NAME" >/dev/null </dev/null \
    || die "could not create the Docker network $HUB_NAME"
}

# The container's docker run arguments for IMAGE, in HUB_RUN_ARGS, and a hash
# of them in HUB_RUN_SIG: a container whose label holds another hash runs an
# older image or other settings.
hub_run_args() {
  HUB_RUN_ARGS=(--name "$HUB_NAME" --init --restart unless-stopped --network "$HUB_NAME"
    --user "$(id -u):$(id -g)" --read-only --tmpfs /tmp --cap-drop ALL --security-opt no-new-privileges
    --log-driver local
    -p "127.0.0.1:$MAGIC_CONCH_PHONE_PORT:$HUB_PHONE_CPORT" -p "127.0.0.1:$MAGIC_CONCH_SESSION_PORT:$HUB_SESSION_CPORT"
    --mount "type=bind,src=$(hub_data_dir),dst=/data"
    --mount "type=bind,src=$(hub_model_dir),dst=/models/whisper,readonly"
    -e "MAGIC_CONCH_HUB_OWNER_LOGIN=$HUB_TS_LOGIN" -e "MAGIC_CONCH_HUB_URL=$(hub_url)"
    -e "MAGIC_CONCH_HUB_LABEL=$HUB_TS_LABEL" --label "$HUB_LABEL=container")
  HUB_RUN_SIG=$(printf '%s\n' "${HUB_RUN_ARGS[@]}" "$1" | sha256sum | cut -c1-12)
}

# Wait until the container runs and both listeners answer on 127.0.0.1.
hub_wait_ready() {
  local limit=${DEVENV_HUB_START_TIMEOUT:-120} t0=$SECONDS state
  while :; do
    state=$(hub_container_state)
    case "$state" in
      running*)
        case "$(mc_probe_phone 127.0.0.1) $(mc_probe_session 127.0.0.1)" in
          hub\ *\ hub\ *) ok "the hub answers on 127.0.0.1:$MAGIC_CONCH_PHONE_PORT (phones) and 127.0.0.1:$MAGIC_CONCH_SESSION_PORT (sessions)"; return 0 ;;
        esac ;;
      *)
        docker logs --tail 25 "$HUB_NAME" </dev/null >&2 2>&1 || true
        die "the hub stopped while starting (${state:-its container is gone}); its last log lines are above (all of them: docker logs $HUB_NAME)"
        ;;
    esac
    [ $(( SECONDS - t0 )) -lt "$limit" ] \
      || die "the hub's listeners didn't answer within $limit seconds; see docker logs $HUB_NAME and devenv hub status"
    sleep "${DEVENV_HUB_POLL:-2}"
  done
}

# Put the phone listener on the tailnet: tailscale serve over HTTPS on the
# same port, to 127.0.0.1. Persistent (--bg): it survives reboots. Needs
# root; with everything in place it runs nothing.
hub_ensure_serve() {
  local s
  s=$(hub_serve_state)
  case "$s" in
    ok) ok "tailscale serve publishes $(hub_url) to the phone listener (127.0.0.1:$MAGIC_CONCH_PHONE_PORT)"; return 0 ;;
    absent) ;;
    *) die "$(hub_serve_problem "$s")" ;;
  esac
  log "publishing the phone listener on the tailnet: sudo tailscale serve --bg --https=$MAGIC_CONCH_PHONE_PORT http://127.0.0.1:$MAGIC_CONCH_PHONE_PORT (sudo may ask for your password)"
  if ! as_root tailscale serve --bg "--https=$MAGIC_CONCH_PHONE_PORT" "http://127.0.0.1:$MAGIC_CONCH_PHONE_PORT" >&2 </dev/null; then
    warn "tailscale serve failed; the hub runs, but phones can't reach it until you run: sudo tailscale serve --bg --https=$MAGIC_CONCH_PHONE_PORT http://127.0.0.1:$MAGIC_CONCH_PHONE_PORT"
    return 0
  fi
  s=$(hub_serve_state)
  if [ "$s" = ok ]; then ok "tailscale serve publishes $(hub_url) to the phone listener"
  else warn "tailscale serve ran, but its configuration reads '$s'; see: tailscale serve status"; fi
}

# The two policy lines: the session port should be allowed for sandboxes,
# and the phone port must not be.
hub_policy_lines() {
  case "$(sbx_policy_state "$MAGIC_CONCH_SESSION_PORT")" in
    allowed) echo "ok: sandbox $CONF_SANDBOX_NAME may reach the session listener (the network policy allows localhost:$MAGIC_CONCH_SESSION_PORT)" ;;
    denied) echo "warn: sandboxes can't reach the session listener: allow it once with: sbx policy allow network localhost:$MAGIC_CONCH_SESSION_PORT" ;;
    *) have sbx && echo "info: check that sandboxes may reach it: sbx policy check network --sandbox $CONF_SANDBOX_NAME localhost:$MAGIC_CONCH_SESSION_PORT" ;;
  esac
  case "$(sbx_policy_state "$MAGIC_CONCH_PHONE_PORT")" in
    allowed) echo "fail: the network policy lets sandboxes reach localhost:$MAGIC_CONCH_PHONE_PORT, the hub's phone listener, which only tailscale serve may reach (the hub trusts serve's identity header): remove that rule (sbx policy ls shows it; sbx policy rm network --resource localhost:$MAGIC_CONCH_PHONE_PORT)" ;;
    denied) echo "ok: sandboxes can't reach the phone listener (localhost:$MAGIC_CONCH_PHONE_PORT is denied)" ;;
  esac
  return 0
}

# ---------------------------------------------------------------- reports
# One line per finding, for doctor and status: "ok: …", "warn: …",
# "fail: …" or "info: …". What isn't set up is info; a hub that was started
# and doesn't work, or an exposed listener, is a failure.
hub_host_report() {
  local p image state s e2e dir
  p=$(hub_settings_problems)
  if [ -n "$p" ]; then printf '%s\n' "$p" | sed 's/^/fail: /'; return 0; fi
  if ! have docker; then
    echo "info: not set up: it needs Docker Engine in this Linux (README: Magic Conch hub), then devenv hub start"
    return 0
  fi
  p=$(hub_docker_problem)
  if [ -n "$p" ]; then echo "warn: $p"; return 0; fi
  image=$(hub_image)
  if docker image inspect "$image" >/dev/null 2>&1 </dev/null; then echo "ok: image $image ($MAGIC_CONCH_REPO at ${MAGIC_CONCH_COMMIT:0:12})"
  else echo "info: image $image not built yet (devenv hub start builds it)"; fi
  dir=$(hub_model_dir)
  if [ "$(cat "$dir/.devenv-model" 2>/dev/null)" = "$(hub_model_files)" ]; then echo "ok: Whisper model $MAGIC_CONCH_WHISPER_REPO in $dir"
  else echo "info: Whisper model $MAGIC_CONCH_WHISPER_REPO not downloaded yet (devenv hub start does it)"; fi
  p=$(hub_data_problems)
  if [ -n "$p" ]; then printf '%s\n' "$p" | sed 's/^/fail: /'
  elif [ -d "$(hub_data_dir)" ]; then echo "ok: data folder $(hub_data_dir), owner-only"; fi
  state=$(hub_container_state)
  case "$state" in
    '') echo "info: not running (devenv hub start)" ;;
    running*)
      case "$state" in
        "running healthy") echo "ok: running (container $HUB_NAME, healthy)" ;;
        "running unhealthy") echo "fail: running, but its listeners stopped answering (Docker's health check); see docker logs $HUB_NAME, then devenv hub stop and devenv hub start" ;;
        *) echo "info: running; its health check hasn't passed yet" ;;
      esac
      if hub_tailnet_read && [ "$(hub_container_label)" != "$(hub_run_args "$image"; echo "$HUB_RUN_SIG")" ]; then
        echo "warn: it runs an older image or other settings; devenv hub start replaces it"
      fi
      case "$(mc_probe_phone 127.0.0.1)" in
        "hub 403 not_owner") echo "ok: the phone listener answers on 127.0.0.1:$MAGIC_CONCH_PHONE_PORT" ;;
        *) echo "fail: nothing like the hub's phone listener answers on 127.0.0.1:$MAGIC_CONCH_PHONE_PORT; see docker logs $HUB_NAME" ;;
      esac
      case "$(mc_probe_session 127.0.0.1)" in
        hub\ 401\ *) echo "ok: the session listener answers on 127.0.0.1:$MAGIC_CONCH_SESSION_PORT" ;;
        *) echo "fail: nothing like the hub's session listener answers on 127.0.0.1:$MAGIC_CONCH_SESSION_PORT; see docker logs $HUB_NAME" ;;
      esac
      if ts_systemd_running && [ "$(systemctl is-enabled docker 2>/dev/null)" != enabled ]; then
        echo "warn: Docker doesn't start at boot, so the hub won't either; run: sudo systemctl enable docker"
      fi
      ;;
    *) echo "fail: its container isn't running ($state); see docker logs $HUB_NAME, then devenv hub start" ;;
  esac
  if [ -z "$state" ] && ! docker image inspect "$image" >/dev/null 2>&1 </dev/null; then
    # Not set up on this host: only a policy rule that exposes the phone
    # port matters.
    hub_policy_lines | grep '^fail: ' || true
    return 0
  fi
  if have tailscale; then
    if ! hub_tailnet_read; then
      echo "warn: phones can't reach it: $HUB_TS_PROBLEM"
    else
      s=$(hub_serve_state)
      case "$s" in
        ok) echo "ok: tailscale serve publishes $(hub_url) to the phone listener" ;;
        absent) echo "warn: tailscale serve doesn't publish the phone listener, so phones can't reach it; run: devenv hub start" ;;
        unknown\ *) echo "warn: $(hub_serve_problem "$s")" ;;
        *) echo "fail: $(hub_serve_problem "$s")" ;;
      esac
      if [ "$s" = ok ] && [[ $state == running* ]]; then
        # Through the tailnet, as a phone would: tailscale serve adds this
        # machine's owner as the identity, which the hub must accept.
        e2e=$(mc_probe "$(hub_url)/v1/info" GET)
        case "$e2e" in
          "hub 200 -") echo "ok: $(hub_url) reaches the hub through tailscale serve, and the hub accepts your login ($HUB_TS_LOGIN)" ;;
          "hub 403 not_owner") echo "fail: $(hub_url) reaches the hub, but it refuses your login: run devenv hub start again (it takes the login from the user this machine is signed in as)" ;;
          *) echo "info: $(hub_url) didn't answer from this machine (${e2e%% *}); check it from the phone" ;;
        esac
      fi
    fi
  fi
  hub_policy_lines
}

hub_status() {
  echo "Magic Conch hub"
  if [ "$(detect_mode)" = sbx ]; then emu_print_report < <(mc_env_report)
  else emu_print_report < <(hub_host_report); fi
}

# ---------------------------------------------------------------- commands
hub_start() {
  local p image state
  hub_host_only start
  p=$(hub_settings_problems)
  [ -z "$p" ] || die "$(printf '%s\n' "$p" | head -n 1)"
  p=$(hub_docker_problem)
  [ -z "$p" ] || die "$p"
  hub_tailnet_read || die "$HUB_TS_PROBLEM"
  p=$(hub_serve_state)
  case "$p" in ok|absent) ;; *) die "$(hub_serve_problem "$p")" ;; esac
  image=$(hub_image)
  hub_ensure_image "$image"
  hub_ensure_model
  hub_ensure_data
  hub_ensure_network
  hub_run_args "$image"
  state=$(hub_container_state)
  if [[ $state == running* ]] && [ "$(hub_container_label)" = "$HUB_RUN_SIG" ]; then
    ok "the hub is already running"
  else
    if [ -n "$state" ]; then
      log "replacing the hub's container (${state%% *}; a new image or other settings)"
      docker stop -t 30 "$HUB_NAME" >/dev/null 2>&1 </dev/null || true
    fi
    docker rm -f "$HUB_NAME" >/dev/null 2>&1 </dev/null || true
    if ! p=$(docker run -d "${HUB_RUN_ARGS[@]}" --label "$HUB_LABEL.config=$HUB_RUN_SIG" "$image" 2>&1 </dev/null); then
      docker rm -f "$HUB_NAME" >/dev/null 2>&1 </dev/null || true
      case "$p" in
        *"already allocated"*|*"address already in use"*)
          die "a port on 127.0.0.1 is taken ($MAGIC_CONCH_PHONE_PORT or $MAGIC_CONCH_SESSION_PORT); free it, or choose others: MAGIC_CONCH_PHONE_PORT and MAGIC_CONCH_SESSION_PORT in devenv.conf" ;;
      esac
      die "docker run failed: $(printf '%s\n' "$p" | tail -n 1)"
    fi
    log "hub started (container $HUB_NAME, label $HUB_TS_LABEL, owner $HUB_TS_LOGIN); it starts again at every boot"
  fi
  hub_wait_ready
  hub_remove_old_images "$image"
  hub_remove_old_models
  hub_ensure_serve
  while IFS= read -r p; do
    case "$p" in
      "ok: "*) ok "${p#ok: }" ;;
      "warn: "*) warn "${p#warn: }" ;;
      "fail: "*) warn "${p#fail: }" ;;
      "info: "*) log "${p#info: }" ;;
    esac
  done < <(hub_policy_lines)
  log "phones: $(hub_url) (pair one: devenv hub admin pairing-code)"
  log "sessions: http://host.docker.internal:$MAGIC_CONCH_SESSION_PORT from a sandbox (add one: devenv hub admin add-session firstmate Firstmate; then devenv hub admin default-session firstmate)"
}

hub_stop() {
  local p
  hub_host_only stop
  p=$(hub_docker_problem)
  [ -z "$p" ] || die "$p"
  if [ -z "$(hub_container_state)" ]; then ok "the hub is not running"; return 0; fi
  docker stop -t 30 "$HUB_NAME" >/dev/null 2>&1 </dev/null || true
  docker rm -f "$HUB_NAME" >/dev/null 2>&1 </dev/null || die "could not remove the container $HUB_NAME"
  ok "hub stopped; its data ($(hub_data_dir)), image and model stay, and tailscale serve keeps its entry (phones get an error until devenv hub start)"
}

hub_clean() {
  local p s
  hub_host_only clean
  p=$(hub_docker_problem)
  [ -z "$p" ] || die "$p"
  docker rm -f "$HUB_NAME" >/dev/null 2>&1 </dev/null && log "removed the container $HUB_NAME" || true
  hub_remove_old_images ''
  docker network rm "$HUB_NAME" >/dev/null 2>&1 </dev/null && log "removed the Docker network $HUB_NAME" || true
  rm -rf "$(hub_models_dir)" "$(hub_cache)"
  if have tailscale; then
    s=$(hub_serve_state)
    if [ "$s" = ok ]; then
      if as_root tailscale serve "--https=$MAGIC_CONCH_PHONE_PORT" off >&2 </dev/null; then log "removed tailscale serve's entry for port $MAGIC_CONCH_PHONE_PORT"
      else warn "could not remove tailscale serve's entry; run: sudo tailscale serve --https=$MAGIC_CONCH_PHONE_PORT off"; fi
    fi
  fi
  ok "removed the hub's container, images, network, Whisper model and downloads"
  log "its data stays in $(hub_data_dir) (paired phones, sessions, history); to start over, delete it yourself"
}

# The hub's administration tool (protocol section 10), in the running
# container, on the hub's own store. No terminal is attached, so standard
# output and standard error stay apart: a session key is alone on stdout.
hub_admin() {
  hub_host_only admin
  [[ $(hub_container_state) == running* ]] || die "the hub isn't running; start it: devenv hub start"
  exec docker exec "$HUB_NAME" python -m magic_conch_hub.admin "$@"
}

cmd_hub() {
  local sub=${1:-}
  [ $# -gt 0 ] && shift
  resolve_paths
  case "$sub" in
    start) hub_start ;;
    stop) hub_stop ;;
    status) hub_status ;;
    admin) hub_admin "$@" ;;
    clean) hub_clean ;;
    ''|-h|--help|help) hub_usage ;;
    *) hub_usage >&2; die "unknown hub command: $sub" ;;
  esac
}
