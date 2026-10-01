# The Magic Conch hub's image, built on the host by `devenv hub start`
# (lib/cmd/hub.sh) from the hub's source at the commit pinned in versions.env.
#
# The build context holds this file and the hub's folder (hub/) from GitHub's
# tarball of the private repo digigrant/magic-conch at MAGIC_CONCH_COMMIT,
# checked against MAGIC_CONCH_SHA256. The hub's Python dependencies come from
# its own uv.lock, each file checked by uv against the hash recorded there;
# the hub itself runs from its source folder, so no build backend is fetched.
# The Whisper model isn't in the image: devenv downloads it, pinned by
# sha256, and mounts it read-only at /models/whisper. So the running hub
# needs no network beyond its listeners (Hugging Face stays offline).
#
# `devenv hub start` runs it as the host user, with a read-only root file
# system, no capabilities, its data folder at /data, and both listeners
# published on the host's 127.0.0.1 only.
#
# Build arguments: BASE_IMAGE (python, pinned by digest) and UV_IMAGE (uv,
# pinned by digest), from versions.env.
ARG BASE_IMAGE=base-image-build-arg-is-required
ARG UV_IMAGE=uv-image-build-arg-is-required
FROM ${UV_IMAGE} AS uv

# The dependencies, in a virtual environment built with the base image's own
# Python (the hub's .python-version names it).
FROM ${BASE_IMAGE} AS build
COPY --from=uv /uv /usr/local/bin/uv
WORKDIR /opt/magic-conch-hub
COPY hub/pyproject.toml hub/uv.lock hub/.python-version ./
RUN UV_PYTHON_DOWNLOADS=never UV_NO_CACHE=1 UV_PROJECT_ENVIRONMENT=/opt/magic-conch-hub/venv \
    uv sync --locked --no-dev --no-install-project --compile-bytecode

FROM ${BASE_IMAGE}
COPY --from=build /opt/magic-conch-hub/venv /opt/magic-conch-hub/venv
COPY hub/src /opt/magic-conch-hub/src
ENV PATH=/opt/magic-conch-hub/venv/bin:$PATH \
    PYTHONPATH=/opt/magic-conch-hub/src \
    PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    HOME=/tmp \
    HF_HUB_OFFLINE=1 \
    HF_HUB_DISABLE_TELEMETRY=1 \
    MAGIC_CONCH_HUB_DATA_DIR=/data \
    MAGIC_CONCH_HUB_WHISPER_MODEL=/models/whisper \
    MAGIC_CONCH_HUB_PHONE_ADDRESS=0.0.0.0:8430 \
    MAGIC_CONCH_HUB_SESSION_ADDRESS=0.0.0.0:8431
# 8430 is the phone listener, 8431 the session listener. Inside the container
# they listen on every interface; devenv publishes them on the host's
# 127.0.0.1 only, on its own Docker network.
EXPOSE 8430 8431
# Healthy while both listeners accept connections.
HEALTHCHECK --interval=30s --timeout=5s --start-period=60s --start-interval=2s --retries=3 \
  CMD ["python", "-c", "import socket; [socket.create_connection(('127.0.0.1', p), 3).close() for p in (8430, 8431)]"]
ENTRYPOINT ["python", "-m", "magic_conch_hub"]
