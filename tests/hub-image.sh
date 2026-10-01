#!/usr/bin/env bash
# The Magic Conch hub's real image and model (spec §6.16), with the Docker on
# this machine: `devenv hub start` in host mode builds the image from the
# pinned source (its Python packages from the hub's uv.lock), downloads the
# pinned Whisper model (about 1.5 GB, checked against versions.env) and starts
# the container. Tailscale, sudo, systemctl and sbx are tests/fakes' (this
# machine signed in as owner@example.com), so nothing is served on a real
# tailnet. The test then talks to the real hub on its published ports as a
# phone and a session would: the owner's identity header (which tailscale
# serve would add), a session key and a pairing code from `devenv hub admin`,
# pairing, and a silent recording that the hub transcribes with the pinned
# model (offline, in its read-only container) and marks no_speech. Then stop,
# start (the data is kept) and `devenv hub clean`.
# Heavy, so `devenv test` runs it only with --hub-image.
#   tests/hub-image.sh
# pass and fail always succeed, so `test && pass || fail` is a safe if/else.
# shellcheck disable=SC2015
set -euo pipefail

ROOT=$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)
DOCKER=$(command -v docker) || { echo "docker is required" >&2; exit 1; }
W=$(mktemp -d)
mkdir -p "$W/home" "$W/bin" "$W/log" "$W/root/proc"
fails=0
pass() { printf '  ok    %s\n' "$*"; }
fail() { printf '  FAIL  %s\n' "$*"; fails=$((fails + 1)); }

# Inside a Docker Sandbox, image builds reach the network only through the
# sandbox's proxy: a docker wrapper adds it to `docker build`, and gives the
# build stage the machine's CA list (uv checks TLS against its own list
# otherwise), in the temporary context devenv made, never in the repo.
cat > "$W/bin/docker" <<EOF
#!/usr/bin/env bash
if [ "\${1:-}" = build ] && [ -n "\${HTTPS_PROXY:-\${https_proxy:-}}" ]; then
  ctx=\${*: -1}
  cp /etc/ssl/certs/ca-certificates.crt "\$ctx/ca-certificates.crt"
  sed -i '/^FROM \\\${BASE_IMAGE} AS build\$/a COPY ca-certificates.crt /usr/local/share/ca-certificates.crt\nENV SSL_CERT_FILE=/usr/local/share/ca-certificates.crt UV_NATIVE_TLS=1' "\$ctx/Dockerfile"
  shift
  exec $DOCKER build --network host --build-arg "HTTP_PROXY=\${HTTP_PROXY:-\${http_proxy:-}}" \\
    --build-arg "http_proxy=\${http_proxy:-\${HTTP_PROXY:-}}" --build-arg "HTTPS_PROXY=\${HTTPS_PROXY:-\${https_proxy:-}}" \\
    --build-arg "https_proxy=\${https_proxy:-\${HTTPS_PROXY:-}}" "\$@"
fi
exec $DOCKER "\$@"
EOF
chmod +x "$W/bin/docker"
for f in tailscale sudo systemctl sbx; do ln -s "$ROOT/tests/fakes/$f" "$W/bin/$f"; done
echo "active enabled" > "$W/log/tailscaled"
echo Running > "$W/log/ts-state"
echo '{}' > "$W/log/ts-serve.json"
echo "Linux version 6.8.0-45-generic #45-Ubuntu SMP" > "$W/root/proc/version"
free_port() { python3 -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])'; }
P=$(free_port) S=$(free_port)

# It ends with `devenv hub clean`, which removes every devenv hub image on
# this machine: refuse to run beside one.
if "$DOCKER" inspect devenv-magic-conch-hub >/dev/null 2>&1 \
   || [ -n "$("$DOCKER" image ls -q --filter label=devenv.magic-conch-hub=image)" ]; then
  echo "a devenv hub (container or image) exists here; this test would remove it. Run devenv hub clean first." >&2
  exit 1
fi

devenv() {
  env -u IS_SANDBOX -u SANDBOX_NAME -u WORKSPACE_DIR -u XDG_DATA_HOME -u XDG_CACHE_HOME HOME="$W/home" PATH="$W/bin:$PATH" \
    FAKE_LOG="$W/log" DEVENV_HOST_ROOT="$W/root" MAGIC_CONCH_PHONE_PORT="$P" MAGIC_CONCH_SESSION_PORT="$S" \
    "$ROOT/bin/devenv" "$@"
}
cleanup() { devenv hub clean >/dev/null 2>&1 || true; rm -rf "$W"; }
trap cleanup EXIT

