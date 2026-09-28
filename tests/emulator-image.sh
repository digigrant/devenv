#!/usr/bin/env bash
# The emulator's real image and SDK volume (spec §6.14), with the Docker on
# this machine: `devenv emulator start` in host mode downloads the pinned
# zips (about 2.2 GB, checked against versions.env), builds the image, unpacks
# the SDK into a volume (about 5 GB) and starts the container. Without KVM
# (e.g. inside a Docker Sandbox) a stand-in device takes /dev/kvm's place, so
# the emulator stops at its hardware checks; the test asserts it got that far:
# it found the system image and read the AVD. Then `devenv emulator clean`.
# Heavy, so `devenv test` runs it only with --emulator-image.
#   tests/emulator-image.sh
# pass and fail always succeed, so `test && pass || fail` is a safe if/else.
# shellcheck disable=SC2015
set -euo pipefail

ROOT=$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)
DOCKER=$(command -v docker) || { echo "docker is required" >&2; exit 1; }
W=$(mktemp -d)
mkdir -p "$W/home" "$W/bin"
fails=0
pass() { printf '  ok    %s\n' "$*"; }
fail() { printf '  FAIL  %s\n' "$*"; fails=$((fails + 1)); }

# Inside a Docker Sandbox, image builds reach the network only through the
# sandbox's proxy: a docker wrapper adds it to `docker build`.
cat > "$W/bin/docker" <<EOF
#!/usr/bin/env bash
if [ "\${1:-}" = build ] && [ -n "\${HTTPS_PROXY:-\${https_proxy:-}}" ]; then
  shift
  exec $DOCKER build --network host --build-arg "HTTP_PROXY=\${HTTP_PROXY:-\${http_proxy:-}}" \\
    --build-arg "http_proxy=\${http_proxy:-\${HTTP_PROXY:-}}" --build-arg "HTTPS_PROXY=\${HTTPS_PROXY:-\${https_proxy:-}}" \\
    --build-arg "https_proxy=\${https_proxy:-\${HTTPS_PROXY:-}}" "\$@"
fi
exec $DOCKER "\$@"
EOF
chmod +x "$W/bin/docker"
kvm=/dev/kvm
[ -e /dev/kvm ] || kvm=/dev/null
# It ends with `devenv emulator clean`, which removes every devenv emulator
# on this machine: refuse to run beside one.
if "$DOCKER" inspect devenv-android-emulator >/dev/null 2>&1 \
   || [ -n "$("$DOCKER" image ls -q --filter label=devenv.android-emulator=image)$("$DOCKER" volume ls -q --filter label=devenv.android-emulator=sdk)" ]; then
  echo "a devenv emulator (container, image or SDK volume) exists here; this test would remove it. Run devenv emulator clean first." >&2
  exit 1
fi

devenv() {
  env -u IS_SANDBOX -u SANDBOX_NAME -u WORKSPACE_DIR HOME="$W/home" PATH="$W/bin:$PATH" \
    DEVENV_KVM_DEVICE="$kvm" DEVENV_EMULATOR_BOOT_TIMEOUT=600 "$ROOT/bin/devenv" "$@"
}
cleanup() { devenv emulator clean >/dev/null 2>&1 || true; rm -rf "$W"; }
trap cleanup EXIT

echo "== devenv emulator start (KVM device: $kvm)"
rc=0
devenv emulator start > "$W/start.log" 2>&1 || rc=$?
sed 's/^/    /' "$W/start.log" | tail -n 15
"$DOCKER" image ls --filter label=devenv.android-emulator=image --format '{{.Repository}}:{{.Tag}} {{.Size}}' | grep -q . \
  && pass "image built: $("$DOCKER" image ls --filter label=devenv.android-emulator=image --format '{{.Repository}}:{{.Tag}} ({{.Size}})')" \
  || fail "no emulator image"
vol=$("$DOCKER" volume ls --filter label=devenv.android-emulator=sdk --format '{{.Name}}' | head -n 1)
[ -n "$vol" ] && "$DOCKER" run --rm -v "$vol:/sdk:ro" --entrypoint cat "$("$DOCKER" image ls --filter label=devenv.android-emulator=image --format '{{.Repository}}:{{.Tag}}' | head -n 1)" /sdk/.devenv-sdk \
  | grep -qx 'SYSTEM_IMAGE_DIR=system-images/android-[0-9.]*/[a-z_0-9]*/x86_64' \
  && pass "SDK volume $vol unpacked and complete" || fail "SDK volume ${vol:-missing}"
logs=$("$DOCKER" logs devenv-android-emulator 2>&1 || true)
printf '%s\n' "$logs" | grep -q 'Found systemPath /android/sdk/system-images/' && pass "the emulator found the system image" || fail "the emulator did not find the system image"
if [ "$kvm" = /dev/kvm ]; then
  [ "$rc" = 0 ] && grep -q 'Android booted' "$W/start.log" && pass "Android booted" || fail "no boot with KVM (exit $rc)"
else
  printf '%s\n' "$logs" | grep -qE 'x86_64 emulation currently requires hardware acceleration|does not have enough disk space to run avd' \
    && [ "$rc" != 0 ] && grep -q 'the emulator stopped while booting' "$W/start.log" \
    && pass "without KVM it stops at its hardware checks, and start reports it" || { fail "without KVM: exit $rc"; printf '%s\n' "$logs" | tail -n 20; }
fi
[ -z "$(ls -A "$W/home/.cache/devenv/android-emulator" 2>/dev/null)" ] && pass "downloads deleted after unpacking" || fail "downloads left in the cache"

echo "== devenv emulator clean"
devenv emulator clean > "$W/clean.log" 2>&1 || true
[ -z "$("$DOCKER" image ls -q --filter label=devenv.android-emulator=image)" ] && [ -z "$("$DOCKER" volume ls -q --filter label=devenv.android-emulator=sdk)" ] \
  && ! "$DOCKER" inspect devenv-android-emulator >/dev/null 2>&1 && pass "clean removed the container, image and SDK volume" || fail "clean left something: $(cat "$W/clean.log")"

echo
if [ "$fails" = 0 ]; then echo "emulator image: PASS"; else echo "emulator image: FAIL ($fails)"; exit 1; fi
