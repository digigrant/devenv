#!/usr/bin/env bash
# devenv emulator against fakes (spec §6.14): tests/fakes/{docker,adb,sbx}
# come first on PATH, with a temporary HOME, a stand-in KVM device, a copy of
# this working tree whose SDK pins are the sha256s of small dummy zips (put in
# the download cache, so nothing is downloaded), and a tiny adbd (python3) on
# 127.0.0.1 standing in for the emulator's published adb port. No real Docker,
# KVM, emulator, adb server or sbx is touched.
#   tests/emulator.sh
# pass and fail always succeed, so `test && pass || fail` is a safe if/else,
# and single-quoted $ text is meant literally (commands for the tested shell,
# messages that print $USER).
# shellcheck disable=SC2015,SC2016
set -euo pipefail

ROOT=$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)
W=$(mktemp -d)
ADBD_PID=''
cleanup() { [ -z "$ADBD_PID" ] || kill "$ADBD_PID" 2>/dev/null || true; rm -rf "$W"; }
trap cleanup EXIT
mkdir -p "$W/home" "$W/tmp" "$W/log" "$W/run" "$W/xdg"
(cd "$ROOT" && git ls-files -co --exclude-standard -z | xargs -0 cp --parents -t "$W/run" 2>/dev/null) \
  || cp -r "$ROOT/." "$W/run"
rm -rf "$W/run/dev"
DEV=$W/run/bin/devenv
touch "$W/kvm"
export FAKE_LOG=$W/log
PORT=$(python3 -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])')
CACHE=$W/home/.cache/devenv/android-emulator

# Dummy zips, and pins that match them.
dummy_zips() {
  local z
  mkdir -p "$CACHE"
  for z in emulator system-image platform-tools; do printf 'dummy %s\n' "$z" > "$CACHE/$z.zip"; done
}
dummy_zips
sed -i -e "s/^ANDROID_EMULATOR_SHA256=.*/ANDROID_EMULATOR_SHA256=$(sha256sum < "$CACHE/emulator.zip" | cut -d' ' -f1)/" \
  -e "s/^ANDROID_SYSTEM_IMAGE_SHA256=.*/ANDROID_SYSTEM_IMAGE_SHA256=$(sha256sum < "$CACHE/system-image.zip" | cut -d' ' -f1)/" \
  -e "s/^ANDROID_PLATFORM_TOOLS_SHA256=.*/ANDROID_PLATFORM_TOOLS_SHA256=$(sha256sum < "$CACHE/platform-tools.zip" | cut -d' ' -f1)/" \
  "$W/run/versions.env"

fails=0
pass() { printf '  ok    %s\n' "$*"; }
fail() { printf '  FAIL  %s\n' "$*"; fails=$((fails + 1)); }

# run VAR=VALUE... -- ARGS: devenv on the host (no sandbox variables), with
# the fakes first on PATH. Sets OUT, ERR, RC.
run() {
  local envs=()
  while [ "$1" != -- ]; do envs+=("$1"); shift; done
  shift
  : > "$FAKE_LOG/argv"
  RC=0
  env -i HOME="$W/home" TMPDIR="$W/tmp" PATH="$ROOT/tests/fakes:/usr/local/bin:/usr/bin:/bin" \
    XDG_RUNTIME_DIR="$W/xdg" FAKE_LOG="$FAKE_LOG" FAKE_PORT="$PORT" DEVENV_KVM_DEVICE="$W/kvm" \
    DEVENV_EMULATOR_POLL=0 ANDROID_EMULATOR_PORT="$PORT" "${envs[@]}" \
    bash "$DEV" "$@" > "$W/out" 2> "$W/err" < /dev/null || RC=$?
  OUT=$(cat "$W/out"); ERR=$(cat "$W/err")
}
called() { grep -qF -- "$1" "$FAKE_LOG/argv"; }

