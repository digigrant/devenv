#!/usr/bin/env bash
# devenv hub against fakes (spec §6.16): tests/fakes/{docker,tailscale,sbx,
# sudo,systemctl,curl,secret-tool,busctl} come first on PATH, with a
# temporary HOME, DEVENV_HOST_ROOT standing a folder in for / (a native Linux
# with systemd), a copy of this working tree whose pins are the sha256s of a
# small dummy source tarball and dummy model files (served by the fake curl,
# with the fake keyring and Infisical of tests/secrets.sh for the gej-machine
# token), and a tiny hub (python3) on 127.0.0.1 standing in for the
# container's published listeners. No real Docker, Tailscale, sbx, keyring,
# Infisical, GitHub or Hugging Face is touched.
#   tests/hub.sh
# pass and fail always succeed, so `test && pass || fail` is a safe if/else,
# and single-quoted $ text is meant literally.
# shellcheck disable=SC2015,SC2016
set -euo pipefail

ROOT=$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)
W=$(mktemp -d)
HUB_PID=''
cleanup() { [ -z "$HUB_PID" ] || kill "$HUB_PID" 2>/dev/null || true; rm -rf "$W"; }
trap cleanup EXIT
mkdir -p "$W/home" "$W/tmp" "$W/log" "$W/run" "$W/dl" "$W/root/run/systemd/system" "$W/root/proc"
# A copy of the working tree without .git, so doctor doesn't fetch.
(cd "$ROOT" && git ls-files -co --exclude-standard -z | xargs -0 cp --parents -t "$W/run" 2>/dev/null) \
  || cp -r "$ROOT/." "$W/run"
rm -rf "$W/run/dev" "$W/run/.git"
DEV=$W/run/bin/devenv
echo "Linux version 6.8.0-45-generic (buildd@lcy02-amd64-075) #45-Ubuntu SMP" > "$W/root/proc/version"
free_port() { python3 -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])'; }
P=$(free_port)
S=$(free_port)
while [ "$S" = "$P" ]; do S=$(free_port); done
URL=https://devhost.tail1234.ts.net:$P

export FAKE_LOG=$W/log
export FAKE_PROJECT_ID=fake-project-5f1e0c
export FAKE_CLIENT_ID=fake-client-id-8c2d41
export FAKE_CLIENT_SECRET=fake-client-secret-91ab77
export FAKE_ACCESS_TOKEN=fake-access-token-77aa03
export FAKE_GITHUB=ghp_FAKEfakeFAKEfakeFAKEfakeFAKEfake0001
export FAKE_CLAUDE=sk-ant-oat01-FAKEfakeFAKEfakeFAKEfake0002

# The dummy source tarball (laid out like GitHub's) and model files, and pins
# that match them.
COMMIT=$(sed -n 's/^MAGIC_CONCH_COMMIT=//p' "$W/run/versions.env")
make_tarball() {  # COMMIT [broken]
  local t=$W/tarball top=digigrant-magic-conch-$1
  rm -rf "$t"; mkdir -p "$t/$top/hub/src/magic_conch_hub" "$t/$top/android"
  if [ "${2:-}" != broken ]; then
    printf '[project]\nname = "magic-conch-hub"\n' > "$t/$top/hub/pyproject.toml"
    printf 'version = 1\n' > "$t/$top/hub/uv.lock"
  fi
  echo 3.14 > "$t/$top/hub/.python-version"
  echo 'print("hub")' > "$t/$top/hub/src/magic_conch_hub/__main__.py"
  echo app > "$t/$top/android/build.gradle.kts"
  tar -czf "$W/dl/tarball-$1.tar.gz" -C "$t" "$top"
  sha256sum < "$W/dl/tarball-$1.tar.gz" | cut -d' ' -f1
}
sed -i "s/^MAGIC_CONCH_SHA256=.*/MAGIC_CONCH_SHA256=$(make_tarball "$COMMIT")/" "$W/run/versions.env"
files=''
for f in config.json model.bin tokenizer.json vocabulary.txt; do
  printf 'dummy %s\n' "$f" > "$W/dl/$f"
  files+="$f:$(sha256sum < "$W/dl/$f" | cut -d' ' -f1) "