# The pinned source, put where `hub start` looks for it, so the test needs no
# Infisical login: GitHub's tarball through gh, or (in a sandbox, whose proxy
# adds the gej-machine token) through curl.
# shellcheck source=../versions.env
. "$ROOT/versions.env"
cache=$W/home/.cache/devenv/magic-conch-hub
mkdir -p "$cache"
tgz=$cache/magic-conch-$MAGIC_CONCH_COMMIT.tar.gz
gh api "repos/$MAGIC_CONCH_REPO/tarball/$MAGIC_CONCH_COMMIT" > "$tgz" 2>/dev/null \
  || curl -fsSL -o "$tgz" "https://api.github.com/repos/$MAGIC_CONCH_REPO/tarball/$MAGIC_CONCH_COMMIT"
[ "$(sha256sum < "$tgz" | cut -d' ' -f1)" = "$MAGIC_CONCH_SHA256" ] && pass "GitHub's tarball of $MAGIC_CONCH_REPO at ${MAGIC_CONCH_COMMIT:0:12} matches MAGIC_CONCH_SHA256" \
  || fail "the tarball doesn't match MAGIC_CONCH_SHA256"

hub_call() {  # METHOD PATH [CURL ARGS...]: a call to the phone listener as the owner, through tailscale serve
  local method=$1 path=$2
  shift 2
  curl -sS -m 30 -X "$method" -H 'Magic-Conch-Protocol: 1.0' -H 'Tailscale-User-Login: owner@example.com' "$@" "http://127.0.0.1:$P$path"
}

echo "== devenv hub start (downloads the Whisper model, about 1.5 GB)"
rc=0
time devenv hub start > "$W/start.log" 2>&1 || rc=$?
sed 's/^/    /' "$W/start.log" | tail -n 20
[ "$rc" = 0 ] && grep -q 'the hub answers on 127.0.0.1' "$W/start.log" && pass "start: built, model checked, both listeners answer" || fail "start: exit $rc"
image=$("$DOCKER" image ls --filter label=devenv.magic-conch-hub=image --format '{{.Repository}}:{{.Tag}} ({{.Size}})' | head -n 1)
[ -n "$image" ] && pass "image $image" || fail "no hub image"
for _ in $(seq 60); do [ "$("$DOCKER" inspect -f '{{.State.Health.Status}}' devenv-magic-conch-hub 2>/dev/null)" = healthy ] && break; sleep 2; done
[ "$("$DOCKER" inspect -f '{{.State.Health.Status}} {{.HostConfig.ReadonlyRootfs}} {{.HostConfig.RestartPolicy.Name}} {{.Config.User}}' devenv-magic-conch-hub)" = "healthy true unless-stopped $(id -u):$(id -g)" ] \
  && pass "healthy; read-only, restarts unless stopped, runs as $(id -u):$(id -g)" || fail "container: $("$DOCKER" inspect -f '{{.State.Health.Status}} {{.HostConfig.ReadonlyRootfs}} {{.HostConfig.RestartPolicy.Name}} {{.Config.User}}' devenv-magic-conch-hub)"
ports=$("$DOCKER" port devenv-magic-conch-hub | sort | paste -sd' ' -)
[ "$ports" = "8430/tcp -> 127.0.0.1:$P 8431/tcp -> 127.0.0.1:$S" ] && pass "published on 127.0.0.1 only: $ports" || fail "ports: $ports"

echo "== the real hub"
out=$(curl -sS -m 10 -H 'Magic-Conch-Protocol: 1.0' "http://127.0.0.1:$P/v1/info")
[ "$(printf '%s' "$out" | jq -r .error.code)" = not_owner ] && pass "without Tailscale's identity header: 403 not_owner (lock 2)" || fail "no header: $out"
out=$(hub_call GET /v1/info)
[ "$(printf '%s' "$out" | jq -r .hub_label)" = devhost ] && pass "as the owner: /v1/info names the hub devhost (the machine's name)" || fail "info: $out"
key=$(devenv hub admin add-session firstmate Firstmate 2>/dev/null)
devenv hub admin default-session firstmate >/dev/null 2>&1 || true
[[ $key =~ ^mcs_[A-Za-z0-9_-]{43}$ ]] && pass "admin add-session: the key alone on stdout" || fail "add-session printed '$key'"
out=$(curl -sS -m 10 -X POST -H 'Magic-Conch-Protocol: 1.0' -H "Authorization: Bearer $key" -H 'Content-Type: application/json' \
  --data '{"connector":"devenv-test/1"}' "http://127.0.0.1:$S/v1/session/hello")
