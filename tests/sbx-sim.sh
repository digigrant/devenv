#!/usr/bin/env bash
# Simulated sbx create: runs the kit's own setup.install and setup.startup
# snippets (from kits/devenv/spec.yaml) in a throwaway ubuntu:26.04 container
# laid out like a Docker Sandbox: an `agent` user with uid 1000, the workspace
# at the host-style path <home>/devenv/dev, an agent-owned
# /etc/sandbox-persistent.sh and npm prefix, node from apt. The kit clones
# devenv from a local git copy of this working tree (standing in for GitHub),
# so it tests the code on disk. It checks the clone, the root-to-agent handoff
# in provision.sh, file ownership, skill links, and a clean re-run.
#   tests/sbx-sim.sh [image]
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
  -v "$ROOT:/src/devenv:ro" "$img" bash /src/devenv/tests/sbx-sim-inner.sh
