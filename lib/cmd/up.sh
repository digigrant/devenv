# shellcheck shell=bash
# devenv up [sbx env run options]: the V5 fallback, for sbx versions that do
# not resolve relative paths in sbxenv.yaml. Renders sbxenv.yaml with absolute
# paths into .sbxenv.rendered.yaml (gitignored) and runs `sbx env run` on it.
# Not needed when `cd ~/devenv && sbx env run` works (docs/HOST-VERIFY.md V5).

cmd_up() {
  local real out
  [ "$(detect_mode)" = sbx ] && die "devenv up runs on the host"
  have sbx || die "sbx is not installed"
  real=$(readlink -f "$DEVENV_ROOT")
  out="$real/.sbxenv.rendered.yaml"
  sed -e "s|^workspace: \.\./dev\b|workspace: $(dirname "$real")/dev|" \
      -e "s|^\(  *- path: \)\.\( *\)$|\1$real\2|" \
      -e "s|\./kits/devenv|$real/kits/devenv|g" \
      -e "s|\./bin/devenv|$real/bin/devenv|g" \
      -e "s|\${{ env\.fileDir }}|$real|g" \
      "$real/sbxenv.yaml" > "$out"
  log "rendered $out"
  exec sbx env run "$out" "$@"
}
