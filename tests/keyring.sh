#!/usr/bin/env bash
# The keyring code against a real Secret Service: gnome-keyring, secret-tool
# and busctl in a throwaway container, with only Infisical, GitHub and sbx
# faked (tests/fakes/curl, tests/fakes/sbx) and dummy values. It checks what
# the fakes in tests/secrets.sh can only assume: secrets-init stores through
# secret-tool, secret-get reads it back, a locked keyring is reported without
# opening the unlock window, and host-prepare's unlock step does ask for it.
#   tests/keyring.sh [image]
set -euo pipefail

ROOT=$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)
img=${1:-ubuntu:26.04}

env_args=()
for v in HTTP_PROXY HTTPS_PROXY NO_PROXY http_proxy https_proxy no_proxy PROXY_CA_CERT_B64; do
  [ -n "${!v:-}" ] && env_args+=(-e "$v")
done
net_args=()
[ -n "${HTTPS_PROXY:-${https_proxy:-}}" ] && net_args=(--network host)

docker run --rm "${net_args[@]}" "${env_args[@]}" \
  -v "$ROOT:/src/devenv:ro" "$img" bash /src/devenv/tests/keyring-inner.sh