done
sed -i "s/^MAGIC_CONCH_WHISPER_FILES=.*/MAGIC_CONCH_WHISPER_FILES=\"${files% }\"/" "$W/run/versions.env"
MODEL=$W/home/.local/share/devenv/whisper/faster-whisper-medium.en-a29b04bd1538
DATA=$W/home/.local/share/magic-conch-hub

fails=0
pass() { printf '  ok    %s\n' "$*"; }
fail() { printf '  FAIL  %s\n' "$*"; fails=$((fails + 1)); }

# Tailscale installed, running and signed in, with nothing served.
signed_in() {
  echo "active enabled" > "$FAKE_LOG/tailscaled"
  echo Running > "$FAKE_LOG/ts-state"
  echo '{}' > "$FAKE_LOG/ts-serve.json"
}
signed_in

# run VAR=VALUE... -- ARGS: devenv on the host (no sandbox variables), with
# the fakes first on PATH. Sets OUT, ERR, RC.
run() {
  local envs=()
  while [ "$1" != -- ]; do envs+=("$1"); shift; done
  shift
  : > "$FAKE_LOG/argv"
  RC=0
  env -i HOME="$W/home" TMPDIR="$W/tmp" PATH="$ROOT/tests/fakes:/usr/local/bin:/usr/bin:/bin" \
    XDG_RUNTIME_DIR="$W/tmp" DEVENV_HOST_ROOT="$W/root" FAKE_LOG="$FAKE_LOG" FAKE_DOWNLOADS="$W/dl" \
    FAKE_PROJECT_ID="$FAKE_PROJECT_ID" FAKE_CLIENT_ID="$FAKE_CLIENT_ID" FAKE_CLIENT_SECRET="$FAKE_CLIENT_SECRET" \
    FAKE_ACCESS_TOKEN="$FAKE_ACCESS_TOKEN" FAKE_GITHUB="$FAKE_GITHUB" FAKE_CLAUDE="$FAKE_CLAUDE" \
    DEVENV_HUB_POLL=0 DEVENV_HUB_START_TIMEOUT=5 DEVENV_HUB_PROBE_TIMEOUT=3 \
    MAGIC_CONCH_PHONE_PORT="$P" MAGIC_CONCH_SESSION_PORT="$S" "${envs[@]}" \
    bash "$DEV" "$@" > "$W/out" 2> "$W/err" < /dev/null || RC=$?
  OUT=$(cat "$W/out"); ERR=$(cat "$W/err")
}
called() { grep -qF -- "$1" "$FAKE_LOG/argv"; }
section() { printf '%s\n' "$OUT" | sed -n '/^Magic Conch hub/,/^Operating rule/p'; }
run_argv() { cat "$FAKE_LOG/docker/containers/devenv-magic-conch-hub.argv" 2>/dev/null | paste -sd' ' -; }

# hub [OWNER]: answer like the hub's two listeners on 127.0.0.1:$P (the
# phone listener: 403 not_owner unless Tailscale's identity header names
# OWNER, default owner@example.com) and :$S (the session listener: 401
# without a key); stop it with "hub off".
hub() {
  [ -z "$HUB_PID" ] || { kill "$HUB_PID" 2>/dev/null || true; wait "$HUB_PID" 2>/dev/null || true; HUB_PID=''; }
  [ "${1:-}" != off ] || return 0
  python3 -c '
import json, sys, threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
owner, phone, session = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
def handler(kind):
    class H(BaseHTTPRequestHandler):
        def answer(self):
            if kind == "phone" and self.headers.get("Tailscale-User-Login") != owner:
                status, body = 403, {"error": {"code": "not_owner", "message": "not the owner"}}
            elif kind == "phone" and self.path == "/v1/info":
                status, body = 200, {"hub_id": "x", "hub_label": "devhost", "protocol_version": "1.0"}
            else:
                status, body = 401, {"error": {"code": "session_key_invalid" if kind == "session" else "not_paired", "message": "no key"}}
            data = json.dumps(body).encode()
            self.send_response(status)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(data)))
            self.send_header("Magic-Conch-Protocol", "1.0")
            self.end_headers()
            self.wfile.write(data)
        do_GET = do_POST = answer
        def log_message(self, *a): pass
    return H
