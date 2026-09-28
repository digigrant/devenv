# shellcheck shell=bash
# devenv bump: update pins in versions.env (spec §6.8). Edits a writable
# devenv checkout and prints the diff; never commits or pushes.
#
#   devenv bump [--repo PATH] herdr <version>
#   devenv bump [--repo PATH] herdr-manifest <commit|latest>
#   devenv bump [--repo PATH] treehouse <version|latest>
#   devenv bump [--repo PATH] no-mistakes <version|latest>
#   devenv bump [--repo PATH] npm <package> <version|latest>
#   devenv bump [--repo PATH] node <version|latest-lts>
#   devenv bump [--repo PATH] platform-tools <version|latest>
#   devenv bump [--repo PATH] android-emulator <build|latest>
#   devenv bump [--repo PATH] android-system-image <api> [tag]
#   devenv bump [--repo PATH] android-base-image [image:tag]
#   devenv bump --list          pinned vs latest, read-only

HERDR_MANIFEST_PATH=distribution/agent-detection/claude.toml

bump_usage() { sed -n '5,16p' "$DEVENV_ROOT/lib/cmd/bump.sh" | sed 's/^# \{0,1\}//'; }

# GitHub REST call: gh when it works, anonymous curl otherwise.
gh_api() {
  if have gh && gh api "$1" 2>/dev/null; then return 0; fi
  curl -fsSL -m 20 -H 'Accept: application/vnd.github+json' "https://api.github.com/$1"
}

# sha256 digest of a release asset (GitHub's recorded digest).
release_digest() {  # <release-json> <asset-name>
  printf '%s' "$1" | jq -r --arg n "$2" '.assets[] | select(.name == $n) | .digest // empty' | sed 's/^sha256://'
}

release_json() {  # <owner/repo> <version|latest>
  if [ "$2" = latest ]; then gh_api "repos/$1/releases/latest"; else gh_api "repos/$1/releases/tags/v${2#v}"; fi
}

set_pin() {  # <key> <value>
  grep -q "^$1=" "$BUMP_FILE" || die "$1 not found in $BUMP_FILE"
  sed -i "s|^$1=.*|$1=$2|" "$BUMP_FILE"
}

show_diff() {
  if diff -u --label "versions.env (before)" --label "versions.env" "$BUMP_BACKUP" "$BUMP_FILE"; then
    log "versions.env unchanged"
  fi
  rm -f "$BUMP_BACKUP"
}

herdr_verified_versions() {
  local doc="$FM_HOME/docs/herdr-backend.md"
  [ -f "$doc" ] || return 0
  grep -m1 -i 'verification covers versions' "$doc" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' || true
}

bump_herdr() {
  local ver=${1:?usage: devenv bump herdr <version>} json x a verified
  ver=${ver#v}
  json=$(release_json herdrdev/herdr "$ver") || die "no herdr release v$ver"
  x=$(release_digest "$json" herdr-linux-x86_64); a=$(release_digest "$json" herdr-linux-aarch64)
  [ -n "$x" ] && [ -n "$a" ] || die "herdr v$ver has no recorded digests for its Linux assets"
  set_pin HERDR_VERSION "$ver"
  set_pin HERDR_SHA256_X86_64 "$x"
  set_pin HERDR_SHA256_AARCH64 "$a"
  verified=$(herdr_verified_versions | tr '\n' ' ')
  if case " $verified " in *" $ver "*) false ;; *) true ;; esac; then
    printf '\n%s!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!\n' "$_c_red"
    printf '!!  herdr %s is NOT in Firstmate'"'"'s verified herdr versions: %s\n' "$ver" "${verified:-unknown (no \$FM_HOME/docs/herdr-backend.md)}"
    printf '!!  (%s). Expect breakage; test before merging.\n' "$FM_HOME/docs/herdr-backend.md"
    printf '!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!%s\n\n' "$_c_off"
  fi
  warn "the herdr Claude detection override was tested with herdr $HERDR_CLAUDE_MANIFEST_HERDR; run: devenv bump herdr-manifest latest, then test (devenv doctor shows which rules herdr uses)"
}

