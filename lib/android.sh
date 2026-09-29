# shellcheck shell=bash
# Android in the sandbox and in plain mode: adb (Google's platform-tools), the
# build toolchain (a JDK, the command-line tools, a platform and build-tools),
# and the adb handshake probe that `devenv emulator` and `devenv doctor` use.
# Needs lib/common.sh, load_config and resolve_paths.

ANDROID_REPO_URL=https://dl.google.com/android/repository

# Google publishes platform-tools, build-tools and the emulator for x86_64
# Linux only.
android_supported() { [ "$(uname -m)" = x86_64 ]; }

# devenv's Android SDK. It is ANDROID_HOME unless one is already set, so a
# project can add SDK packages to it with sdkmanager.
android_sdk_dir() { printf '%s' "$HOME/.local/share/android-sdk"; }

# devenv's JDK, JAVA_HOME unless one is already set.
jdk_dir() { printf '%s' "$HOME/.local/share/jdk"; }

# _prop FILE KEY: KEY's value in a properties file (source.properties, a
# JDK's release file), without quotes; empty when either is missing.
_prop() {
  sed -n "s/^${2//./\\.}=//p" "$1" 2>/dev/null | head -n 1 | sed 's/^"\(.*\)"$/\1/' || true
}

# _android_unpack URL SHA256 DEST [PACKAGE NAME]: download URL, check its
# sha256, unpack it (a zip or a .tar.gz holding one folder) and put that
# folder in place as DEST, replacing what is there. With an SDK PACKAGE path
# (such as platforms;android-37.0) and its display NAME, record it in
# DEST/package.xml first, as sdkmanager does.
_android_unpack() {
  local url=$1 sha=$2 dest=$3 pkg=${4:-} name=${5:-} tmp top
  tmp=$(mktemp -d)
  fetch_verified "$url" "$sha" "$tmp/download"
  mkdir "$tmp/x"
  case "$url" in
    *.zip)
      have unzip || die "unzip is missing; run: sudo apt-get install -y unzip"
      unzip -q "$tmp/download" -d "$tmp/x"
      ;;
    *) tar -xzf "$tmp/download" -C "$tmp/x" ;;
  esac
  top=$(find "$tmp/x" -mindepth 1 -maxdepth 1)
  if [ ! -d "$top" ]; then rm -rf "$tmp"; die "${url##*/} does not hold exactly one folder"; fi
  [ -z "$pkg" ] || _sdk_package_xml "$pkg" "$top" "$name"
  mkdir -p "${dest%/*}"
  rm -rf "$dest.devenv-old"
  if [ -e "$dest" ]; then mv "$dest" "$dest.devenv-old"; fi
  mv "$top" "$dest"
  rm -rf "$dest.devenv-old" "$tmp"
}

# "36.0.0" → <major>36</major><minor>0</minor><micro>0</micro>
_revision_xml() {
  local parts tag i=0
  IFS=. read -ra parts <<<"$1"
  for tag in major minor micro; do
    [ "$i" -lt "${#parts[@]}" ] && printf '<%s>%s</%s>' "$tag" "${parts[$i]}" "$tag"
    i=$((i + 1))
  done
  return 0
}

