# shellcheck shell=bash
# devenv emulator: the opt-in Android emulator on the host (spec §6.14).
#
# On the host (x86_64 Linux with KVM and Docker Engine):
#   devenv emulator start       start it (building its image and SDK volume first when needed) and wait for Android to boot
#   devenv emulator stop        stop it and remove its container
#   devenv emulator status      the container, boot, adb and the sandbox's network policy rule
#   devenv emulator clean       stop it and remove its images, SDK volumes and downloads
# In the sandbox (or plain mode):
#   devenv emulator connect     adb-connect to it and print the device serial
#   devenv emulator run -- CMD  connect, then run CMD with ANDROID_SERIAL set, one run at a time
#   devenv emulator status      whether it answers, and what to do when it doesn't
#
# Host code: it reads nothing from the workspace dev/. The emulator runs in a
# container with /dev/kvm; its adb port is published on the host's 127.0.0.1
# only, and a sandbox reaches it at host.docker.internal once the host's
# network policy allows localhost:<port>. Uses lib/android.sh.

EMU_NAME=devenv-android-emulator      # the container, and the image repository
EMU_SDK_VOLUME=devenv-android-sdk     # prefix of the SDK volumes' names
EMU_LABEL=devenv.android-emulator     # label on the images (image) and SDK volumes (sdk)
EMU_CONTAINER_PORT=6555               # launch.sh forwards it to the emulator's adb port
EMU_LOCK=devenv-android-emulator.lock # `run` holds it, in XDG_RUNTIME_DIR or /tmp

emu_usage() { sed -n '4,13p' "$DEVENV_ROOT/lib/cmd/emulator.sh" | sed 's/^# \{0,1\}//'; }

# The KVM device, overridable so tests can stand in for a missing one.
emu_kvm() { printf '%s' "${DEVENV_KVM_DEVICE:-/dev/kvm}"; }

# Where the emulator's adb port is: the host, seen from a sandbox, or this machine.
emu_host() { if [ "$(detect_mode)" = sbx ]; then echo host.docker.internal; else echo 127.0.0.1; fi; }

emu_settings_problems() {
  local k v min max
  for k in ANDROID_EMULATOR_PORT:1024:65535 ANDROID_EMULATOR_MEMORY:2048:65536 ANDROID_EMULATOR_CORES:1:64; do
    IFS=: read -r k min max <<<"$k"
    v=${!k:-}
    if ! [[ $v =~ ^[0-9]+$ ]] || [ "$v" -lt "$min" ] || [ "$v" -gt "$max" ]; then
      echo "$k in devenv.conf must be a number from $min to $max, not '$v'"
    fi
  done
  return 0
}

# Why Docker can't run the emulator here, one line with the fix; nothing when it can.
emu_docker_problem() { docker_engine_problem "whose containers get no /dev/kvm" "Android emulator"; }

emu_kvm_problem() {
  [ -e "$(emu_kvm)" ] || echo "$(emu_kvm) is missing: this machine has no KVM (turn on virtualization in the firmware settings; under WSL, nested virtualization)"
  return 0
}

emu_host_only() {
  [ "$(detect_mode)" != sbx ] || die "devenv emulator $1 runs on the host, not in a sandbox (here: devenv emulator connect, run or status)"
}

# Everything start needs; dies with the first problem and its fix.
emu_host_ready() {
  local p
  emu_host_only "$1"
  android_supported || die "the Android emulator runs on x86_64 Linux only (this is $(uname -m))"
  for p in "$(emu_settings_problems)" "$(emu_kvm_problem)" "$(emu_docker_problem)"; do
    [ -z "$p" ] || die "$p"
  done
}

