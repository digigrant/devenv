# The devenv Android emulator image, built on the host by
# `devenv emulator start` (lib/cmd/emulator.sh). It follows the Android
# emulator team's container recipe (github.com/google/android-emulator-
# container-scripts): a headless emulator whose adb port (loopback only) socat
# forwards to the container's port 6555.
#
# The image holds only the runtime libraries and launch.sh. The Android SDK
# (the emulator, one system image and platform-tools, about 5 GB unpacked)
# lives in a Docker volume mounted at /android/sdk: `devenv emulator start`
# downloads the pinned zips, checks them against versions.env, and has this
# image unpack them into the volume (launch.sh --unpack). Keeping the SDK out
# of the image layers keeps the build small and leaves no multi-GB build
# context or build cache behind.
#
# Build argument: BASE_IMAGE, ubuntu pinned by digest (ANDROID_EMULATOR_BASE_IMAGE).
ARG BASE_IMAGE=base-image-build-arg-is-required
FROM ${BASE_IMAGE}
# The emulator's runtime libraries (headless, software GPU), socat, and unzip
# for --unpack.
RUN apt-get update -qq \
 && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends \
      libdbus-1-3 libfontconfig1 libgl1 libnss3 libpulse0 libx11-6 libx11-xcb1 \
      libxcb1 libxcomposite1 libxcursor1 libxdamage1 libxext6 libxfixes3 libxi6 \
      libxkbfile1 libxrandr2 libxrender1 libxtst6 zlib1g socat unzip >/dev/null \
 && rm -rf /var/lib/apt/lists/*
COPY launch.sh /android/launch.sh
ENV ANDROID_SDK_ROOT=/android/sdk \
    ANDROID_HOME=/android/sdk \
    ANDROID_AVD_HOME=/android/avd
# 6555 is adb (forwarded to the emulator's own adb port 5557). The console
# (5556) and gRPC stay inside the container.
EXPOSE 6555
# Healthy once Android has booted (launch.sh writes the marker) and adb in
# the container still sees the device.
HEALTHCHECK --interval=10s --timeout=10s --start-period=15m --retries=3 \
  CMD test -f /tmp/devenv-booted && /android/sdk/platform-tools/adb -s emulator-5556 get-state | grep -qx device
ENTRYPOINT ["bash", "/android/launch.sh"]
