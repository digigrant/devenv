#!/usr/bin/env bash
# The Android build toolchain and adb (spec §6.3 step 3b) against fakes:
# provision.sh's installers for platform-tools, the JDK and the SDK packages,
# with tests/fakes/curl serving small dummy archives laid out like Google's
# zips and Temurin's tarball (their sha256s replace the pins), a temporary
# HOME, and DEVENV_HOST_ROOT standing a folder in for / (the system's CA list
# for Java). No real download, JDK or SDK is touched.
#   tests/android-toolchain.sh
# pass and fail always succeed, so `test && pass || fail` is a safe if/else,
# and single-quoted $ text is meant literally (code for the tested shell).
# shellcheck disable=SC2015,SC2016
set -euo pipefail

ROOT=$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)
W=$(mktemp -d)
trap 'rm -rf "$W"' EXIT
mkdir -p "$W/home" "$W/tmp" "$W/log" "$W/dl" "$W/root/etc/ssl/certs/java" "$W/arm"
H=$W/home
SDK=$H/.local/share/android-sdk
JDK=$H/.local/share/jdk
CAS=$W/root/etc/ssl/certs/java/cacerts
printf 'system CAs\n' > "$CAS"
# A uname that says aarch64, for the architecture that gets no toolchain.
printf '#!/bin/sh\n[ "${1:-}" = -m ] && { echo aarch64; exit 0; }\nexec %s "$@"\n' "$(command -v uname)" > "$W/arm/uname"
chmod +x "$W/arm/uname"

fails=0
pass() { printf '  ok    %s\n' "$*"; }
fail() { printf '  FAIL  %s\n' "$*"; fails=$((fails + 1)); }

# archive OUT TOP NAME=CONTENT...: a zip (or, for any other OUT, a .tar.gz)
# holding the folder TOP with those files ("\n" in CONTENT is a newline),
# all executable.
archive() {
  python3 - "$@" <<'EOF'
import io, sys, tarfile, zipfile
out, top, *files = sys.argv[1:]
entries = [(n, c.replace("\\n", "\n").encode()) for n, c in (f.split("=", 1) for f in files)]
if out.endswith(".zip"):
    with zipfile.ZipFile(out, "w") as z:
        for n, c in entries:
            i = zipfile.ZipInfo(f"{top}/{n}"); i.external_attr = 0o755 << 16
            z.writestr(i, c)
else:
    with tarfile.open(out, "w:gz") as t:
        for n, c in entries:
            i = tarfile.TarInfo(f"{top}/{n}"); i.size = len(c); i.mode = 0o755
            t.addfile(i, io.BytesIO(c))
EOF
  sha256sum "$1" | cut -d' ' -f1
}

# The dummy downloads, named as the pins name them, and pins that match them.
. "$ROOT/versions.env"
JDK_TGZ="OpenJDK${JDK_VERSION%%.*}U-jdk_x64_linux_hotspot_${JDK_VERSION/+/_}.tar.gz"
CT_ZIP="commandlinetools-linux-${ANDROID_CMDLINE_TOOLS_BUILD}_latest.zip"
platform_props="Pkg.Desc=Android SDK Platform 17\nPkg.Revision=$ANDROID_PLATFORM_REVISION\nAndroidVersion.ApiLevel=37.0\nAndroidVersion.CodeName=\nAndroidVersion.ExtensionLevel=22\nAndroidVersion.IsBaseSdk=true\nLayoutlib.Api=15\nLayoutlib.Revision=1"
{
  echo "ANDROID_PLATFORM_TOOLS_SHA256=$(archive "$W/dl/platform-tools_r$ANDROID_PLATFORM_TOOLS_VERSION-linux.zip" platform-tools \
    "adb=#!/bin/sh\necho 'Android Debug Bridge version 1.0.41'\necho 'Version $ANDROID_PLATFORM_TOOLS_VERSION-1'" \
    'package.xml=<repository/>' "source.properties=Pkg.Revision=$ANDROID_PLATFORM_TOOLS_VERSION")"
  echo "JDK_SHA256=$(archive "$W/dl/$JDK_TGZ" "jdk-$JDK_VERSION" \
    "release=IMPLEMENTOR=\"Eclipse Adoptium\"\nIMPLEMENTOR_VERSION=\"Temurin-$JDK_VERSION\"" \
    'bin/java=#!/bin/sh\necho fake java' 'lib/security/cacerts=temurin CAs')"
  echo "ANDROID_CMDLINE_TOOLS_SHA256=$(archive "$W/dl/$CT_ZIP" cmdline-tools \
    "source.properties=Pkg.Revision=$ANDROID_CMDLINE_TOOLS_VERSION\nPkg.Path=cmdline-tools;$ANDROID_CMDLINE_TOOLS_VERSION\nPkg.Desc=Android SDK Command-line Tools" \
    'bin/sdkmanager=#!/bin/sh\necho fake sdkmanager' 'bin/avdmanager=#!/bin/sh\necho fake avdmanager')"
  echo "ANDROID_PLATFORM_SHA256=$(archive "$W/dl/$ANDROID_PLATFORM_ZIP" "$ANDROID_PLATFORM" \
    "source.properties=$platform_props" 'android.jar=dummy')"
  # Google's build-tools zips hold a folder named for an old Android release.
  echo "ANDROID_BUILD_TOOLS_SHA256=$(archive "$W/dl/$ANDROID_BUILD_TOOLS_ZIP" android-16 \
    "source.properties=Pkg.UserSrc=false\nPkg.Revision=$ANDROID_BUILD_TOOLS_VERSION\n#Pkg.Revision=$ANDROID_BUILD_TOOLS_VERSION rc5" \
    'aapt2=dummy')"
} > "$W/pins"