# _sdk_package_xml PACKAGE DIR NAME: write DIR/package.xml for the SDK package
# unpacked in DIR, from its source.properties. sdkmanager and the Android
# Gradle Plugin know a package by this file; without it they miss a platform
# such as android-37.0 (its source.properties is too new for their fallback
# reader), and the plugin then tries to download it, which fails until the SDK
# license is accepted.
_sdk_package_xml() {
  local pkg=$1 dir=$2 name=$3 p=$2/source.properties details v
  case "$pkg" in
    platforms\;*)
      details="<type-details xsi:type=\"sdk:platformDetailsType\"><api-level>$(_prop "$p" AndroidVersion.ApiLevel)</api-level>"
      details+="<codename>$(_prop "$p" AndroidVersion.CodeName)</codename>"
      v=$(_prop "$p" AndroidVersion.ExtensionLevel)
      [ -z "$v" ] || details+="<extension-level>$v</extension-level>"
      v=$(_prop "$p" AndroidVersion.IsBaseSdk)
      [ -z "$v" ] || details+="<base-extension>$v</base-extension>"
      details+="<layoutlib api=\"$(_prop "$p" Layoutlib.Api)\"/></type-details>"
      ;;
    *) details='<type-details xsi:type="generic:genericDetailsType"/>' ;;
  esac
  cat > "$dir/package.xml" <<EOF
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<ns2:repository xmlns:ns2="http://schemas.android.com/repository/android/common/02" xmlns:generic="http://schemas.android.com/repository/android/generic/02" xmlns:sdk="http://schemas.android.com/sdk/android/repo/repository2/03" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
  <localPackage path="$pkg" obsolete="false">
    $details
    <revision>$(_revision_xml "$(_prop "$p" Pkg.Revision)")</revision>
    <display-name>$name</display-name>
  </localPackage>
</ns2:repository>
EOF
}

# Revision of the SDK package in DIR when devenv (or sdkmanager) installed it,
# with its package.xml; empty otherwise.
_sdk_pkg_revision() {
  [ -f "$1/package.xml" ] || return 0
  _prop "$1/source.properties" Pkg.Revision
}

# The build toolchain's SDK packages, one per line: "<package> <folder in the
# SDK> <revision> <zip> <sha256> <display name>".
_android_sdk_packages() {
  printf '%s\n' \
    "cmdline-tools;latest cmdline-tools/latest $ANDROID_CMDLINE_TOOLS_VERSION commandlinetools-linux-${ANDROID_CMDLINE_TOOLS_BUILD}_latest.zip $ANDROID_CMDLINE_TOOLS_SHA256 Android SDK Command-line Tools" \
    "platforms;$ANDROID_PLATFORM platforms/$ANDROID_PLATFORM $ANDROID_PLATFORM_REVISION $ANDROID_PLATFORM_ZIP $ANDROID_PLATFORM_SHA256 Android SDK Platform ${ANDROID_PLATFORM#android-}" \
    "build-tools;$ANDROID_BUILD_TOOLS_VERSION build-tools/$ANDROID_BUILD_TOOLS_VERSION $ANDROID_BUILD_TOOLS_VERSION $ANDROID_BUILD_TOOLS_ZIP $ANDROID_BUILD_TOOLS_SHA256 Android SDK Build-Tools ${ANDROID_BUILD_TOOLS_VERSION%%.*}"
}

# Version of devenv's JDK (its release file's "Temurin-<version>"), or empty.
jdk_installed_version() {
  local v
  v=$(_prop "$(jdk_dir)/release" IMPLEMENTOR_VERSION)
  printf '%s' "${v#Temurin-}"
}

# The build toolchain, one line per piece: "<name> <pinned> <installed>",
# installed being empty when it is missing.
android_toolchain_versions() {
  local pkg dir rev _
  printf 'jdk %s %s\n' "$JDK_VERSION" "$(jdk_installed_version)"
  while read -r pkg dir rev _; do
    printf '%s %s %s\n' "$pkg" "$rev" "$(_sdk_pkg_revision "$(android_sdk_dir)/$dir")"
  done < <(_android_sdk_packages)
}

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
  local sdk cur
  if ! android_supported; then
    log "adb: Google publishes platform-tools for x86_64 Linux only; skipped on $(uname -m)"
    return 0
  fi
  sdk=$(android_sdk_dir)
  cur=$(_adb_version_of "$sdk/platform-tools/adb" || true)
  if [ "$cur" != "$ANDROID_PLATFORM_TOOLS_VERSION" ]; then
    _android_unpack "$ANDROID_REPO_URL/platform-tools_r$ANDROID_PLATFORM_TOOLS_VERSION-linux.zip" \
      "$ANDROID_PLATFORM_TOOLS_SHA256" "$sdk/platform-tools"
  fi
  mkdir -p "$LOCAL_BIN"
  [ "$(readlink "$LOCAL_BIN/adb" 2>/dev/null)" = "$sdk/platform-tools/adb" ] || ln -sfn "$sdk/platform-tools/adb" "$LOCAL_BIN/adb"
  hash -r
  if [ "$cur" = "$ANDROID_PLATFORM_TOOLS_VERSION" ]; then ok "adb $cur (already installed)"
  else ok "adb $ANDROID_PLATFORM_TOOLS_VERSION installed in $sdk/platform-tools${cur:+ (was $cur)}"; fi
}