servers = [ThreadingHTTPServer(("127.0.0.1", p), handler(k)) for p, k in ((phone, "phone"), (session, "session"))]
for s in servers[1:]:
    threading.Thread(target=s.serve_forever, daemon=True).start()
servers[0].serve_forever()
' "${1:-owner@example.com}" "$P" "$S" &
  HUB_PID=$!
  for _ in $(seq 50); do (exec 3<>"/dev/tcp/127.0.0.1/$S") 2>/dev/null && return 0; sleep 0.1; done
  echo "the fake hub did not start" >&2; exit 1
}

echo "host: start"
hub
run FAKE_SBX_POLICY_ALLOW="localhost:15555" -- hub start
if [ "$RC" = 0 ] && printf '%s' "$ERR" | grep -qF "the hub answers on 127.0.0.1:$P (phones) and 127.0.0.1:$S (sessions)"; then
  pass "start: builds, downloads the model, starts, waits for both listeners"
else fail "start: exit $RC, stderr: $ERR"; fi
called "curl -fsSL --retry 3 --connect-timeout 20 -H @- -o $W/home/.cache/devenv/magic-conch-hub/magic-conch-$COMMIT.tar.gz.part https://api.github.com/repos/digigrant/magic-conch/tarball/$COMMIT" \
  && pass "the source: GitHub's tarball of the pinned commit, the token as a header on stdin" || fail "tarball download: $(grep tarball "$FAKE_LOG/argv")"
if grep -qF -- "$FAKE_GITHUB" "$FAKE_LOG/argv" || grep -rqF -- "$FAKE_GITHUB" "$W/home" "$W/tmp" 2>/dev/null; then
  fail "the gej-machine token appeared in a command's arguments or a file"
else pass "the gej-machine token appears in no command's arguments and no file"; fi
[ "$(cat "$FAKE_LOG/docker/context")" = "$(printf '%s\n' ./Dockerfile ./hub/.python-version ./hub/pyproject.toml ./hub/src/magic_conch_hub/__main__.py ./hub/uv.lock)" ] \
  && cmp -s "$FAKE_LOG/docker/../docker/context" "$FAKE_LOG/docker/context" \
  && pass "the build context: devenv's Dockerfile and the tarball's hub/ folder only" || fail "build context: $(cat "$FAKE_LOG/docker/context")"
called 'docker build -q -t devenv-magic-conch-hub:' && called '--label devenv.magic-conch-hub=image --build-arg BASE_IMAGE=python:3.14-slim-trixie@sha256:' \
  && called '--build-arg UV_IMAGE=ghcr.io/astral-sh/uv:' \
  && pass "the image is built from the pinned base and uv images" || fail "docker build: $(grep 'docker build' "$FAKE_LOG/argv")"
[ -z "$(ls -A "$W/home/.cache/devenv/magic-conch-hub")" ] && pass "the tarball is deleted once built" || fail "left in the cache: $(ls "$W/home/.cache/devenv/magic-conch-hub")"
[ "$(ls "$MODEL")" = "$(printf '%s\n' config.json model.bin tokenizer.json vocabulary.txt)" ] && [ -s "$MODEL/.devenv-model" ] \
  && called "curl -fsSL --retry 3 --connect-timeout 20 -o $MODEL/model.bin.part https://huggingface.co/Systran/faster-whisper-medium.en/resolve/a29b04bd15381511a9af671baec01072039215e3/model.bin" \
  && pass "the Whisper model: each file from the pinned revision, checked" || fail "model: $(ls -A "$MODEL" 2>&1)"