bump_herdr_manifest() {
  local ref=${1:-latest} sha content ver dest
  if [ "$ref" = latest ]; then
    sha=$(gh_api "repos/herdrdev/herdr/commits?path=$HERDR_MANIFEST_PATH&per_page=1" | jq -r '.[0].sha // empty')
  else
    sha=$(gh_api "repos/herdrdev/herdr/commits/$ref" | jq -r '.sha // empty')
  fi
  [ -n "$sha" ] || die "cannot resolve herdr commit $ref"
  content=$(gh_api "repos/herdrdev/herdr/contents/$HERDR_MANIFEST_PATH?ref=$sha" | jq -r '.content' | base64 -d) \
    || die "cannot fetch $HERDR_MANIFEST_PATH at $sha"
  ver=$(printf '%s\n' "$content" | sed -n 's/^version = "\(.*\)"$/\1/p' | head -n 1)
  [ -n "$ver" ] || die "no version field in the fetched manifest"
  dest="$BUMP_REPO/herdr/agent-detection/claude.toml"
  printf '%s\n' "$content" > "$dest"
  set_pin HERDR_CLAUDE_MANIFEST_COMMIT "$sha"
  set_pin HERDR_CLAUDE_MANIFEST_VERSION "$ver"
  set_pin HERDR_CLAUDE_MANIFEST_SHA256 "$(file_sha256 "$dest")"
  set_pin HERDR_CLAUDE_MANIFEST_HERDR "$(sed -n 's/^HERDR_VERSION=//p' "$BUMP_FILE")"
  log "herdr/agent-detection/claude.toml updated to $ver (herdr ${sha:0:12}); test detection before merging"
}

