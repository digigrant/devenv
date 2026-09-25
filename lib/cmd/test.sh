# shellcheck shell=bash
# devenv test [--image IMG]... [--no-containers] [--no-shellcheck]
# (spec §6.13, AC5, AC12):
#   1. tests/statusline-identity.sh
#   2. shellcheck on every script (installed shellcheck, or the pinned image)
#   3. tests/container-smoke.sh for ubuntu:24.04 and ubuntu:26.04: provision.sh
#      --plain in a throwaway container, versions, a clean second run, and
#      `devenv check` exiting 0.

DEVENV_TEST_IMAGES=(ubuntu:24.04 ubuntu:26.04)

# The entry points; -x follows what they source, so lib/ is checked in context.
shellcheck_targets() {
  printf '%s\n' provision.sh bin/devenv bin/devenv-entry agents/claude/statusline.sh \
    agents/claude/hooks/memory-link.sh tests/*.sh
}

run_shellcheck() {
  local files
  mapfile -t files < <(cd "$DEVENV_ROOT" && shellcheck_targets)
  if have shellcheck; then
    (cd "$DEVENV_ROOT" && shellcheck -x "${files[@]}")
  elif have docker; then
    docker run --rm -v "$DEVENV_ROOT:/mnt:ro" -w /mnt "$TEST_SHELLCHECK_IMAGE" -x "${files[@]}"
  else
    warn "neither shellcheck nor docker is available"
    return 1
  fi
}

cmd_test() {
  local images=() containers=1 lint=1 rc=0 img results=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --image) images+=("${2:?--image needs a value}"); shift 2 ;;
      --no-containers) containers=0; shift ;;
      --no-shellcheck) lint=0; shift ;;
      *) die "usage: devenv test [--image IMG]... [--no-containers] [--no-shellcheck]" ;;
    esac
  done
  [ ${#images[@]} -gt 0 ] || images=("${DEVENV_TEST_IMAGES[@]}")

  echo "== status line identity"
  if bash "$DEVENV_ROOT/tests/statusline-identity.sh"; then results+=("PASS statusline identity")
  else results+=("FAIL statusline identity"); rc=1; fi

  if [ "$lint" = 1 ]; then
    echo "== shellcheck"
    if run_shellcheck; then results+=("PASS shellcheck"); else results+=("FAIL shellcheck"); rc=1; fi
  fi

  if [ "$containers" = 1 ]; then
    have docker || die "docker is required for the container tests"
    for img in "${images[@]}"; do
      echo "== container smoke: $img"
      if bash "$DEVENV_ROOT/tests/container-smoke.sh" "$img"; then results+=("PASS container $img")
      else results+=("FAIL container $img"); rc=1; fi
    done
  fi

  echo
  printf '%s\n' "${results[@]}"
  return "$rc"
}
