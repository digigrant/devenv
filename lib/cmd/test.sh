# shellcheck shell=bash
# devenv test [--image IMG]... [--no-containers] [--no-shellcheck] [--emulator-image]
# (spec §6.13, AC5, AC12):
#   1. tests/statusline-identity.sh
#   2. tests/secrets.sh: secret-get, doctor and host-prepare against a fake
#      keyring, Infisical, GitHub and sbx (docs/SECRETS.md §6.9); and
#      tests/emulator.sh: devenv emulator against a fake docker, adb and sbx
#      (spec §6.15)
#   3. tests/tailscale.sh: tailscale-setup and doctor's Tailscale checks
#      against fake apt, systemd, Tailscale and Windows (spec §6.14)
#   4. shellcheck on every script (installed shellcheck, or the pinned image)
#   5. tests/container-smoke.sh for ubuntu:24.04 and ubuntu:26.04: provision.sh
#      --plain in a throwaway container, versions (gh from GitHub's apt
#      repository), a clean second run, and `devenv check` exiting 0.
#   6. tests/sbx-sim.sh: the kit's own install and startup snippets in a
#      container laid out like a Docker Sandbox (the devenv clone, the
#      root-to-agent handoff, ownership, skill links, GitHub's gh replacing
#      Ubuntu's, a clean re-run).
#   7. tests/keyring.sh: secrets-init, secret-get and host-prepare's unlock
#      step against a real gnome-keyring in an ubuntu:26.04 container.
# --no-containers runs only 1 to 4. --emulator-image adds
# tests/emulator-image.sh: the emulator's real image and SDK volume (downloads
# about 2.2 GB, needs about 6 GB of Docker disk).

DEVENV_TEST_IMAGES=(ubuntu:24.04 ubuntu:26.04)

# The entry points; -x follows what they source, so lib/ is checked in context.
shellcheck_targets() {
  printf '%s\n' provision.sh bin/devenv bin/devenv-entry agents/claude/statusline.sh \
    agents/claude/hooks/memory-link.sh android/emulator/launch.sh tests/*.sh tests/fakes/*
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
  local images=() containers=1 lint=1 emulator_image=0 rc=0 img results=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --image) images+=("${2:?--image needs a value}"); shift 2 ;;
      --no-containers) containers=0; shift ;;
      --no-shellcheck) lint=0; shift ;;
      --emulator-image) emulator_image=1; shift ;;
      *) die "usage: devenv test [--image IMG]... [--no-containers] [--no-shellcheck] [--emulator-image]" ;;
    esac
  done
  [ ${#images[@]} -gt 0 ] || images=("${DEVENV_TEST_IMAGES[@]}")

  echo "== status line identity"
  if bash "$DEVENV_ROOT/tests/statusline-identity.sh"; then results+=("PASS statusline identity")
  else results+=("FAIL statusline identity"); rc=1; fi

  echo "== secrets (fakes)"
  if bash "$DEVENV_ROOT/tests/secrets.sh"; then results+=("PASS secrets")
  else results+=("FAIL secrets"); rc=1; fi

  echo "== emulator (fakes)"
  if bash "$DEVENV_ROOT/tests/emulator.sh"; then results+=("PASS emulator")
  else results+=("FAIL emulator"); rc=1; fi

  echo "== tailscale (fakes)"
  if bash "$DEVENV_ROOT/tests/tailscale.sh"; then results+=("PASS tailscale")
  else results+=("FAIL tailscale"); rc=1; fi

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
    echo "== sbx simulation"
    if bash "$DEVENV_ROOT/tests/sbx-sim.sh"; then results+=("PASS sbx simulation")
    else results+=("FAIL sbx simulation"); rc=1; fi
    echo "== keyring (real gnome-keyring)"
    if bash "$DEVENV_ROOT/tests/keyring.sh"; then results+=("PASS keyring")
    else results+=("FAIL keyring"); rc=1; fi
  fi
  if [ "$emulator_image" = 1 ]; then
    have docker || die "docker is required for --emulator-image"
    echo "== emulator image (real)"
    if bash "$DEVENV_ROOT/tests/emulator-image.sh"; then results+=("PASS emulator image")
    else results+=("FAIL emulator image"); rc=1; fi
  fi

  echo
  printf '%s\n' "${results[@]}"
  return "$rc"
}