# The image (tagged by what goes into it) and the SDK volume (named by the
# pins it holds); a changed pin or script means a new one.
emu_image() {
  printf '%s:%s' "$EMU_NAME" "$( { cat "$DEVENV_ROOT/android/emulator/Dockerfile" "$DEVENV_ROOT/android/emulator/launch.sh"
    printf '%s\n' "$ANDROID_EMULATOR_BASE_IMAGE"; } | sha256sum | cut -c1-12)"
}
emu_sdk_volume() {
  printf '%s-api%s-%s' "$EMU_SDK_VOLUME" "$ANDROID_SYSTEM_IMAGE_API" "$(printf '%s\n' "$ANDROID_EMULATOR_BUILD" \
    "$ANDROID_EMULATOR_SHA256" "$ANDROID_SYSTEM_IMAGE_API" "$ANDROID_SYSTEM_IMAGE_TAG" "$ANDROID_SYSTEM_IMAGE_ZIP" \
    "$ANDROID_SYSTEM_IMAGE_SHA256" "$ANDROID_PLATFORM_TOOLS_VERSION" "$ANDROID_PLATFORM_TOOLS_SHA256" | sha256sum | cut -c1-12)"
}
emu_cache() { printf '%s' "$DEVENV_CACHE/android-emulator"; }

# "<status> <health>" of the container ("running healthy", "running
# starting", "exited"), or nothing when there is none.
emu_container_state() {
  docker inspect -f '{{.State.Status}}{{if .State.Health}} {{.State.Health.Status}}{{end}}' "$EMU_NAME" 2>/dev/null </dev/null || true
}

# emu_remove_old image|sdk KEEP: remove devenv's emulator images or SDK
# volumes other than KEEP (all of them when KEEP is empty). Ones in use stay.
emu_remove_old() {
  local kind=$1 keep=$2 x
  { if [ "$kind" = image ]; then docker image ls --filter "label=$EMU_LABEL=image" --format '{{.Repository}}:{{.Tag}}'
    else docker volume ls --filter "label=$EMU_LABEL=sdk" --format '{{.Name}}'; fi; } 2>/dev/null </dev/null \
  | while IFS= read -r x; do
      [ -n "$x" ] && [ "$x" != "$keep" ] || continue
      if [ "$kind" = image ]; then docker image rm "$x" >/dev/null 2>&1 </dev/null && log "removed the emulator image $x"
      else docker volume rm "$x" >/dev/null 2>&1 </dev/null && log "removed the SDK volume $x"; fi
    done
  return 0
}

emu_ensure_image() {
  local image=$1 ctx
  docker image inspect "$image" >/dev/null 2>&1 </dev/null && return 0
  ctx=$(mktemp -d)
  cp "$DEVENV_ROOT/android/emulator/Dockerfile" "$DEVENV_ROOT/android/emulator/launch.sh" "$ctx/"
  log "building the emulator image $image (runtime libraries only; a minute or two)"
  if ! docker build -q -t "$image" --label "$EMU_LABEL=image" \
       --build-arg "BASE_IMAGE=$ANDROID_EMULATOR_BASE_IMAGE" "$ctx" >/dev/null </dev/null; then
    rm -rf "$ctx"
    die "building the emulator image failed (docker build's output is above)"
  fi
  rm -rf "$ctx"
  ok "emulator image $image built"
  emu_remove_old image "$image"
}

# emu_fetch URL SHA256 DEST: download and verify, keeping a DEST that already matches.
emu_fetch() {
  [ -f "$3" ] && [ "$(file_sha256 "$3")" = "$2" ] && return 0
  log "downloading ${1##*/}"
  fetch_verified "$1" "$2" "$3"
}