# adbd MODE: answer adb's CNXN on 127.0.0.1:$PORT with CNXN (device) or AUTH
# (auth), the way the emulator's adbd does; stop it with no argument.
adbd() {
  [ -z "$ADBD_PID" ] || { kill "$ADBD_PID" 2>/dev/null || true; wait "$ADBD_PID" 2>/dev/null || true; ADBD_PID=''; }
  [ -n "${1:-}" ] || return 0
  python3 -c '
import socket, struct, sys, threading
mode, port = sys.argv[1], int(sys.argv[2])
srv = socket.socket(); srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
srv.bind(("127.0.0.1", port)); srv.listen(8)
def serve(c):
    head = c.recv(24)
    if len(head) == 24 and head[:4] == b"CNXN":
        cmd = b"CNXN" if mode == "device" else b"AUTH"
        body = b"device::ro.product.model=sdk_gphone64_x86_64;" if mode == "device" else b"x" * 20
        c.sendall(cmd + struct.pack("<5I", 0x01000001, 4096, len(body), 0, struct.unpack("<I", cmd)[0] ^ 0xffffffff) + body)
    c.close()
while True:
    c, _ = srv.accept()
    threading.Thread(target=serve, args=(c,), daemon=True).start()
' "$1" "$PORT" &
  ADBD_PID=$!
  for _ in $(seq 50); do (exec 3<>"/dev/tcp/127.0.0.1/$PORT") 2>/dev/null && return 0; sleep 0.1; done
  echo "the fake adbd did not start" >&2; exit 1
}

echo "host: start"
adbd device
run -- emulator start
if [ "$RC" = 0 ] && printf '%s' "$ERR" | grep -q 'Android booted' && printf '%s' "$ERR" | grep -qF "adb answers on 127.0.0.1:$PORT"; then
  pass "start: builds, unpacks, starts, waits for the boot, checks adb"
else fail "start: exit $RC, stderr: $ERR"; fi
called 'docker build -q -t devenv-android-emulator:' && called '--label devenv.android-emulator=image --build-arg BASE_IMAGE=ubuntu:24.04@sha256:' \
  && pass "the image is built from the pinned base image" || fail "docker build: $(grep 'docker build' "$FAKE_LOG/argv")"
vol=$(sed -n 's/^docker volume create --label devenv.android-emulator=sdk //p' "$FAKE_LOG/argv")
[[ $vol =~ ^devenv-android-sdk-api36-[0-9a-f]{12}$ ]] \
  && called "docker run --rm -v $vol:/android/sdk -v $CACHE:/zips:ro devenv-android-emulator:" \
  && called '--unpack system-images/android-36/google_apis' \
  && pass "the SDK is unpacked into its own volume ($vol)" || fail "SDK volume '$vol': $(grep -e 'volume' -e 'unpack' "$FAKE_LOG/argv")"
[ -z "$(ls -A "$CACHE")" ] && pass "the downloads are deleted once unpacked" || fail "left in the cache: $(ls "$CACHE")"
line=$(grep '^docker run -d' "$FAKE_LOG/argv" || true)
if printf '%s' "$line" | grep -qF -- "--name devenv-android-emulator --init --device $W/kvm:/dev/kvm -p 127.0.0.1:$PORT:6555 -v $vol:/android/sdk -e EMULATOR_MEMORY=4096 -e EMULATOR_CORES=4"; then
  pass "docker run: /dev/kvm, adb published on 127.0.0.1 only, the SDK volume, memory and cores"
else fail "docker run: ${line:-none}"; fi
printf '%s' "$ERR" | grep -qF "sandboxes can't reach it yet. Allow it once with: sbx policy allow network localhost:$PORT" \
  && called "sbx policy check network --sandbox dev localhost:$PORT" \
  && pass "no policy rule yet: prints the exact sbx policy allow command" || fail "policy hint missing: $ERR"

run -- emulator start
[ "$RC" = 0 ] && printf '%s' "$ERR" | grep -q 'already running' && ! called 'docker run -d' && ! called 'docker build' \
  && pass "start again: reuses the running emulator" || fail "second start: exit $RC, stderr: $ERR"