bump_gotool() {  # treehouse|no-mistakes <version|latest>
  local tool=$1 ver=${2:?usage: devenv bump $1 <version|latest>} json tag x a key
  json=$(release_json "kunchenguid/$tool" "$ver") || die "no $tool release $ver"
  tag=$(printf '%s' "$json" | jq -r .tag_name); ver=${tag#v}
  x=$(release_digest "$json" "$tool-v$ver-linux-amd64.tar.gz"); a=$(release_digest "$json" "$tool-v$ver-linux-arm64.tar.gz")
  [ -n "$x" ] && [ -n "$a" ] || die "$tool $tag has no recorded digests for its Linux assets"
  key=${tool//-/_}; key=${key^^}
  set_pin "${key}_VERSION" "$ver"
  set_pin "${key}_SHA256_X86_64" "$x"
  set_pin "${key}_SHA256_AARCH64" "$a"
}

bump_npm() {
  local pkg=${1:?usage: devenv bump npm <package> <version|latest>} ver=${2:-latest} var engines
  var=$(npm_pin_var "$pkg")
  grep -q "^$var=" "$BUMP_FILE" || die "$pkg is not one of devenv's npm packages (${DEVENV_NPM_PACKAGES[*]})"
  if [ "$ver" = latest ]; then ver=$(npm view "$pkg" version); else ver=$(npm view "$pkg@$ver" version | tail -n 1); fi
  [ -n "$ver" ] || die "no such version of $pkg"
  set_pin "$var" "$ver"
  engines=$(npm view "$pkg@$ver" engines.node 2>/dev/null || true)
  [ -n "$engines" ] && log "$pkg $ver requires node $engines (NODE_MIN_VERSION is $NODE_MIN_VERSION)"
}

bump_node() {
  local ver=${1:-latest-lts} sums x a
  if [ "$ver" = latest-lts ]; then
    ver=$(curl -fsSL -m 20 https://nodejs.org/dist/index.json | jq -r '[.[] | select(.lts != false)][0].version')
  fi
  ver=${ver#v}
  sums=$(curl -fsSL -m 20 "https://nodejs.org/dist/v$ver/SHASUMS256.txt") || die "no Node v$ver"
  x=$(printf '%s\n' "$sums" | awk -v f="node-v$ver-linux-x64.tar.gz" '$2 == f { print $1 }')
  a=$(printf '%s\n' "$sums" | awk -v f="node-v$ver-linux-arm64.tar.gz" '$2 == f { print $1 }')
  [ -n "$x" ] && [ -n "$a" ] || die "Node v$ver has no Linux tarballs"
  set_pin NODE_VERSION "$ver"
  set_pin NODE_SHA256_X86_64 "$x"
  set_pin NODE_SHA256_AARCH64 "$a"
}

# Google's SDK repository index (repository2-3.xml, or sys-img/<tag>/sys-img2-3.xml):
# one line per stable archive, "path version url host-os host-arch sha1"
# ("-" for a missing field).
android_repo_packages() {
  curl -fsSL --retry 3 -m 60 "$ANDROID_REPO_URL/$1" | python3 -c '
import sys, xml.etree.ElementTree as ET
root = ET.fromstring(sys.stdin.buffer.read())
chan = {c.get("id"): c.text for c in root.iter("channel")}
for p in root.iter():
    if not p.tag.endswith("remotePackage"):
        continue
    ref = p.find("channelRef")
    if ref is None or chan.get(ref.get("ref")) != "stable":
        continue
    rev = ".".join(x.text for x in p.find("revision") if x.tag in ("major", "minor", "micro"))
    for a in p.iter("archive"):
        print(p.get("path"), rev, a.findtext("complete/url"), a.findtext("host-os") or "-",
              a.findtext("host-arch") or "-", a.findtext("complete/checksum") or "-")
'
}

# android_zip_sha256 URL [SHA1]: download URL to a temporary file, check it
# against Google's SHA-1 when given, and print its sha256.
android_zip_sha256() {
  local url=$1 sha1=${2:--} tmp sum
  tmp=$(mktemp)
  log "downloading ${url##*/} to compute its sha256"
  curl -fsSL --retry 3 -o "$tmp" "$url" || { rm -f "$tmp"; die "download failed: $url"; }
  if [ "$sha1" != - ] && [ "$(sha1sum "$tmp" | cut -d' ' -f1)" != "$sha1" ]; then
    rm -f "$tmp"; die "${url##*/} does not match the SHA-1 in Google's repository index"
  fi
  sum=$(file_sha256 "$tmp")
  rm -f "$tmp"
  printf '%s' "$sum"
}

bump_platform_tools() {
  local ver=${1:-latest} line sha1=-
  line=$(android_repo_packages repository2-3.xml | awk '$1 == "platform-tools" && $4 == "linux"' | head -n 1)
  if [ "$ver" = latest ]; then
    [ -n "$line" ] || die "Google's repository lists no stable platform-tools for Linux"
    ver=$(printf '%s' "$line" | cut -d' ' -f2)
  fi
  [ "$(printf '%s' "$line" | cut -d' ' -f3)" = "platform-tools_r$ver-linux.zip" ] && sha1=$(printf '%s' "$line" | cut -d' ' -f6)
  set_pin ANDROID_PLATFORM_TOOLS_SHA256 "$(android_zip_sha256 "$ANDROID_REPO_URL/platform-tools_r$ver-linux.zip" "$sha1")"
  set_pin ANDROID_PLATFORM_TOOLS_VERSION "$ver"
}

bump_android_emulator() {
  local want=${1:-latest} line ver url sha1 build
  line=$(android_repo_packages repository2-3.xml | awk '$1 == "emulator" && $4 == "linux" && $5 == "x64"')
  [ "$want" = latest ] || line=$(printf '%s\n' "$line" | awk -v u="emulator-linux_x64-$want.zip" '$3 == u')
  line=$(printf '%s\n' "$line" | head -n 1)
  [ -n "$line" ] || die "Google's repository lists no stable Linux emulator build $want (devenv bump --list shows the latest)"
  read -r _ ver url _ _ sha1 <<<"$line"
  build=${url#emulator-linux_x64-}; build=${build%.zip}
  set_pin ANDROID_EMULATOR_SHA256 "$(android_zip_sha256 "$ANDROID_REPO_URL/$url" "$sha1")"
  set_pin ANDROID_EMULATOR_VERSION "$ver"
  set_pin ANDROID_EMULATOR_BUILD "$build"
}

bump_android_system_image() {
  local api=${1:?usage: devenv bump android-system-image <api> [tag]} tag=${2:-} line rev zip sha1
  [ -n "$tag" ] || tag=$(sed -n 's/^ANDROID_SYSTEM_IMAGE_TAG=//p' "$BUMP_FILE")
  line=$(android_repo_packages "sys-img/$tag/sys-img2-3.xml" | awk -v p="system-images;android-$api;$tag;x86_64" '$1 == p' | head -n 1)
  [ -n "$line" ] || die "Google's repository lists no stable system-images;android-$api;$tag;x86_64"
  read -r _ rev zip _ _ sha1 <<<"$line"
  log "the system image is about 2 GB"
  set_pin ANDROID_SYSTEM_IMAGE_SHA256 "$(android_zip_sha256 "$ANDROID_REPO_URL/sys-img/$tag/$zip" "$sha1")"
  set_pin ANDROID_SYSTEM_IMAGE_API "$api"
  set_pin ANDROID_SYSTEM_IMAGE_TAG "$tag"
  set_pin ANDROID_SYSTEM_IMAGE_REVISION "$rev"
  set_pin ANDROID_SYSTEM_IMAGE_ZIP "$zip"
}

bump_android_base_image() {
  local ref=${1:-} digest
  [ -n "$ref" ] || ref=$(sed -n 's/^ANDROID_EMULATOR_BASE_IMAGE=//p' "$BUMP_FILE" | sed 's/@.*//')
  have docker || die "resolving $ref's digest needs docker (docker buildx imagetools inspect)"
  digest=$(docker buildx imagetools inspect --format '{{json .Manifest}}' "$ref" | jq -r '.digest // empty') \
    && [ -n "$digest" ] || die "cannot resolve the digest of $ref"
  set_pin ANDROID_EMULATOR_BASE_IMAGE "${ref%@*}@$digest"
}

bump_list() {
  local row latest
  printf '%-22s %-14s %s\n' TOOL PINNED LATEST
  latest=$(release_json herdrdev/herdr latest 2>/dev/null | jq -r '.tag_name // "?"')
  printf '%-22s %-14s %s  (Firstmate-verified: %s)\n' herdr "$HERDR_VERSION" "${latest#v}" "$(herdr_verified_versions | tr '\n' ' ')"
  latest=$(gh_api "repos/herdrdev/herdr/commits?path=$HERDR_MANIFEST_PATH&per_page=1" 2>/dev/null | jq -r '.[0].sha // "?"')
  printf '%-22s %-14s %s\n' herdr-manifest "${HERDR_CLAUDE_MANIFEST_COMMIT:0:12}" "${latest:0:12}"
  for row in treehouse no-mistakes; do
    latest=$(release_json "kunchenguid/$row" latest 2>/dev/null | jq -r '.tag_name // "?"')
    printf '%-22s %-14s %s\n' "$row" "$(bin_pin "$row")" "${latest#v}"
  done
  for row in "${DEVENV_NPM_PACKAGES[@]}"; do
    latest=$(npm view "$row" version 2>/dev/null || echo '?')
    printf '%-22s %-14s %s\n' "$row" "$(npm_pin "$row")" "$latest"
  done
  latest=$(curl -fsSL -m 20 https://nodejs.org/dist/index.json 2>/dev/null | jq -r '[.[] | select(.lts != false)][0].version // "?"')
  printf '%-22s %-14s %s\n' node "$NODE_VERSION" "${latest#v}"
  latest=$(android_repo_packages repository2-3.xml 2>/dev/null | awk '$1 == "platform-tools" && $4 == "linux" { print $2; exit }')
  printf '%-22s %-14s %s\n' platform-tools "$ANDROID_PLATFORM_TOOLS_VERSION" "${latest:-?}"
  latest=$(android_repo_packages repository2-3.xml 2>/dev/null | awk '$1 == "emulator" && $4 == "linux" && $5 == "x64" { u = $3; sub(/^emulator-linux_x64-/, "", u); sub(/\.zip$/, "", u); print $2 " (" u ")"; exit }')
  printf '%-22s %-14s %s\n' android-emulator "$ANDROID_EMULATOR_VERSION ($ANDROID_EMULATOR_BUILD)" "${latest:-?}"
  latest=$(android_repo_packages "sys-img/$ANDROID_SYSTEM_IMAGE_TAG/sys-img2-3.xml" 2>/dev/null \
    | awk -v p="system-images;android-$ANDROID_SYSTEM_IMAGE_API;$ANDROID_SYSTEM_IMAGE_TAG;x86_64" '$1 == p { print "r" $2; exit }')
  printf '%-22s %-14s %s  (other API levels: devenv bump android-system-image <api>)\n' android-system-image \
    "$ANDROID_SYSTEM_IMAGE_API r$ANDROID_SYSTEM_IMAGE_REVISION" "${latest:-?}"
  latest=$(git ls-remote "$FIRSTMATE_REPO" refs/heads/main 2>/dev/null | cut -c1-12)
  printf '%-22s %-14s %s  (%s; not pinned, updates automatically)\n' firstmate - "${latest:-?}" "${FIRSTMATE_REPO#https://github.com/}"
  if [ -n "${FIRSTMATE_UPSTREAM:-}" ]; then
    latest=$(git ls-remote "$FIRSTMATE_UPSTREAM" refs/heads/main 2>/dev/null | cut -c1-12)
    printf '%-22s %-14s %s  (%s; synced into the fork automatically)\n' firstmate-upstream - "${latest:-?}" "${FIRSTMATE_UPSTREAM#https://github.com/}"
  fi
}

cmd_bump() {
  local repo=''
  resolve_paths
  while [ $# -gt 0 ]; do
    case "$1" in
      --repo) repo=${2:?--repo needs a path}; shift 2 ;;
      --repo=*) repo=${1#*=}; shift ;;
      --list) bump_list; return 0 ;;
      -h|--help) bump_usage; return 0 ;;
      *) break ;;
    esac
  done
  [ $# -gt 0 ] || { bump_usage; return 1; }
  BUMP_REPO=${repo:-$DEVENV_ROOT}
  BUMP_FILE="$BUMP_REPO/versions.env"
  [ -f "$BUMP_FILE" ] || die "$BUMP_FILE not found"
  if [ ! -w "$BUMP_FILE" ] || [ ! -w "$BUMP_REPO" ]; then
    die "$BUMP_REPO is read-only. Clone the repo and bump there, then open a PR:
    git clone https://github.com/digigrant/devenv ~/src/devenv
    devenv bump --repo ~/src/devenv $*"
  fi
  BUMP_BACKUP=$(mktemp)
  cp "$BUMP_FILE" "$BUMP_BACKUP"
  local what=$1; shift
  case "$what" in
    herdr) bump_herdr "$@" ;;
    herdr-manifest) bump_herdr_manifest "$@" ;;
    treehouse|no-mistakes) bump_gotool "$what" "$@" ;;
    npm) bump_npm "$@" ;;
    node) bump_node "$@" ;;
    platform-tools) bump_platform_tools "$@" ;;
    android-emulator) bump_android_emulator "$@" ;;
    android-system-image) bump_android_system_image "$@" ;;
    android-base-image) bump_android_base_image "$@" ;;
    *) rm -f "$BUMP_BACKUP"; bump_usage; die "unknown bump target: $what" ;;
  esac
  show_diff
}
