#!/usr/bin/env bash
# Status line identity test (spec AC5, §6.13).
# For every fixture in tests/fixtures/statusline-*.json:
#   1. no warnings: the wrapper's output is byte-identical to the original's;
#   2. two warnings: the output is the original's plus exactly the marker;
#   3. warnings present but DEVENV_STATUSLINE_WARNINGS=off: identical again.
# Also checks the preserved script's sha256.
set -euo pipefail

ROOT=$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)
WANT_SHA=dc324500a5e54bc7905816cd92039c6519e4bcd3303d40a023e0686cde7e27c4
fail=0

got_sha=$(sha256sum "$ROOT/agents/claude/statusline-command.sh" | cut -d' ' -f1)
if [ "$got_sha" = "$WANT_SHA" ]; then echo "ok   statusline-command.sh sha256 $WANT_SHA"
else echo "FAIL statusline-command.sh sha256 is $got_sha, want $WANT_SHA"; fail=1; fi

home=$(mktemp -d)
trap 'rm -rf "$home"' EXIT
mkdir -p "$home/.claude" "$home/.cache/devenv"
cp "$ROOT/agents/claude/statusline-command.sh" "$home/.claude/statusline-command.sh"
cp "$ROOT/agents/claude/statusline.sh" "$home/.claude/statusline.sh"
cache="$home/.cache/devenv/warnings"

# Run a status line script with a clean environment and the test HOME.
run() {  # <script> <fixture> <outfile> [VAR=value...]
  local script=$1 fixture=$2 out=$3; shift 3
  env -i PATH="$PATH" HOME="$home" LANG=C.UTF-8 "$@" bash "$script" < "$fixture" > "$out"
}

marker=$'\033[2m | \033[0m'$'\033[31m''⚠ devenv:2'$'\033[0m'
n=0
for fx in "$ROOT"/tests/fixtures/statusline-*.json; do
  n=$((n + 1))
  name=${fx##*/}
  run "$home/.claude/statusline-command.sh" "$fx" "$home/orig.out"

  : > "$cache"
  run "$home/.claude/statusline.sh" "$fx" "$home/wrap.out"
  if cmp -s "$home/orig.out" "$home/wrap.out"; then echo "ok   $name: byte-identical without warnings"
  else echo "FAIL $name: output differs without warnings"; cmp "$home/orig.out" "$home/wrap.out" || true; fail=1; fi

  printf 'first warning\nsecond warning\n' > "$cache"
  run "$home/.claude/statusline.sh" "$fx" "$home/warn.out"
  { cat "$home/orig.out"; printf '%s' "$marker"; } > "$home/want.out"
  if cmp -s "$home/want.out" "$home/warn.out"; then echo "ok   $name: marker appended with 2 warnings"
  else echo "FAIL $name: unexpected output with warnings"; od -c "$home/warn.out" | tail -n 3; fail=1; fi

  run "$home/.claude/statusline.sh" "$fx" "$home/off.out" DEVENV_STATUSLINE_WARNINGS=off
  if cmp -s "$home/orig.out" "$home/off.out"; then echo "ok   $name: identical with DEVENV_STATUSLINE_WARNINGS=off"
  else echo "FAIL $name: output differs with warnings off"; fail=1; fi
done
[ "$n" -gt 0 ] || { echo "FAIL no fixtures found"; fail=1; }

if [ "$fail" = 0 ]; then echo "statusline identity: PASS ($n fixtures)"; else echo "statusline identity: FAIL"; fi
exit "$fail"