[ "$(printf '%s' "$out" | jq -r .session_id)" = firstmate ] && pass "the session listener accepts the key" || fail "hello: $out"
pc=$(devenv hub admin pairing-code 2>&1)
code=$(printf '%s\n' "$pc" | sed -n 's/^Pairing code: *//p' | tr -d ' ')
printf '%s\n' "$pc" | grep -qF "Hub URL:" && printf '%s\n' "$pc" | grep -qF "https://devhost.tail1234.ts.net:$P" && [ -n "$code" ] \
  && pass "admin pairing-code: the tailnet URL and a code" || fail "pairing-code: $pc"
dev=$(python3 -c 'import uuid; print(uuid.uuid4())')
dkey=mcd_$(python3 -c 'import base64, os; print(base64.urlsafe_b64encode(os.urandom(32)).decode().rstrip("="))')
out=$(hub_call POST /v1/pair -H 'Content-Type: application/json' \
  --data "{\"pairing_code\":\"$code\",\"device_id\":\"$dev\",\"device_key\":\"$dkey\",\"device_label\":\"Test\"}")
[ "$(printf '%s' "$out" | jq -r .device_id)" = "$dev" ] && pass "a phone pairs with the code" || fail "pair: $out"
python3 -c 'import sys, wave; w = wave.open(sys.argv[1], "wb"); w.setnchannels(1); w.setsampwidth(2); w.setframerate(16000); w.writeframes(b"\0\0" * 16000); w.close()' "$W/silence.wav"
req=$(python3 -c 'import uuid; print(uuid.uuid4())')
out=$(hub_call PUT "/v1/recordings/$req" -H "Authorization: Bearer $dkey" -H 'Content-Type: audio/wav' \
  -H "Magic-Conch-Recorded-At: $(date -u +%Y-%m-%dT%H:%M:%S.000Z)" --data-binary "@$W/silence.wav")
[ "$(printf '%s' "$out" | jq -r .result)" = accepted ] && pass "a recording is accepted" || fail "recording: $out"
status=''
for _ in $(seq 60); do
  out=$(hub_call POST /v1/sync -H "Authorization: Bearer $dkey" -H 'Content-Type: application/json' --data '{"history_after":0}')
  status=$(printf '%s' "$out" | jq -r --arg r "$req" '[.history[]? | .. | objects | select(.request_id? == $r) | .status? // empty] | last // empty')
  case "$status" in transcribing|queued|'') sleep 2 ;; *) break ;; esac
done
[ "$status" = no_speech ] && pass "the pinned model transcribed it offline, in the read-only container: no_speech" \
  || { fail "transcription ended '$status'"; "$DOCKER" logs --tail 20 devenv-magic-conch-hub 2>&1 | sed 's/^/    /'; }
data=$W/home/.local/share/magic-conch-hub
[ "$(stat -c '%a %u' "$data")" = "700 $(id -u)" ] && [ -z "$(find "$data" ! -user "$(id -u)")" ] \
  && pass "the data folder is owner-only, and everything in it is the user's" || fail "data: $(stat -c '%a %u' "$data")"

echo "== status, stop, start, clean"
devenv hub status > "$W/status.log" 2>&1 || true
sed 's/^/    /' "$W/status.log"
grep -q 'ok    running (container devenv-magic-conch-hub, healthy)' "$W/status.log" && ! grep -q 'FAIL' "$W/status.log" \
  && pass "status: no failures" || fail "status has failures"
devenv hub stop > /dev/null 2>&1
devenv hub start > "$W/restart.log" 2>&1 || true
devenv hub admin sessions > "$W/sessions.log" 2>&1 || true
grep -q firstmate "$W/sessions.log" && ! grep -q 'building the hub image' "$W/restart.log" \
  && pass "stop and start: no rebuild, and the session is still there" || fail "restart: $(cat "$W/restart.log" "$W/sessions.log")"
devenv hub clean > "$W/clean.log" 2>&1 || true
[ -z "$("$DOCKER" image ls -q --filter label=devenv.magic-conch-hub=image)" ] && ! "$DOCKER" inspect devenv-magic-conch-hub >/dev/null 2>&1 \
  && ! "$DOCKER" network inspect devenv-magic-conch-hub >/dev/null 2>&1 && [ -d "$data" ] \
  && pass "clean removed the container, image and network; the data stays" || fail "clean: $(cat "$W/clean.log")"

echo
if [ "$fails" = 0 ]; then echo "hub image: PASS"; else echo "hub image: FAIL ($fails)"; exit 1; fi
