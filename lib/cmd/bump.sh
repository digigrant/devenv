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
#   devenv bump --list          pinned vs latest, read-only

HERDR_MANIFEST_PATH=distribution/agent-detection/claude.toml

bump_usage() { sed -n '5,12p' "$DEVENV_ROOT/lib/cmd/bump.sh" | sed 's/^# \{0,1\}//'; }

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
    *) rm -f "$BUMP_BACKUP"; bump_usage; die "unknown bump target: $what" ;;
  esac
  show_diff
}