[ "$(stat -c %a "$DATA")" = 700 ] && pass "the data folder is made owner-only" || fail "data folder: $(stat -c %a "$DATA" 2>&1)"
called 'docker network create --label devenv.magic-conch-hub=network devenv-magic-conch-hub' && pass "its own Docker network" || fail "network: $(grep network "$FAKE_LOG/argv")"
args=$(run_argv)
want="-d --name devenv-magic-conch-hub --init --restart unless-stopped --network devenv-magic-conch-hub --user $(id -u):$(id -g) --read-only --tmpfs /tmp --cap-drop ALL --security-opt no-new-privileges --log-driver local -p 127.0.0.1:$P:8430 -p 127.0.0.1:$S:8431 --mount type=bind,src=$DATA,dst=/data --mount type=bind,src=$MODEL,dst=/models/whisper,readonly -e MAGIC_CONCH_HUB_OWNER_LOGIN=owner@example.com -e MAGIC_CONCH_HUB_URL=$URL -e MAGIC_CONCH_HUB_LABEL=devhost --label devenv.magic-conch-hub=container --label devenv.magic-conch-hub.config="
case "$args" in
  "run $want"*) pass "docker run: the host user, read-only, no capabilities, both listeners on 127.0.0.1 only, the data and model, the owner and URL from Tailscale, back at boot" ;;
  *) fail "docker run: $args" ;;
esac
called "sudo tailscale serve --bg --https=$P http://127.0.0.1:$P" \
  && printf '%s' "$ERR" | grep -qF "tailscale serve publishes $URL to the phone listener" \
  && pass "tailscale serve publishes the phone listener over HTTPS on the tailnet" || fail "serve: $(grep serve "$FAKE_LOG/argv"), stderr: $ERR"
printf '%s' "$ERR" | grep -qF "sandboxes can't reach the session listener: allow it once with: sbx policy allow network localhost:$S" \
  && printf '%s' "$ERR" | grep -qF "sandboxes can't reach the phone listener (localhost:$P is denied)" \
  && pass "no policy rule yet: prints the exact sbx policy allow command, and the phone port stays denied" || fail "policy lines: $ERR"

run FAKE_SBX_POLICY_ALLOW="localhost:$S" -- hub start
[ "$RC" = 0 ] && printf '%s' "$ERR" | grep -q 'the hub is already running' && ! called 'docker run -d' && ! called 'docker build' \
  && ! called 'sudo' && ! called 'huggingface.co' && ! called 'api.github.com' \
  && pass "start again: nothing to do, no sudo, no download" || fail "second start: exit $RC, stderr: $ERR"

echo "host: status and doctor"
run FAKE_SBX_POLICY_ALLOW="localhost:$S" -- hub status
if [ "$RC" = 0 ] && printf '%s' "$OUT" | grep -qF "ok    running (container devenv-magic-conch-hub, healthy)" \
   && printf '%s' "$OUT" | grep -qF "ok    the phone listener answers on 127.0.0.1:$P" \
   && printf '%s' "$OUT" | grep -qF "ok    the session listener answers on 127.0.0.1:$S" \
   && printf '%s' "$OUT" | grep -qF "ok    $URL reaches the hub through tailscale serve, and the hub accepts your login (owner@example.com)" \
   && printf '%s' "$OUT" | grep -qF "ok    sandbox dev may reach the session listener (the network policy allows localhost:$S)" \
   && printf '%s' "$OUT" | grep -qF "ok    data folder $DATA, owner-only"; then
  pass "status: running, both listeners, through the tailnet as the owner, the policy"
else fail "status: exit $RC, output: $OUT"; fi
run FAKE_SBX_POLICY_ALLOW="localhost:$S localhost:$P" -- hub status
[ "$RC" = 1 ] && printf '%s' "$OUT" | grep -qF "FAIL  the network policy lets sandboxes reach localhost:$P, the hub's phone listener, which only tailscale serve may reach" \
  && pass "status: a policy rule for the phone port is a failure" || fail "phone port allowed: exit $RC, output: $OUT"
run FAKE_DOCKER_ENABLED=disabled FAKE_SBX_POLICY_ALLOW="localhost:$S" -- hub status
printf '%s' "$OUT" | grep -qF "warn  Docker doesn't start at boot, so the hub won't either; run: sudo systemctl enable docker" \
  && pass "status: Docker not enabled at boot is a warning" || fail "docker at boot: $OUT"
hub other@example.com
run FAKE_SBX_POLICY_ALLOW="localhost:$S" -- hub status
[ "$RC" = 1 ] && printf '%s' "$OUT" | grep -qF "FAIL  $URL reaches the hub, but it refuses your login" \
  && pass "status: a hub that refuses the owner through tailscale serve is a failure" || fail "login refused: exit $RC, output: $OUT"
