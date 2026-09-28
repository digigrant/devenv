# shellcheck shell=bash
# Android: adb (Google's platform-tools) in the sandbox and in plain mode, and
# the adb handshake probe that `devenv emulator` and `devenv doctor` use.
# Needs lib/common.sh, load_config and resolve_paths.

ANDROID_REPO_URL=https://dl.google.com/android/repository

# Google publishes platform-tools and the emulator for x86_64 Linux only.
android_supported() { [ "$(uname -m)" = x86_64 ]; }

# devenv's Android SDK: platform-tools only. It is ANDROID_HOME unless one is
# already set, so a project can add SDK packages to it with sdkmanager.
android_sdk_dir() { printf '%s' "$HOME/.local/share/android-sdk"; }

# "Version 37.0.1-15733141" from `adb --version` → 37.0.1
_adb_version_of() { "$1" --version 2>/dev/null | sed -n 's/^Version \([0-9][0-9.]*\).*/\1/p' | head -n 1; }

# Version of the adb on PATH (or devenv's), or empty when there is none.
adb_installed_version() {
  local exe
  exe=$(command -v adb 2>/dev/null) || exe="$LOCAL_BIN/adb"
  [ -x "$exe" ] || return 0
  _adb_version_of "$exe" || true
}

# Install the pinned platform-tools into the SDK directory and link adb into
# LOCAL_BIN. Skipped when the installed copy matches the pin.
install_platform_tools() {
  local sdk cur tmp url
  if ! android_supported; then
    log "adb: Google publishes platform-tools for x86_64 Linux only; skipped on $(uname -m)"
    return 0
  fi
  sdk=$(android_sdk_dir)
  cur=$(_adb_version_of "$sdk/platform-tools/adb" || true)
  if [ "$cur" != "$ANDROID_PLATFORM_TOOLS_VERSION" ]; then
    have unzip || die "unzip is missing; run: sudo apt-get install -y unzip"
    tmp=$(mktemp -d)
    url="$ANDROID_REPO_URL/platform-tools_r$ANDROID_PLATFORM_TOOLS_VERSION-linux.zip"
    fetch_verified "$url" "$ANDROID_PLATFORM_TOOLS_SHA256" "$tmp/platform-tools.zip"
    unzip -q "$tmp/platform-tools.zip" -d "$tmp"
    mkdir -p "$sdk"
    rm -rf "$sdk/platform-tools.devenv-old"
    [ -e "$sdk/platform-tools" ] && mv "$sdk/platform-tools" "$sdk/platform-tools.devenv-old"
    mv "$tmp/platform-tools" "$sdk/platform-tools"
    rm -rf "$sdk/platform-tools.devenv-old" "$tmp"
  fi
  mkdir -p "$LOCAL_BIN"
  [ "$(readlink "$LOCAL_BIN/adb" 2>/dev/null)" = "$sdk/platform-tools/adb" ] || ln -sfn "$sdk/platform-tools/adb" "$LOCAL_BIN/adb"
  hash -r
  if [ "$cur" = "$ANDROID_PLATFORM_TOOLS_VERSION" ]; then ok "adb $cur (already installed)"
  else ok "adb $ANDROID_PLATFORM_TOOLS_VERSION installed in $sdk/platform-tools${cur:+ (was $cur)}"; fi
}

# adb_hello HOST PORT: open an adb connection the way an adb client does (a
# CNXN message) and print what answers: "device" when adbd accepts it, "auth"
# when it asks for key authorization. Fails when nothing answers within a few
# seconds. Inside a sandbox the TCP connect always succeeds (the proxy
# accepts it first), so only an answer counts.
adb_hello() {
  LC_ALL=C timeout 8 bash -c '
    exec 3<>"/dev/tcp/$1/$2" || exit 1
    # CNXN, version 0x01000001, max payload 256 KiB, 7 bytes of "host::\0"
    # (checksum 0x232), magic = CNXN ^ 0xffffffff.
    printf "CNXN\x01\x00\x00\x01\x00\x00\x04\x00\x07\x00\x00\x00\x32\x02\x00\x00\xbc\xb1\xa7\xb1host::\x00" >&3
    IFS= read -r -N 4 -t 6 -u 3 cmd || exit 1
    case $cmd in CNXN) echo device ;; AUTH) echo auth ;; *) exit 1 ;; esac
  ' _ "$1" "$2" 2>/dev/null
}
