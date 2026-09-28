#!/usr/bin/env bash
# Entrypoint of the devenv Android emulator image (android/emulator/Dockerfile).
# Runs as root inside the container. Not meant to be run anywhere else.
#
#   launch.sh                    start the emulator (docker run --init --device /dev/kvm)
#   launch.sh --unpack SYSDIR    unpack the SDK zips in /zips into /android/sdk,
#                                the system image under SYSDIR (e.g.
#                                system-images/android-36/google_apis)
#
# The SDK is a Docker volume at /android/sdk, filled once by --unpack
# (lib/cmd/emulator.sh). Every start is a fresh device: the AVD is written
# here, inside the container, and its data wiped. The emulator runs headless
# (no window, software GPU, no audio) and needs /dev/kvm. adb authorization is
# skipped (-skip-adb-auth), so any client that reaches the port can use the
# device: devenv publishes it on the host's 127.0.0.1 only, and sandboxes
# reach it through one network policy rule.
#
# Environment (set by `devenv emulator start` from devenv.conf):
#   EMULATOR_MEMORY  guest RAM in MB (default 4096, the least this image boots with)
#   EMULATOR_CORES   guest CPU cores (default 4)
set -euo pipefail

sdk=$ANDROID_SDK_ROOT

# --unpack: emulator.zip, platform-tools.zip and system-image.zip from /zips.
# .devenv-sdk, written last, marks a complete SDK and names its system image.
if [ "${1:-}" = --unpack ]; then
  sysdir=${2:?launch.sh --unpack needs the system image directory}
  find "$sdk" -mindepth 1 -delete
  mkdir -p "$sdk/$sysdir" "$sdk/platforms"
  unzip -q /zips/emulator.zip -d "$sdk"
  unzip -q /zips/platform-tools.zip -d "$sdk"
  unzip -q /zips/system-image.zip -d "$sdk/$sysdir"
  test -x "$sdk/emulator/emulator" && test -x "$sdk/platform-tools/adb" && test -f "$sdk/$sysdir/x86_64/system.img"
  printf 'SYSTEM_IMAGE_DIR=%s/x86_64\n' "$sysdir" > "$sdk/.devenv-sdk"
  echo "devenv: SDK unpacked ($(du -sh "$sdk" | cut -f1))"
  exit 0
fi

avd=$ANDROID_AVD_HOME
adb=$sdk/platform-tools/adb
memory=${EMULATOR_MEMORY:-4096}
cores=${EMULATOR_CORES:-4}
marker=/tmp/devenv-booted
rm -f "$marker"

sysdir=$(sed -n 's/^SYSTEM_IMAGE_DIR=//p' "$sdk/.devenv-sdk" 2>/dev/null || true)
if [ -z "$sysdir" ]; then
  echo "devenv: error: no SDK in $sdk (devenv emulator start unpacks one into the volume)" >&2
  exit 1
fi
props=$sdk/$sysdir/source.properties
echo "devenv: $("$sdk/emulator/emulator" -version 2>/dev/null | head -n 1)"
echo "devenv: system image $sysdir revision $(sed -n 's/^Pkg.Revision=//p' "$props"), ${memory} MB, $cores cores"
if [ ! -w /dev/kvm ]; then
  echo "devenv: error: /dev/kvm is not available in the container (docker run --device /dev/kvm)" >&2
  exit 1
fi

# The AVD: a phone-sized, headless device on the SDK's one system image.
mkdir -p "$avd/devenv.avd"
printf 'avd.ini.encoding=UTF-8\npath=%s/devenv.avd\n' "$avd" > "$avd/devenv.ini"
cat > "$avd/devenv.avd/config.ini" <<EOF
AvdId=devenv
avd.ini.displayname=devenv
avd.ini.encoding=UTF-8
PlayStore.enabled=false
abi.type=x86_64
hw.cpu.arch=x86_64
image.sysdir.1=$sysdir/
tag.id=$(sed -n 's/^SystemImage.TagId=//p' "$props")
hw.ramSize=$memory
hw.cpu.ncore=$cores
disk.dataPartition.size=6G
hw.lcd.width=1080
hw.lcd.height=2400
hw.lcd.density=420
hw.keyboard=yes
hw.mainKeys=no
hw.gpu.enabled=yes
hw.gpu.mode=swiftshader_indirect
hw.audioInput=no
hw.audioOutput=no
hw.camera.back=none
hw.camera.front=none
hw.sdCard=no
fastboot.forceColdBoot=yes
EOF

# The emulator's adb port (5557) listens on the container's loopback only;
# forward the published port to it. 6555 is outside the range adb scans for
# local emulators (5555-5585), so the adb server in here doesn't find the
# emulator a second time through this forward.
socat tcp-listen:6555,reuseaddr,fork tcp:127.0.0.1:5557 &

# Once Android has booted: turn off animations (UI tests expect that), then
# write the marker the health check looks for.
(
  "$adb" start-server >/dev/null 2>&1 || true
  until [ "$("$adb" -s emulator-5556 shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" = 1 ]; do
    sleep 3
  done
  for s in window_animation_scale transition_animation_scale animator_duration_scale; do
    "$adb" -s emulator-5556 shell settings put global "$s" 0 >/dev/null 2>&1 || true
  done
  touch "$marker"
  echo "devenv: Android booted (API $("$adb" -s emulator-5556 shell getprop ro.build.version.sdk | tr -d '\r'))"
) &

exec "$sdk/emulator/emulator" -avd devenv -ports 5556,5557 \
  -no-window -no-audio -no-boot-anim -no-snapshot -wipe-data -no-metrics \
  -skip-adb-auth -gpu swiftshader_indirect -accel on \
  -memory "$memory" -cores "$cores" \
  -qemu -append panic=1
