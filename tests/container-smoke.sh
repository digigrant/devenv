#!/usr/bin/env bash
# Container smoke test (spec §6.13): run provision.sh --plain in a throwaway
# container with the repo mounted read-only, as a non-root user with sudo.
#   tests/container-smoke.sh <image>
# Inside a Docker Sandbox the container reaches the network through the
# sandbox proxy: the proxy variables and CA are passed in only when present.
set -euo pipefail

ROOT=$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)
img=${1:?usage: container-smoke.sh <image>}

env_args=()
for v in HTTP_PROXY HTTPS_PROXY NO_PROXY http_proxy https_proxy no_proxy PROXY_CA_CERT_B64; do
  [ -n "${!v:-}" ] && env_args+=(-e "$v")
done
net_args=()
# The sandbox proxy is only reachable from the VM's own network namespace.
[ -n "${HTTPS_PROXY:-${https_proxy:-}}" ] && net_args=(--network host)

docker run --rm "${net_args[@]}" "${env_args[@]}" \
  -v "$ROOT:/devenv:ro" "$img" bash /devenv/tests/container-inner.sh