# The SDK volume: the pinned zips, downloaded and checked here, then unpacked
# into a Docker volume by the image (launch.sh --unpack). A volume without
# launch.sh's completion marker (an interrupted unpack) is made again.
emu_ensure_sdk() {
  local image=$1 vol=$2 cache
  if docker volume inspect "$vol" >/dev/null 2>&1 </dev/null; then
    docker run --rm -v "$vol:/android/sdk:ro" --entrypoint test "$image" -f /android/sdk/.devenv-sdk </dev/null && return 0
    log "the SDK volume $vol is incomplete; unpacking it again"
    docker volume rm -f "$vol" >/dev/null </dev/null
  fi
  cache=$(emu_cache)
  mkdir -p "$cache"
  log "downloading the emulator, the Android $ANDROID_SYSTEM_IMAGE_API system image and platform-tools (about 2.2 GB) into $cache"
  emu_fetch "$ANDROID_REPO_URL/emulator-linux_x64-$ANDROID_EMULATOR_BUILD.zip" "$ANDROID_EMULATOR_SHA256" "$cache/emulator.zip"
  emu_fetch "$ANDROID_REPO_URL/sys-img/$ANDROID_SYSTEM_IMAGE_TAG/$ANDROID_SYSTEM_IMAGE_ZIP" "$ANDROID_SYSTEM_IMAGE_SHA256" "$cache/system-image.zip"
  emu_fetch "$ANDROID_REPO_URL/platform-tools_r$ANDROID_PLATFORM_TOOLS_VERSION-linux.zip" "$ANDROID_PLATFORM_TOOLS_SHA256" "$cache/platform-tools.zip"
  ok "downloads match versions.env"
  docker volume create --label "$EMU_LABEL=sdk" "$vol" >/dev/null </dev/null
  log "unpacking them into the Docker volume $vol (about 5 GB)"
  if ! docker run --rm -v "$vol:/android/sdk" -v "$cache:/zips:ro" "$image" \
       --unpack "system-images/android-$ANDROID_SYSTEM_IMAGE_API/$ANDROID_SYSTEM_IMAGE_TAG" >&2 </dev/null; then
    docker volume rm -f "$vol" >/dev/null 2>&1 </dev/null || true
    die "unpacking the SDK failed (output above)"
  fi
  rm -f "$cache"/*.zip
  emu_remove_old sdk "$vol"
}

emu_wait_boot() {
  local limit=${DEVENV_EMULATOR_BOOT_TIMEOUT:-900} t0=$SECONDS next=60 state
  while :; do
    state=$(emu_container_state)
    case "$state" in
      "running healthy") ok "Android booted ($(( SECONDS - t0 ))s)"; return 0 ;;
      running*) ;;
      *)
        docker logs --tail 25 "$EMU_NAME" </dev/null >&2 2>&1 || true
        die "the emulator stopped while booting (${state:-its container is gone}); its last log lines are above (all of them: docker logs $EMU_NAME; then devenv emulator stop)"
        ;;
    esac
    [ $(( SECONDS - t0 )) -lt "$limit" ] \
      || die "Android did not boot within $(( limit / 60 )) minutes; see docker logs $EMU_NAME, then devenv emulator stop"
    if [ $(( SECONDS - t0 )) -ge "$next" ]; then log "still booting ($(( SECONDS - t0 ))s)"; next=$(( next + 60 )); fi
    sleep "${DEVENV_EMULATOR_POLL:-5}"
  done
}

# allowed or denied: whether the host's network policy lets sandbox dev reach
# localhost:<port> (sbx policy check); nothing when sbx can't say.
emu_policy_state() { sbx_policy_state "$ANDROID_EMULATOR_PORT"; }

# One line per finding, for doctor and status: "ok: …", "warn: …", "fail: …"
# or "info: …". The emulator is optional: what isn't set up is info, not a
# failure; a started emulator that doesn't work is.
emu_host_report() {
  local p image vol state out
  if ! android_supported; then echo "info: not available on $(uname -m): Google publishes the emulator for x86_64 Linux only"; return 0; fi
  p=$(emu_settings_problems)
  if [ -n "$p" ]; then printf 'fail: %s\n' "$p"; return 0; fi
  if ! have docker; then
    echo "info: not set up: it needs Docker Engine in this Linux (README: Android emulator), then devenv emulator start"
    return 0
  fi
  p=$(emu_docker_problem)
  if [ -n "$p" ]; then echo "warn: $p"; return 0; fi
  echo "ok: Docker Engine $(docker version --format '{{.Server.Version}}' 2>/dev/null </dev/null)"
  p=$(emu_kvm_problem)
  if [ -n "$p" ]; then echo "warn: $p"; return 0; fi
  image=$(emu_image) vol=$(emu_sdk_volume)
  if docker image inspect "$image" >/dev/null 2>&1 </dev/null; then echo "ok: image $image"
  else echo "info: image $image not built yet (devenv emulator start builds it)"; fi
  if docker volume inspect "$vol" >/dev/null 2>&1 </dev/null; then echo "ok: SDK volume $vol (Android API $ANDROID_SYSTEM_IMAGE_API, $ANDROID_SYSTEM_IMAGE_TAG)"
  else echo "info: SDK volume $vol not made yet (devenv emulator start downloads about 2.2 GB and unpacks about 5 GB)"; fi
  state=$(emu_container_state)
  if [ -z "$state" ] && docker image inspect "$image" >/dev/null 2>&1 </dev/null && docker volume inspect "$vol" >/dev/null 2>&1 </dev/null; then
    # The emulator's own check, inside a container: line 2 is 0 when KVM works.
    out=$(docker run --rm --device "$(emu_kvm):/dev/kvm" -v "$vol:/android/sdk:ro" --entrypoint /android/sdk/emulator/emulator \
      "$image" -accel-check 2>&1 </dev/null || true)
    if [ "$(printf '%s\n' "$out" | sed -n 2p)" = 0 ]; then echo "ok: KVM works in a container ($(printf '%s\n' "$out" | sed -n 3p))"
    else echo "fail: KVM doesn't work in a container: $(printf '%s\n' "$out" | sed -n 3p) (turn on virtualization in the firmware settings; under WSL, nested virtualization)"; fi
  fi
  case "$state" in
    '') echo "info: not running (start it when a task needs it: devenv emulator start)" ;;
    "running healthy")
      out=$(adb_hello 127.0.0.1 "$ANDROID_EMULATOR_PORT" || true)
      case "$out" in
        device) echo "ok: running; Android booted; adb answers on 127.0.0.1:$ANDROID_EMULATOR_PORT" ;;
        auth) echo "fail: running, but adb on 127.0.0.1:$ANDROID_EMULATOR_PORT asks for authorization; restart it: devenv emulator stop, then devenv emulator start" ;;
        *) echo "fail: running and booted, but nothing answers on 127.0.0.1:$ANDROID_EMULATOR_PORT; restart it: devenv emulator stop, then devenv emulator start" ;;
      esac
      ;;
    "running starting"|running) echo "info: running; Android is still booting (devenv emulator start waits for it)" ;;
    "running unhealthy") echo "fail: running, but adb in the container lost the device; restart it: devenv emulator stop, then devenv emulator start (log: docker logs $EMU_NAME)" ;;
    *) echo "fail: its container stopped ($state); see docker logs $EMU_NAME, then remove it: devenv emulator stop" ;;
  esac
  case "$(emu_policy_state)" in
    allowed) echo "ok: sandbox $CONF_SANDBOX_NAME may reach it (the network policy allows localhost:$ANDROID_EMULATOR_PORT)" ;;
    denied) echo "warn: sandboxes can't reach it: allow it once with: sbx policy allow network localhost:$ANDROID_EMULATOR_PORT" ;;
    *) have sbx && echo "info: check that sandboxes may reach it: sbx policy check network --sandbox $CONF_SANDBOX_NAME localhost:$ANDROID_EMULATOR_PORT" ;;
  esac
  return 0
}

# Why nothing answers at HOST:PORT, with the fix. From a sandbox, the proxy's
# HTTP path shows whether the network policy blocks the port: it answers a
# blocked destination with HTTP 403 and the reason.
emu_unreachable_reason() {
  local host=$1 port=$2 out
  if [ "$(detect_mode)" = sbx ]; then
    out=$(curl -sS -m 5 -w '\n%{http_code}' "http://$host:$port/" 2>/dev/null </dev/null || true)
    if [ "$(printf '%s\n' "$out" | tail -n 1)" = 403 ] && printf '%s\n' "$out" | grep -qiE 'blocked|approval'; then
      echo "the network policy doesn't let this sandbox reach localhost:$port (\"$(printf '%s\n' "$out" | head -n 1)\"); on the host, run once: sbx policy allow network localhost:$port"
      return 0
    fi
    echo "no emulator answers at $host:$port; on the host, run: devenv emulator start"
  else
    echo "no emulator answers at $host:$port; run: devenv emulator start"
  fi
}

emu_env_report() {
  local cur host hello
  if ! android_supported; then echo "info: no adb on $(uname -m): Google publishes platform-tools for x86_64 Linux only"; return 0; fi
  cur=$(adb_installed_version)
  if [ "$cur" = "$ANDROID_PLATFORM_TOOLS_VERSION" ]; then echo "ok: adb $cur"
  else echo "fail: adb ${cur:-missing} (pinned $ANDROID_PLATFORM_TOOLS_VERSION); run: $DEVENV_ROOT/provision.sh"; fi
  host=$(emu_host)
  if ! hello=$(adb_hello "$host" "$ANDROID_EMULATOR_PORT"); then
    echo "info: emulator not reachable: $(emu_unreachable_reason "$host" "$ANDROID_EMULATOR_PORT")"
  elif [ "$hello" = device ]; then
    echo "ok: an emulator answers at $host:$ANDROID_EMULATOR_PORT (devenv emulator connect)"
  else
    echo "warn: the emulator at $host:$ANDROID_EMULATOR_PORT asks for adb authorization; restart it on the host: devenv emulator stop, then devenv emulator start"
  fi
}

# Print a report in doctor's format; fails when it has a failure.
emu_print_report() {
  local line rc=0
  while IFS= read -r line; do
    case "$line" in
      "ok: "*) _pass "${line#ok: }" ;;
      "warn: "*) _wrn "${line#warn: }" ;;
      "fail: "*) _fail "${line#fail: }"; rc=1 ;;
      "info: "*) _info "note  ${line#info: }" ;;
    esac
  done
  return "$rc"
}

emu_start() {
  local image vol out
  emu_host_ready start
  image=$(emu_image) vol=$(emu_sdk_volume)
  case "$(emu_container_state)" in
    running*)
      ok "the emulator is already running"
      [ "$(docker inspect -f '{{.Config.Image}}' "$EMU_NAME" 2>/dev/null </dev/null)" = "$image" ] \
        || warn "it runs an older image; for the current one: devenv emulator stop, then devenv emulator start"
      ;;
    *)
      docker rm -f "$EMU_NAME" >/dev/null 2>&1 </dev/null || true
      emu_ensure_image "$image"
      emu_ensure_sdk "$image" "$vol"
      if ! out=$(docker run -d --name "$EMU_NAME" --init --device "$(emu_kvm):/dev/kvm" \
            -p "127.0.0.1:$ANDROID_EMULATOR_PORT:$EMU_CONTAINER_PORT" -v "$vol:/android/sdk" \
            -e "EMULATOR_MEMORY=$ANDROID_EMULATOR_MEMORY" -e "EMULATOR_CORES=$ANDROID_EMULATOR_CORES" \
            --label "$EMU_LABEL=container" "$image" 2>&1 </dev/null); then
        docker rm -f "$EMU_NAME" >/dev/null 2>&1 </dev/null || true
        case "$out" in
          *"already allocated"*|*"address already in use"*)
            die "port $ANDROID_EMULATOR_PORT on 127.0.0.1 is taken; free it, or pick another one: ANDROID_EMULATOR_PORT=<port> devenv emulator start (the policy rule and every connect need the same port)" ;;
        esac
        die "docker run failed: $(printf '%s\n' "$out" | tail -n 1)"
      fi
      log "emulator started (container $EMU_NAME, ${ANDROID_EMULATOR_MEMORY} MB, $ANDROID_EMULATOR_CORES cores); waiting for Android to boot, usually 1 to 3 minutes"
      ;;
  esac
  emu_wait_boot
  if [ "$(adb_hello 127.0.0.1 "$ANDROID_EMULATOR_PORT" || true)" = device ]; then ok "adb answers on 127.0.0.1:$ANDROID_EMULATOR_PORT"
  else warn "Android booted, but adb doesn't answer on 127.0.0.1:$ANDROID_EMULATOR_PORT (devenv emulator status)"; fi
  case "$(emu_policy_state)" in
    allowed) ok "sandbox $CONF_SANDBOX_NAME may reach it (the network policy allows localhost:$ANDROID_EMULATOR_PORT)" ;;
    denied) warn "sandboxes can't reach it yet. Allow it once with: sbx policy allow network localhost:$ANDROID_EMULATOR_PORT" ;;
    *) have sbx && log "check that sandboxes may reach it: sbx policy check network --sandbox $CONF_SANDBOX_NAME localhost:$ANDROID_EMULATOR_PORT" ;;
  esac
  log "in the sandbox: devenv emulator run -- ./gradlew connectedDebugAndroidTest (or devenv emulator connect)"
  log "it uses about 5 GB of memory while it runs; stop it when you're done: devenv emulator stop"
}

emu_stop() {
  local p
  emu_host_only stop
  p=$(emu_docker_problem)
  [ -z "$p" ] || die "$p"
  if [ -z "$(emu_container_state)" ]; then ok "the emulator is not running"; return 0; fi
  docker stop -t 20 "$EMU_NAME" >/dev/null 2>&1 </dev/null || true
  docker rm -f "$EMU_NAME" >/dev/null 2>&1 </dev/null || die "could not remove the container $EMU_NAME"
  ok "emulator stopped; its image and SDK volume stay for the next start (devenv emulator clean removes them)"
}

emu_clean() {
  local p
  emu_host_only clean
  p=$(emu_docker_problem)
  [ -z "$p" ] || die "$p"
  docker rm -f "$EMU_NAME" >/dev/null 2>&1 </dev/null && log "removed the container $EMU_NAME" || true
  emu_remove_old image ''
  emu_remove_old sdk ''
  rm -rf "$(emu_cache)"
  ok "removed the emulator's container, images, SDK volumes and downloads"
}

emu_prop() { adb -s "$1" shell getprop "$2" 2>/dev/null </dev/null | tr -d '\r'; }

# Connect this machine's adb server to the emulator; prints the serial.
emu_connect() {
  local host addr hello out
  android_supported || die "no adb on $(uname -m): Google publishes platform-tools for x86_64 Linux only"
  have adb || die "adb is not installed; run: $DEVENV_ROOT/provision.sh"
  host=$(emu_host)
  addr="$host:$ANDROID_EMULATOR_PORT"
  hello=$(adb_hello "$host" "$ANDROID_EMULATOR_PORT") || die "$(emu_unreachable_reason "$host" "$ANDROID_EMULATOR_PORT")"
  [ "$hello" = device ] \
    || die "the emulator at $addr asks for adb authorization, which devenv's emulator skips; restart it on the host: devenv emulator stop, then devenv emulator start"
  if [ "$(adb -s "$addr" get-state 2>/dev/null </dev/null)" != device ]; then
    # A connection that went away stays listed as offline; start afresh.
    adb disconnect "$addr" >/dev/null 2>&1 </dev/null || true
    out=$(timeout 30 adb connect "$addr" 2>&1 </dev/null || true)
    case "$out" in *"connected to $addr"*) ;; *) die "adb connect $addr failed: ${out:-no answer}" ;; esac
    timeout 30 adb -s "$addr" wait-for-device >/dev/null 2>&1 </dev/null \
      || die "adb connected to $addr, but the device stayed offline; try again, or restart the emulator on the host"
  fi
  [ "$(emu_prop "$addr" sys.boot_completed)" = 1 ] \
    || die "Android on $addr is still booting; wait until devenv emulator start on the host says it booted"
  ok "connected to the emulator: $addr (Android $(emu_prop "$addr" ro.build.version.release), API $(emu_prop "$addr" ro.build.version.sdk))"
  printf '%s\n' "$addr"
}

# Connect, then run a command against the emulator, one run at a time: the
# emulator is shared by every worker in the sandbox, and test runs that
# overlap install over each other.
emu_run() {
  local serial lock rc=0
  [ "${1:-}" = -- ] && shift
  [ $# -gt 0 ] || die "usage: devenv emulator run -- COMMAND [ARGS...]"
  serial=$(emu_connect)
  lock="${XDG_RUNTIME_DIR:-/tmp}/$EMU_LOCK"
  exec 9>>"$lock"
  if ! flock -n 9; then
    log "another run is using the emulator; waiting for it to finish"
    flock 9
  fi
  log "running with ANDROID_SERIAL=$serial: $*"
  # 9>&- keeps the lock from long-lived children, such as a Gradle daemon.
  ANDROID_SERIAL=$serial "$@" 9>&- || rc=$?
  exec 9>&-
  return "$rc"
}

emu_status() {
  echo "Android emulator"
  if [ "$(detect_mode)" = sbx ]; then emu_print_report < <(emu_env_report)
  else emu_print_report < <(emu_host_report); fi
}

cmd_emulator() {
  local sub=${1:-}
  [ $# -gt 0 ] && shift
  resolve_paths
  export PATH="$LOCAL_BIN:$PATH"
  case "$sub" in
    start) emu_start ;;
    stop) emu_stop ;;
    status) emu_status ;;
    clean) emu_clean ;;
    connect) emu_connect ;;
    run) emu_run "$@" ;;
    ''|-h|--help|help) emu_usage ;;
    *) emu_usage >&2; die "unknown emulator command: $sub" ;;
  esac
}