# Let devenv's JDK trust the system's CA certificates for Java
# (/etc/ssl/certs/java/cacerts, from ca-certificates-java) when the system
# has them, as Ubuntu's own JDKs do. In a sandbox that list holds the proxy's
# CA, which re-signs github.com, where Gradle's wrapper downloads Gradle;
# Temurin's own list doesn't. Temurin's list stays as cacerts.temurin and
# comes back if the system's goes away.
_jdk_system_trust() {
  local sec=$1/lib/security sys
  sys=$(host_path /etc/ssl/certs/java/cacerts)
  if [ -s "$sys" ]; then
    [ "$(readlink "$sec/cacerts" 2>/dev/null)" != "$sys" ] || return 0
    [ -L "$sec/cacerts" ] || mv -f "$sec/cacerts" "$sec/cacerts.temurin"
    ln -sfn "$sys" "$sec/cacerts"
    ok "the JDK trusts the system's CA certificates ($sys)"
  elif [ -L "$sec/cacerts" ] && [ -f "$sec/cacerts.temurin" ]; then
    mv -f "$sec/cacerts.temurin" "$sec/cacerts"
    ok "the JDK uses Temurin's own CA certificates again ($sys is gone)"
  fi
  return 0
}

# Install the pinned JDK into jdk_dir. Skipped when its release file names
# the pin.
install_jdk() {
  local dir cur major
  dir=$(jdk_dir)
  cur=$(jdk_installed_version)
  major=${JDK_VERSION%%.*}
  if [ "$cur" = "$JDK_VERSION" ]; then
    ok "jdk $cur (already installed)"
  else
    _android_unpack "https://github.com/adoptium/temurin$major-binaries/releases/download/jdk-${JDK_VERSION/+/%2B}/OpenJDK${major}U-jdk_x64_linux_hotspot_${JDK_VERSION/+/_}.tar.gz" \
      "$JDK_SHA256" "$dir"
    ok "jdk $JDK_VERSION (Temurin) installed in $dir${cur:+ (was $cur)}"
  fi
  _jdk_system_trust "$dir"
}

# Install the build toolchain: the JDK and the pinned SDK packages, each
# skipped when it matches its pin, and link sdkmanager and avdmanager into
# LOCAL_BIN. Packages added with sdkmanager stay.
install_android_toolchain() {
  local sdk pkg dir rev zip sha name cur t
  if ! android_supported; then
    log "Android build toolchain: Google publishes build-tools for x86_64 Linux only; skipped on $(uname -m)"
    return 0
  fi
  install_jdk
  sdk=$(android_sdk_dir)
  while read -r pkg dir rev zip sha name; do
    cur=$(_sdk_pkg_revision "$sdk/$dir")
    if [ "$cur" = "$rev" ]; then ok "$pkg $rev (already installed)"; continue; fi
    _android_unpack "$ANDROID_REPO_URL/$zip" "$sha" "$sdk/$dir" "$pkg" "$name"
    ok "$pkg $rev installed in $sdk/$dir${cur:+ (was $cur)}"
  done < <(_android_sdk_packages)
  mkdir -p "$LOCAL_BIN"
  for t in sdkmanager avdmanager; do
    [ "$(readlink "$LOCAL_BIN/$t" 2>/dev/null)" = "$sdk/cmdline-tools/latest/bin/$t" ] \
      || ln -sfn "$sdk/cmdline-tools/latest/bin/$t" "$LOCAL_BIN/$t"
  done
  hash -r
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