echo "host: status and doctor"
run FAKE_SBX_POLICY=allowed -- emulator status
if [ "$RC" = 0 ] && printf '%s' "$OUT" | grep -qF "ok    running; Android booted; adb answers on 127.0.0.1:$PORT" \
   && printf '%s' "$OUT" | grep -qF "ok    sandbox dev may reach it (the network policy allows localhost:$PORT)" \
   && printf '%s' "$OUT" | grep -qF "ok    SDK volume $vol (Android API 36, google_apis)"; then
  pass "status: running, booted, adb answers, the policy allows it"
else fail "status: exit $RC, output: $OUT"; fi
run -- doctor --host
printf '%s\n' "$OUT" | sed -n '/^Android emulator/,/^Operating rule/p' | grep -qF "warn  sandboxes can't reach it: allow it once with: sbx policy allow network localhost:$PORT" \
  && pass "doctor --host: an Android emulator section with the policy fix" || fail "doctor's emulator section: $(printf '%s\n' "$OUT" | sed -n '/^Android emulator/,/^Operating rule/p')"
adbd
run -- emulator status
[ "$RC" = 1 ] && printf '%s' "$OUT" | grep -qF "FAIL  running and booted, but nothing answers on 127.0.0.1:$PORT" \
  && pass "status: a booted emulator that doesn't answer is a failure" || fail "status without adbd: exit $RC, output: $OUT"

echo "host: stop and restart"
run -- emulator stop
[ "$RC" = 0 ] && called 'docker stop -t 20 devenv-android-emulator' && called 'docker rm -f devenv-android-emulator' \
  && pass "stop: stops and removes the container" || fail "stop: exit $RC, stderr: $ERR"
run -- emulator status
[ "$RC" = 0 ] && printf '%s' "$OUT" | grep -qF 'note  not running (start it when a task needs it: devenv emulator start)' \
  && printf '%s' "$OUT" | grep -qF 'ok    KVM works in a container (KVM (version 12) is installed and usable.)' \
  && pass "status when stopped: not running, and KVM checked in a container" || fail "status when stopped: exit $RC, output: $OUT"
run FAKE_DOCKER_ACCEL=3 -- emulator status
[ "$RC" = 1 ] && printf '%s' "$OUT" | grep -qF "FAIL  KVM doesn't work in a container: KVM requires a CPU that supports vmx or svm" \
  && pass "status: KVM that fails in a container is a failure" || fail "status with a failing accel-check: exit $RC, output: $OUT"
run -- emulator stop
[ "$RC" = 0 ] && printf '%s' "$ERR" | grep -q 'the emulator is not running' && pass "stop when stopped: nothing to do" || fail "stop again: exit $RC, stderr: $ERR"
adbd device
run -- emulator start
[ "$RC" = 0 ] && called 'docker run -d' && ! called 'docker build' && ! called 'docker volume create' \
  && pass "start after stop: reuses the image and SDK volume" || fail "restart: exit $RC, stderr: $ERR"
run -- emulator stop

echo "host: failures"
run FAKE_DOCKER_RUN_FAIL=port -- emulator start
[ "$RC" = 1 ] && printf '%s' "$ERR" | grep -qF "port $PORT on 127.0.0.1 is taken" && called 'docker rm -f devenv-android-emulator' \
  && pass "a taken port: says so, and removes the half-made container" || fail "taken port: exit $RC, stderr: $ERR"
run FAKE_DOCKER_BOOT=exit -- emulator start
[ "$RC" = 1 ] && printf '%s' "$ERR" | grep -q 'x86_64 emulation currently requires hardware acceleration' \
  && printf '%s' "$ERR" | grep -q 'the emulator stopped while booting (exited)' \
  && pass "an emulator that dies while booting: shows its log" || fail "boot failure: exit $RC, stderr: $ERR"