# step CODE [PATH_PREFIX]: run CODE in a shell set up the way provision.sh's
# user phase is (plain mode, devenv's libraries, the dummy pins), with the
# fakes first on PATH and the temporary HOME. Sets OUT (stdout and stderr) and RC.
step() {
  : > "$W/log/argv"
  RC=0
  OUT=$(env -i HOME="$H" TMPDIR="$W/tmp" PATH="${2:+$2:}$ROOT/tests/fakes:/usr/local/bin:/usr/bin:/bin" \
    FAKE_LOG="$W/log" FAKE_DOWNLOADS="$W/dl" DEVENV_HOST_ROOT="$W/root" DEVENV_ROOT="$ROOT" PINS="$W/pins" \
    bash -c 'set -euo pipefail
      . "$DEVENV_ROOT/lib/common.sh"; . "$DEVENV_ROOT/lib/tools.sh"; . "$DEVENV_ROOT/lib/android.sh"
      . "$DEVENV_ROOT/lib/cmd/check.sh"
      load_config; . "$PINS"; resolve_paths plain
      eval "$1"' _ "$1" 2>&1) || RC=$?
}
downloads() { grep -c '^curl ' "$W/log/argv" || true; }
has() { printf '%s\n' "$OUT" | grep -qF -- "$1"; }
snapshot() {
  (cd "$H" && find . \( -type f -o -type l \) -print | sort | while read -r f; do
    if [ -L "$f" ]; then echo "L $(readlink "$f") $f"; else echo "$(sha256sum < "$f" | cut -c1-16) $(stat -c %Y "$f") $f"; fi
  done)
}
# pkgxml DIR: "<path> <revision> <type> <api-level> <extension-level> <base-extension> <layoutlib api>"
# from DIR/package.xml, parsed as XML.
pkgxml() {
  python3 - "$1/package.xml" <<'EOF'
import sys, xml.etree.ElementTree as ET
p = ET.parse(sys.argv[1]).getroot().find("localPackage")
t = p.find("type-details")
rev = ".".join(e.text for e in p.find("revision"))
xsi = "{http://www.w3.org/2001/XMLSchema-instance}type"
lay = t.find("layoutlib")
print(p.get("path"), rev, t.get(xsi), *(t.findtext(k) or "-" for k in ("api-level", "extension-level", "base-extension")),
      lay.get("api") if lay is not None else "-")
EOF
}

echo "== aarch64: no toolchain"
step 'install_platform_tools; install_android_toolchain' "$W/arm"
[ "$RC" = 0 ] && has 'Android build toolchain: Google publishes build-tools for x86_64 Linux only; skipped on aarch64' \
  && [ "$(downloads)" = 0 ] && [ -z "$(ls -A "$H")" ] && pass "skipped with a note, nothing downloaded or written" || fail "aarch64: rc $RC: $OUT"

echo "== first install"
step 'install_platform_tools; install_android_toolchain; android_toolchain_versions'
[ "$RC" = 0 ] && pass "installs" || { fail "install failed (rc $RC)"; printf '%s\n' "$OUT"; exit 1; }
[ "$(downloads)" = 5 ] && pass "5 downloads" || fail "$(downloads) downloads"
grep -qF "https://github.com/adoptium/temurin21-binaries/releases/download/jdk-${JDK_VERSION/+/%2B}/$JDK_TGZ" "$W/log/argv" \
  && pass "the JDK from Temurin's release on GitHub" || fail "JDK URL: $(grep adoptium "$W/log/argv")"
for z in "$CT_ZIP" "$ANDROID_PLATFORM_ZIP" "$ANDROID_BUILD_TOOLS_ZIP"; do
  grep -qF "https://dl.google.com/android/repository/$z" "$W/log/argv" && pass "$z from Google's repository" || fail "no download of $z"
done
[ "$(cat "$JDK/release" 2>/dev/null | sed -n 's/^IMPLEMENTOR_VERSION=//p')" = "\"Temurin-$JDK_VERSION\"" ] && [ -x "$JDK/bin/java" ] \
  && pass "JDK in ~/.local/share/jdk" || fail "JDK layout"
[ "$(readlink "$JDK/lib/security/cacerts")" = "$CAS" ] && [ "$(cat "$JDK/lib/security/cacerts.temurin")" = "temurin CAs" ] \
  && has "the JDK trusts the system's CA certificates ($CAS)" && pass "the JDK uses the system's CA list, Temurin's kept" || fail "JDK trust store"
[ -x "$SDK/cmdline-tools/latest/bin/sdkmanager" ] && [ -f "$SDK/platforms/$ANDROID_PLATFORM/android.jar" ] \
  && [ -f "$SDK/build-tools/$ANDROID_BUILD_TOOLS_VERSION/aapt2" ] && [ -x "$SDK/platform-tools/adb" ] \
  && pass "SDK layout: cmdline-tools/latest, platforms/$ANDROID_PLATFORM, build-tools/$ANDROID_BUILD_TOOLS_VERSION, platform-tools" \
  || fail "SDK layout: $(cd "$SDK" && find . -maxdepth 2 | sort | tr '\n' ' ')"
got=$(pkgxml "$SDK/platforms/$ANDROID_PLATFORM")
[ "$got" = "platforms;$ANDROID_PLATFORM $ANDROID_PLATFORM_REVISION sdk:platformDetailsType 37.0 22 true 15" ] \
  && pass "package.xml for the platform" || fail "platform package.xml: $got"
got=$(pkgxml "$SDK/build-tools/$ANDROID_BUILD_TOOLS_VERSION")
[ "$got" = "build-tools;$ANDROID_BUILD_TOOLS_VERSION $ANDROID_BUILD_TOOLS_VERSION generic:genericDetailsType - - - -" ] \
  && pass "package.xml for build-tools" || fail "build-tools package.xml: $got"
got=$(pkgxml "$SDK/cmdline-tools/latest")
[ "$got" = "cmdline-tools;latest $ANDROID_CMDLINE_TOOLS_VERSION generic:genericDetailsType - - - -" ] \
  && pass "package.xml for cmdline-tools" || fail "cmdline-tools package.xml: $got"
[ "$(cat "$SDK/platform-tools/package.xml")" = '<repository/>' ] && pass "platform-tools keeps its own package.xml" || fail "platform-tools package.xml replaced"
for t in adb:platform-tools/adb sdkmanager:cmdline-tools/latest/bin/sdkmanager avdmanager:cmdline-tools/latest/bin/avdmanager; do
  [ "$(readlink "$H/.local/bin/${t%%:*}")" = "$SDK/${t#*:}" ] && pass "${t%%:*} linked into ~/.local/bin" || fail "${t%%:*} link"
done
for t in "jdk $JDK_VERSION $JDK_VERSION" "cmdline-tools;latest $ANDROID_CMDLINE_TOOLS_VERSION $ANDROID_CMDLINE_TOOLS_VERSION" \
    "platforms;$ANDROID_PLATFORM $ANDROID_PLATFORM_REVISION $ANDROID_PLATFORM_REVISION" \
    "build-tools;$ANDROID_BUILD_TOOLS_VERSION $ANDROID_BUILD_TOOLS_VERSION $ANDROID_BUILD_TOOLS_VERSION"; do
  printf '%s\n' "$OUT" | grep -qxF "$t" && pass "reported: $t" || fail "not reported: $t"
done
[ -z "$(ls -A "$W/tmp")" ] || [ -z "$(find "$W/tmp" -name '*.part')" ] && pass "no partial downloads left" || fail "partial downloads in TMPDIR"

echo "== second run"
snapshot > "$W/snap1"
step 'install_platform_tools; install_android_toolchain'
snapshot > "$W/snap2"
[ "$RC" = 0 ] && [ "$(downloads)" = 0 ] && pass "nothing downloaded" || fail "rc $RC, $(downloads) downloads"
diff -u "$W/snap1" "$W/snap2" >/dev/null && pass "nothing in HOME changed" || { fail "HOME changed:"; diff -u "$W/snap1" "$W/snap2" || true; }
[ "$(printf '%s\n' "$OUT" | grep -c 'already installed')" = 5 ] && ! printf '%s\n' "$OUT" | grep -v 'already installed' | grep -q . \
  && pass "every piece reported as already installed, nothing else" || fail "second run said: $OUT"

echo "== the system's CA list for Java goes away, then comes back"
rm "$CAS"
step 'install_android_toolchain'
[ ! -L "$JDK/lib/security/cacerts" ] && [ "$(cat "$JDK/lib/security/cacerts")" = "temurin CAs" ] \
  && [ ! -e "$JDK/lib/security/cacerts.temurin" ] && has "the JDK uses Temurin's own CA certificates again" \
  && pass "Temurin's list back in place" || fail "trust store without the system's list: $(ls -l "$JDK/lib/security")"
printf 'system CAs\n' > "$CAS"
step 'install_android_toolchain'
[ "$(readlink "$JDK/lib/security/cacerts")" = "$CAS" ] && pass "linked to the system's list again" || fail "not relinked"

echo "== a new platform revision, and a package added with sdkmanager"
mkdir -p "$SDK/build-tools/35.0.0" && printf 'x\n' > "$SDK/build-tools/35.0.0/package.xml"
new=$(archive "$W/dl/platform-37.0_r03.zip" "$ANDROID_PLATFORM" \
  "source.properties=${platform_props/Pkg.Revision=$ANDROID_PLATFORM_REVISION/Pkg.Revision=3}" 'android.jar=dummy 3')
step "ANDROID_PLATFORM_REVISION=3 ANDROID_PLATFORM_ZIP=platform-37.0_r03.zip ANDROID_PLATFORM_SHA256=$new; install_android_toolchain"
[ "$RC" = 0 ] && [ "$(downloads)" = 1 ] && has "platforms;$ANDROID_PLATFORM 3 installed in $SDK/platforms/$ANDROID_PLATFORM (was $ANDROID_PLATFORM_REVISION)" \
  && [ "$(cat "$SDK/platforms/$ANDROID_PLATFORM/android.jar")" = "dummy 3" ] && pass "only the platform replaced (was $ANDROID_PLATFORM_REVISION)" || fail "new revision: rc $RC: $OUT"
[ -f "$SDK/build-tools/35.0.0/package.xml" ] && pass "the added build-tools 35.0.0 stays" || fail "the added package was removed"

echo "== a download that doesn't match its pin"
step "ANDROID_PLATFORM_REVISION=4 ANDROID_PLATFORM_ZIP=platform-37.0_r03.zip ANDROID_PLATFORM_SHA256=$(printf '0%.0s' {1..64}); install_android_toolchain"
[ "$RC" != 0 ] && has "sha256 mismatch for https://dl.google.com/android/repository/platform-37.0_r03.zip" \
  && [ "$(cat "$SDK/platforms/$ANDROID_PLATFORM/android.jar")" = "dummy 3" ] && pass "fails, and the installed platform stays" || fail "bad checksum: rc $RC: $OUT"
[ -z "$(find "$W/tmp" -name '*.part')" ] && pass "no partial download left" || fail "partial download left"

echo "== devenv check"
rm -rf "$SDK/build-tools/$ANDROID_BUILD_TOOLS_VERSION"
step 'check_tool_versions; printf "warning: %s\n" "${_CHECK_WARNINGS[@]}"'
has "warning: build-tools;$ANDROID_BUILD_TOOLS_VERSION not installed (pinned $ANDROID_BUILD_TOOLS_VERSION) — run provision.sh" \
  && pass "a missing build-tools is a warning" || fail "check: $OUT"
has "warning: platforms;$ANDROID_PLATFORM 3 installed, pinned $ANDROID_PLATFORM_REVISION — run provision.sh" \
  && pass "a platform at another revision is a warning" || fail "check: $OUT"
! has "warning: jdk" && ! has "warning: cmdline-tools" && pass "no warning for what matches its pin" || fail "check: $OUT"

echo
if [ "$fails" = 0 ]; then echo "android toolchain: PASS"; else echo "android toolchain: $fails FAILED"; fi
[ "$fails" = 0 ]