hub
run -- doctor --host
section | grep -qF "ok    running (container devenv-magic-conch-hub, healthy)" \
  && section | grep -qF "warn  sandboxes can't reach the session listener: allow it once with: sbx policy allow network localhost:$S" \
  && pass "doctor --host: a Magic Conch hub section" || fail "doctor's hub section: $(section)"
chmod 755 "$DATA"
run -- hub status
[ "$RC" = 1 ] && printf '%s' "$OUT" | grep -qF "FAIL  $DATA is mode 755, not owner-only (700)" \
  && pass "status: a data folder others can read is a failure" || fail "data mode: exit $RC, output: $OUT"
run -- hub start
[ "$(stat -c %a "$DATA")" = 700 ] && printf '%s' "$ERR" | grep -qF "made $DATA owner-only (it was 755)" \
  && pass "start makes it owner-only again" || fail "data mode fix: $(stat -c %a "$DATA"), stderr: $ERR"

echo "host: admin"
run -- hub admin add-session firstmate Firstmate
[ "$RC" = 0 ] && [ "$OUT" = mcs_FAKEsessionKEYfakeSESSIONkey0000000000000 ] && printf '%s' "$ERR" | grep -q 'Session firstmate added' \
  && called 'docker exec devenv-magic-conch-hub python -m magic_conch_hub.admin add-session firstmate Firstmate' \
  && pass "admin: the tool runs in the container; a session key is alone on stdout" || fail "admin: exit $RC, stdout '$OUT', stderr: $ERR"

echo "host: changes"
run FAKE_TS_LOGIN=new-owner@example.com -- hub start
[ "$RC" = 0 ] && printf '%s' "$ERR" | grep -q 'replacing the hub.s container' && called 'docker run -d' \
  && run_argv | grep -qF -- '-e MAGIC_CONCH_HUB_OWNER_LOGIN=new-owner@example.com' \
  && pass "another Tailscale login: the container is replaced, its data kept" || fail "new login: exit $RC, stderr: $ERR"