run DEVENV_KVM_DEVICE="$W/no-kvm" -- emulator start
[ "$RC" = 1 ] && printf '%s' "$ERR" | grep -qF "$W/no-kvm is missing: this machine has no KVM" && ! called 'docker run' \
  && pass "no KVM: stops before docker" || fail "no KVM: exit $RC, stderr: $ERR"
run FAKE_DOCKER_INFO=denied -- emulator start
[ "$RC" = 1 ] && printf '%s' "$ERR" | grep -qF 'permission denied on the Docker socket; run: sudo usermod -aG docker $USER' \
  && pass "no access to Docker: the usermod fix" || fail "docker denied: exit $RC, stderr: $ERR"
run FAKE_DOCKER_OS='Docker Desktop' -- emulator start
[ "$RC" = 1 ] && printf '%s' "$ERR" | grep -q 'Docker Desktop, whose containers get no /dev/kvm' \
  && pass "Docker Desktop: refused, with the reason" || fail "Docker Desktop: exit $RC, stderr: $ERR"
run ANDROID_EMULATOR_PORT=80 -- emulator start
[ "$RC" = 1 ] && printf '%s' "$ERR" | grep -qF "ANDROID_EMULATOR_PORT in devenv.conf must be a number from 1024 to 65535, not '80'" \
  && pass "a bad port setting: refused" || fail "bad port: exit $RC, stderr: $ERR"
run SANDBOX_NAME=dev IS_SANDBOX=1 WORKSPACE_DIR="$W/ws" -- emulator start
[ "$RC" = 1 ] && printf '%s' "$ERR" | grep -q 'runs on the host, not in a sandbox' && pass "start inside a sandbox: refused" || fail "start in a sandbox: exit $RC, stderr: $ERR"

echo "host: new pins, clean"
dummy_zips
sed -i 's/^ANDROID_SYSTEM_IMAGE_ZIP=.*/ANDROID_SYSTEM_IMAGE_ZIP=x86_64-36_r08.zip/' "$W/run/versions.env"
run -- emulator start
[ "$RC" = 0 ] && called 'docker volume create' && ! called 'docker build' && printf '%s' "$ERR" | grep -qF "removed the SDK volume $vol" \
  && pass "a new system image pin: a new SDK volume, the old one removed" || fail "new pin: exit $RC, stderr: $ERR"
run -- emulator clean
[ "$RC" = 0 ] && [ -z "$(find "$FAKE_LOG/docker/images" "$FAKE_LOG/docker/volumes" -type f)" ] && [ ! -e "$CACHE" ] && [ ! -e "$FAKE_LOG/docker/container" ] \
  && pass "clean: container, images, SDK volumes and downloads removed" || fail "clean: exit $RC, left: $(ls "$FAKE_LOG/docker/images" "$FAKE_LOG/docker/volumes")"

echo "connect and run (plain mode: the emulator on 127.0.0.1)"
adbd device
run -- emulator connect
[ "$RC" = 0 ] && [ "$OUT" = "127.0.0.1:$PORT" ] && printf '%s' "$ERR" | grep -qF "connected to the emulator: 127.0.0.1:$PORT (Android 16, API 36)" \
  && called "adb connect 127.0.0.1:$PORT" && pass "connect: prints only the serial on stdout" || fail "connect: exit $RC, stdout '$OUT', stderr: $ERR"