run -- hub start
sed -i "s/^MAGIC_CONCH_COMMIT=.*/MAGIC_CONCH_COMMIT=1111111111111111111111111111111111111111/" "$W/run/versions.env"
sed -i "s/^MAGIC_CONCH_SHA256=.*/MAGIC_CONCH_SHA256=$(make_tarball 1111111111111111111111111111111111111111)/" "$W/run/versions.env"
old=$(docker_images() { cat "$FAKE_LOG"/docker/images/* 2>/dev/null | grep '^devenv-magic-conch-hub:'; }; docker_images)
run -- hub start
new=$(cat "$FAKE_LOG"/docker/images/* 2>/dev/null | grep '^devenv-magic-conch-hub:')
[ "$RC" = 0 ] && called 'docker build' && [ "$new" != "$old" ] && printf '%s' "$ERR" | grep -qF "removed the hub image $old" \
  && ! called 'huggingface.co' && pass "a new commit pin: a new image, the old one removed, the model kept" || fail "new pin: exit $RC, stderr: $ERR"

echo "host: failures"
cp "$FAKE_LOG/ts-serve.json" "$W/serve-ok.json"
jq --arg k "devhost.tail1234.ts.net:$P" '.AllowFunnel = {($k): true}' "$W/serve-ok.json" > "$FAKE_LOG/ts-serve.json"
run -- hub start
[ "$RC" = 1 ] && printf '%s' "$ERR" | grep -qF "Tailscale Funnel is on for port $P" && ! called 'docker run' \
  && pass "Funnel on the phone port: refused" || fail "funnel: exit $RC, stderr: $ERR"
run -- hub status
[ "$RC" = 1 ] && printf '%s' "$OUT" | grep -qF "FAIL  Tailscale Funnel is on for port $P" && pass "status: Funnel is a failure" || fail "funnel status: $OUT"
jq --arg s "$S" '.TCP[$s] = {HTTPS: true}' "$W/serve-ok.json" > "$FAKE_LOG/ts-serve.json"
run -- hub start
[ "$RC" = 1 ] && printf '%s' "$ERR" | grep -qF "tailscale serve publishes the hub's session listener (port $S)" \
  && pass "the session port on the tailnet: refused" || fail "session served: exit $RC, stderr: $ERR"
jq --arg k "devhost.tail1234.ts.net:$P" '.Web[$k].Handlers["/"].Proxy = "http://127.0.0.1:3000"' "$W/serve-ok.json" > "$FAKE_LOG/ts-serve.json"
run -- hub start
[ "$RC" = 1 ] && printf '%s' "$ERR" | grep -qF "tailscale serve already sends https port $P to http://127.0.0.1:3000 instead of the hub" \
  && pass "the phone port served to something else: refused, not overwritten" || fail "other target: exit $RC, stderr: $ERR"
cp "$W/serve-ok.json" "$FAKE_LOG/ts-serve.json"
echo NeedsLogin > "$FAKE_LOG/ts-state"
run -- hub start
[ "$RC" = 1 ] && printf '%s' "$ERR" | grep -qF "this machine isn't signed in to Tailscale (NeedsLogin)" && pass "not signed in to Tailscale: refused" || fail "not signed in: exit $RC, stderr: $ERR"
signed_in; cp "$W/serve-ok.json" "$FAKE_LOG/ts-serve.json"
run FAKE_TS_MAGICDNS=false -- hub start
[ "$RC" = 1 ] && printf '%s' "$ERR" | grep -q 'MagicDNS is off for the tailnet' && pass "MagicDNS off: refused" || fail "MagicDNS: exit $RC, stderr: $ERR"
run FAKE_TS_HTTPS=0 -- hub start
[ "$RC" = 1 ] && printf '%s' "$ERR" | grep -q 'HTTPS certificates are off for the tailnet' && pass "HTTPS certificates off: refused" || fail "HTTPS: exit $RC, stderr: $ERR"
run FAKE_TS_TAGGED=1 -- hub start
[ "$RC" = 1 ] && printf '%s' "$ERR" | grep -q 'this machine is a tagged device' && pass "a tagged machine (no owner login): refused" || fail "tagged: exit $RC, stderr: $ERR"
run FAKE_DOCKER_OS='Docker Desktop' -- hub start
[ "$RC" = 1 ] && printf '%s' "$ERR" | grep -q 'Docker Desktop, which publishes ports on Windows' && pass "Docker Desktop: refused, with the reason" || fail "Docker Desktop: exit $RC, stderr: $ERR"
run MAGIC_CONCH_SESSION_PORT="$P" -- hub start
[ "$RC" = 1 ] && printf '%s' "$ERR" | grep -q 'MAGIC_CONCH_PHONE_PORT and MAGIC_CONCH_SESSION_PORT in devenv.conf must differ' \
  && pass "bad settings: refused" || fail "same ports: exit $RC, stderr: $ERR"
run SANDBOX_NAME=dev IS_SANDBOX=1 WORKSPACE_DIR="$W/ws" -- hub start
[ "$RC" = 1 ] && printf '%s' "$ERR" | grep -q 'runs on the host, not in a sandbox' && pass "start inside a sandbox: refused" || fail "start in a sandbox: exit $RC, stderr: $ERR"
run -- hub stop
run FAKE_DOCKER_RUN_FAIL=port -- hub start
[ "$RC" = 1 ] && printf '%s' "$ERR" | grep -qF "a port on 127.0.0.1 is taken ($P or $S)" && called 'docker rm -f devenv-magic-conch-hub' \
  && pass "a taken port: says so, and removes the half-made container" || fail "taken port: exit $RC, stderr: $ERR"
run FAKE_DOCKER_BOOT=exit -- hub start
[ "$RC" = 1 ] && printf '%s' "$ERR" | grep -q 'MAGIC_CONCH_HUB_OWNER_LOGIN must name' && printf '%s' "$ERR" | grep -q 'the hub stopped while starting (exited)' \
  && pass "a hub that dies while starting: shows its log" || fail "start failure: exit $RC, stderr: $ERR"
run -- hub stop
hub off
run DEVENV_HUB_START_TIMEOUT=0 -- hub start
[ "$RC" = 1 ] && printf '%s' "$ERR" | grep -q "the hub's listeners didn't answer within 0 seconds" && pass "listeners that never answer: a timeout" || fail "no answer: exit $RC, stderr: $ERR"
hub
sed -i "s/^MAGIC_CONCH_COMMIT=.*/MAGIC_CONCH_COMMIT=2222222222222222222222222222222222222222/" "$W/run/versions.env"
make_tarball 2222222222222222222222222222222222222222 >/dev/null
run -- hub start
[ "$RC" = 1 ] && printf '%s' "$ERR" | grep -q 'sha256 mismatch for digigrant/magic-conch at 2222' && ! called 'docker build' \
  && [ -z "$(ls -A "$W/home/.cache/devenv/magic-conch-hub")" ] && pass "a tarball that doesn't match its pin: nothing built, nothing kept" || fail "sha mismatch: exit $RC, stderr: $ERR"
sed -i "s/^MAGIC_CONCH_SHA256=.*/MAGIC_CONCH_SHA256=$(make_tarball 2222222222222222222222222222222222222222 broken)/" "$W/run/versions.env"
run -- hub start
[ "$RC" = 1 ] && printf '%s' "$ERR" | grep -q 'has no hub/ folder with uv.lock' && ! called 'docker build' && pass "a tarball without the hub's files: refused" || fail "broken tarball: exit $RC, stderr: $ERR"
sed -i "s/^MAGIC_CONCH_SHA256=.*/MAGIC_CONCH_SHA256=$(make_tarball 2222222222222222222222222222222222222222)/" "$W/run/versions.env"
run FAKE_KR_STATE=locked -- hub start
[ "$RC" = 1 ] && printf '%s' "$ERR" | grep -q 'the keyring is locked and no window can ask for its password here' && ! called 'api.github.com' \
  && pass "a locked keyring without a display: stops before downloading" || fail "locked keyring: exit $RC, stderr: $ERR"
run FAKE_READ_CODE=404 -- hub start
[ "$RC" = 1 ] && printf '%s' "$ERR" | grep -q 'fetching GITHUB_GEJ_MACHINE_PAT failed: Infisical has no GITHUB_GEJ_MACHINE_PAT' \
  && pass "no token from Infisical: says why" || fail "no token: exit $RC, stderr: $ERR"

echo "host: stop and clean"
run -- hub start
run -- hub stop
[ "$RC" = 0 ] && called 'docker stop -t 30 devenv-magic-conch-hub' && [ ! -e "$FAKE_LOG/docker/containers/devenv-magic-conch-hub" ] && [ -d "$DATA" ] \
  && pass "stop: removes the container; the data stays" || fail "stop: exit $RC, stderr: $ERR"
run -- hub admin sessions
[ "$RC" = 1 ] && printf '%s' "$ERR" | grep -q "the hub isn't running; start it: devenv hub start" && pass "admin when stopped: says to start it" || fail "admin stopped: exit $RC, stderr: $ERR"
run -- hub status
[ "$RC" = 0 ] && printf '%s' "$OUT" | grep -qF 'note  not running (devenv hub start)' && pass "status when stopped: a note" || fail "stopped status: exit $RC, output: $OUT"
touch "$DATA/hub.db"
run -- hub clean
[ "$RC" = 0 ] && [ -z "$(ls "$FAKE_LOG/docker/images")" ] && [ -z "$(ls "$FAKE_LOG/docker/networks")" ] \
  && [ ! -e "$W/home/.local/share/devenv/whisper" ] && called "sudo tailscale serve --https=$P off" && [ -f "$DATA/hub.db" ] \
  && pass "clean: images, network, model and tailscale serve's entry removed; the data stays" || fail "clean: exit $RC, stderr: $ERR"

echo "sandbox and plain mode"
run -- hub status
run SANDBOX_NAME=dev IS_SANDBOX=1 WORKSPACE_DIR="$W/ws" FAKE_SBX_POLICY_ALLOW="localhost:$S" -- hub status
[ "$RC" = 0 ] && printf '%s' "$OUT" | grep -qF "ok    the hub's session listener answers at http://host.docker.internal:$S" \
  && printf '%s' "$OUT" | grep -qF "ok    the hub's phone listener is out of this sandbox's reach" \
  && pass "in a sandbox: the session listener answers, the phone listener is out of reach" || fail "sandbox status: exit $RC, output: $OUT"
run SANDBOX_NAME=dev IS_SANDBOX=1 WORKSPACE_DIR="$W/ws" -- hub status
printf '%s' "$OUT" | grep -qF "note  no hub reachable: the network policy doesn't let this sandbox reach localhost:$S" \
  && pass "in a sandbox without the rule: a note with the host's command" || fail "sandbox without rule: $OUT"
run SANDBOX_NAME=dev IS_SANDBOX=1 WORKSPACE_DIR="$W/ws" FAKE_SBX_POLICY_ALLOW="localhost:$S localhost:$P" -- hub status
[ "$RC" = 1 ] && printf '%s' "$OUT" | grep -qF "FAIL  the network policy lets this sandbox reach localhost:$P, the hub's phone listener" \
  && pass "in a sandbox that can reach the phone listener: a failure" || fail "sandbox phone reach: exit $RC, output: $OUT"
mkdir -p "$W/ws"
run SANDBOX_NAME=dev IS_SANDBOX=1 WORKSPACE_DIR="$W/ws" FAKE_SBX_POLICY_ALLOW="localhost:$S" -- check
printf '%s' "$OUT" | grep -qF "the Magic Conch hub answers at http://host.docker.internal:$S" && ! printf '%s' "$OUT" | grep -q '⚠ .*Magic Conch' \
  && pass "check in a sandbox: a note while the hub answers" || fail "check with hub: $OUT"
hub off
run SANDBOX_NAME=dev IS_SANDBOX=1 WORKSPACE_DIR="$W/ws" FAKE_SBX_POLICY_ALLOW="localhost:$S" -- check
printf '%s' "$OUT" | grep -qF "⚠ the Magic Conch hub doesn't answer at host.docker.internal:$S, although the network policy allows it; on the host: devenv hub start" \
  && grep -qF "the Magic Conch hub doesn't answer" "$W/home/.cache/devenv/warnings" \
  && pass "check in a sandbox: a warning when the policy allows the hub but it doesn't answer" || fail "check without hub: $OUT"
run SANDBOX_NAME=dev IS_SANDBOX=1 WORKSPACE_DIR="$W/ws" -- check
! grep -q 'Magic Conch' "$W/home/.cache/devenv/warnings" && pass "check in a sandbox without the rule: no warning (no hub on this host)" || fail "check no rule: $(cat "$W/home/.cache/devenv/warnings")"
run SANDBOX_NAME=dev IS_SANDBOX=1 WORKSPACE_DIR="$W/ws" FAKE_SBX_POLICY_ALLOW="localhost:$P" -- check
grep -qF "this sandbox can reach the Magic Conch hub's phone listener (localhost:$P)" "$W/home/.cache/devenv/warnings" \
  && pass "check in a sandbox: a warning when the phone listener is within reach" || fail "check phone: $(cat "$W/home/.cache/devenv/warnings")"
run -- hub status
if [ -n "${SANDBOX_NAME:-}" ] && [ -n "${http_proxy:-}" ]; then
  # Inside a Docker Sandbox, with the real curl: this sandbox's proxy answers
  # for the default ports.
  run SANDBOX_NAME=dev IS_SANDBOX=1 WORKSPACE_DIR="$W/ws" PATH=/usr/local/bin:/usr/bin:/bin http_proxy="$http_proxy" \
    MAGIC_CONCH_PHONE_PORT=8430 MAGIC_CONCH_SESSION_PORT=8431 -- hub status
  line=$(printf '%s\n' "$OUT" | grep -E '8431' || true)
  printf '%s' "$line" | grep -qE "no hub reachable: the network policy doesn't let this sandbox reach localhost:8431|session listener answers at http://host.docker.internal:8431|no hub answers there" \
    && printf '%s' "$OUT" | grep -qF "ok    the hub's phone listener is out of this sandbox's reach" \
    && pass "live, through this sandbox's proxy:${line#  note  }" || fail "live status: exit $RC, output: $OUT"
fi

echo
if [ "$fails" = 0 ]; then echo "hub: PASS"; else echo "hub: FAIL ($fails)"; exit 1; fi