run -- emulator connect
[ "$RC" = 0 ] && ! called 'adb connect' && pass "connect again: already connected, no new connection" || fail "connect again: exit $RC, stderr: $ERR"
run -- emulator run -- sh -c 'echo "serial=$ANDROID_SERIAL"'
[ "$RC" = 0 ] && [ "$OUT" = "serial=127.0.0.1:$PORT" ] && pass "run: the command gets ANDROID_SERIAL" || fail "run: exit $RC, stdout '$OUT', stderr: $ERR"
run -- emulator run -- sh -c 'exit 3'
[ "$RC" = 3 ] && pass "run: passes on the command's exit status" || fail "run: exit $RC, expected 3"
run -- emulator run -- sh -c 'ls -l /proc/$$/fd | grep -c devenv-android-emulator.lock || true'
[ "$RC" = 0 ] && [ "$OUT" = 0 ] && pass "run: the command doesn't inherit the lock (a Gradle daemon would keep it)" || fail "run: the command holds the lock: $OUT"
( env -i HOME="$W/home" TMPDIR="$W/tmp" PATH="$ROOT/tests/fakes:/usr/local/bin:/usr/bin:/bin" XDG_RUNTIME_DIR="$W/xdg" \
    FAKE_LOG="$FAKE_LOG" ANDROID_EMULATOR_PORT="$PORT" bash "$DEV" emulator run -- sleep 2 >/dev/null 2>&1 ) &
first=$!
sleep 1
t0=$SECONDS
run -- emulator run -- true
wait "$first" || true
[ "$RC" = 0 ] && printf '%s' "$ERR" | grep -q 'another run is using the emulator; waiting for it to finish' && [ $((SECONDS - t0)) -ge 1 ] \
  && pass "run: a second run waits for the first" || fail "concurrent runs: exit $RC, stderr: $ERR"
adb_state=$FAKE_LOG/adb/127.0.0.1:$PORT
rm -f "$adb_state"
run FAKE_ADB_BOOTED=0 -- emulator connect
[ "$RC" = 1 ] && printf '%s' "$ERR" | grep -q 'is still booting' && pass "connect while Android boots: says to wait" || fail "connect while booting: exit $RC, stderr: $ERR"
adbd auth
run -- emulator connect
[ "$RC" = 1 ] && printf '%s' "$ERR" | grep -q 'asks for adb authorization' && pass "an emulator that asks for authorization: restart it" || fail "auth: exit $RC, stderr: $ERR"
adbd
run -- emulator connect
[ "$RC" = 1 ] && printf '%s' "$ERR" | grep -qF "no emulator answers at 127.0.0.1:$PORT; run: devenv emulator start" && [ -z "$OUT" ] \
  && pass "nothing answers: start it" || fail "nothing answers: exit $RC, stderr: $ERR"

echo "sandbox side"
run SANDBOX_NAME=dev IS_SANDBOX=1 WORKSPACE_DIR="$W/ws" -- emulator status
printf '%s' "$OUT" | grep -qF 'ok    adb 37.0.1' && printf '%s' "$OUT" | grep -qE 'note  emulator not reachable: |ok    an emulator answers at host.docker.internal' \
  && pass "status in a sandbox: adb, and whether the emulator answers at host.docker.internal" || fail "sandbox status: exit $RC, output: $OUT"
if [ -n "${SANDBOX_NAME:-}" ] && [ -n "${http_proxy:-}" ]; then
  # Inside a Docker Sandbox, with the real curl: the sandbox's own proxy says
  # whether the network policy allows the port.
  run SANDBOX_NAME=dev IS_SANDBOX=1 WORKSPACE_DIR="$W/ws" PATH=/usr/local/bin:/usr/bin:/bin http_proxy="$http_proxy" ANDROID_EMULATOR_PORT=15555 -- emulator status
  line=$(printf '%s\n' "$OUT" | grep -E '^  (note|ok|warn) .*(emulator|15555)' || true)
  printf '%s' "$line" | grep -qE "doesn't let this sandbox reach localhost:15555 .*; on the host, run once: sbx policy allow network localhost:15555|no emulator answers at host.docker.internal:15555; on the host, run: devenv emulator start|an emulator answers at host.docker.internal:15555" \
    && pass "live, through this sandbox's proxy:${line#  note  emulator not reachable:}" || fail "live status: exit $RC, output: $OUT"
fi

echo
if [ "$fails" = 0 ]; then echo "emulator: PASS"; else echo "emulator: FAIL ($fails)"; exit 1; fi
