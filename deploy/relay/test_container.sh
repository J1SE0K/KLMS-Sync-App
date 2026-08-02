#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd -P)"
DOCKER_BIN="${DOCKER_BIN:-docker}"
CLIENT_TOKEN="container-gate-client-token-not-a-secret-2026"
WORKER_TOKEN="container-gate-worker-token-not-a-secret-2026"

if ! command -v "$DOCKER_BIN" >/dev/null 2>&1; then
  printf '%s\n' "Docker is required for the relay container gate." >&2
  exit 69
fi

candidate="$(git -C "$ROOT_DIR" rev-parse --verify 'HEAD^{commit}')"
if [[ "${KLMS_CONTAINER_REQUIRE_CLEAN:-0}" == "1" ]] \
  && [[ -n "$(git -C "$ROOT_DIR" status --porcelain --untracked-files=all)" ]]; then
  printf '%s\n' "The relay container gate requires a clean worktree." >&2
  exit 65
fi

suffix="${candidate:0:12}-$$"
image_tag="${KLMS_CONTAINER_IMAGE_TAG:-klms-relay-gate:$suffix}"
container_name="klms-relay-gate-$suffix"
volume_name="klms-relay-gate-data-$suffix"

cleanup() {
  "$DOCKER_BIN" rm -f "$container_name" >/dev/null 2>&1 || true
  "$DOCKER_BIN" volume rm "$volume_name" >/dev/null 2>&1 || true
  if [[ "${KLMS_CONTAINER_KEEP_IMAGE:-0}" != "1" ]]; then
    "$DOCKER_BIN" image rm "$image_tag" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

host_sha256() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    shasum -a 256 "$1" | awk '{print $1}'
  fi
}

"$DOCKER_BIN" build --pull \
  --file "$ROOT_DIR/deploy/relay/Dockerfile" \
  --tag "$image_tag" \
  "$ROOT_DIR"

"$DOCKER_BIN" volume create "$volume_name" >/dev/null
"$DOCKER_BIN" run --detach \
  --name "$container_name" \
  --volume "$volume_name:/data" \
  --publish 127.0.0.1::18484 \
  --env KLMS_RELAY_PUBLIC_URL=http://127.0.0.1:18484 \
  --env KLMS_RELAY_CLIENT_TOKEN="$CLIENT_TOKEN" \
  --env KLMS_RELAY_WORKER_TOKEN="$WORKER_TOKEN" \
  "$image_tag" >/dev/null

mapping="$("$DOCKER_BIN" port "$container_name" 18484/tcp)"
host_port="${mapping##*:}"
if [[ ! "$host_port" =~ ^[0-9]+$ ]]; then
  printf '%s\n' "Unable to determine the published relay port: $mapping" >&2
  exit 70
fi

ready=0
for _ in $(seq 1 50); do
  if curl --fail --silent --show-error "http://127.0.0.1:$host_port/healthz" >/dev/null 2>&1; then
    ready=1
    break
  fi
  if [[ "$("$DOCKER_BIN" inspect "$container_name" --format '{{.State.Running}}')" != "true" ]]; then
    "$DOCKER_BIN" logs "$container_name" >&2
    exit 70
  fi
  sleep 0.2
done
if [[ "$ready" != "1" ]]; then
  "$DOCKER_BIN" logs "$container_name" >&2
  printf '%s\n' "Relay container did not become healthy." >&2
  exit 70
fi

"$DOCKER_BIN" exec "$container_name" /nodejs/bin/node -e \
  "fetch('http://127.0.0.1:18484/readyz',{headers:{Authorization:'Bearer '+process.env.KLMS_RELAY_WORKER_TOKEN}}).then(r=>process.exit(r.ok?0:1)).catch(()=>process.exit(1))"

container_uid="$("$DOCKER_BIN" exec "$container_name" /nodejs/bin/node -p 'process.getuid()')"
data_uid="$("$DOCKER_BIN" exec "$container_name" /nodejs/bin/node -p 'require("node:fs").statSync("/data").uid')"
image_user="$("$DOCKER_BIN" image inspect "$image_tag" --format '{{.Config.User}}')"
source_module_sha="$(host_sha256 "$ROOT_DIR/tools/klms_realtime_admission.mjs")"
image_module_sha="$("$DOCKER_BIN" exec "$container_name" /nodejs/bin/node -e 'const fs=require("node:fs");const crypto=require("node:crypto");process.stdout.write(crypto.createHash("sha256").update(fs.readFileSync("/app/tools/klms_realtime_admission.mjs")).digest("hex"))')"

if [[ "$container_uid" != "65532" || "$data_uid" != "65532" || "$image_user" != "65532" ]]; then
  printf '%s\n' "Relay container must run as uid 65532 with a writable uid-65532 data volume." >&2
  exit 70
fi
if [[ "$source_module_sha" != "$image_module_sha" ]]; then
  printf '%s\n' "Packaged realtime admission module does not match the source module." >&2
  exit 70
fi

KLMS_TEST_PORT="$host_port" KLMS_TEST_TOKEN="$CLIENT_TOKEN" node --input-type=module -e '
  import net from "node:net";
  const port = Number.parseInt(process.env.KLMS_TEST_PORT || "", 10);
  const token = process.env.KLMS_TEST_TOKEN || "";
  const websocketKey = Buffer.from("klms-gate-nonce!").toString("base64");
  const socket = net.createConnection({ host: "127.0.0.1", port });
  const timer = setTimeout(() => finish(new Error("websocket upgrade timeout")), 3_000);
  let response = "";
  let finished = false;
  function finish(error) {
    if (finished) return;
    finished = true;
    clearTimeout(timer);
    socket.destroy();
    if (error) {
      console.error(error.message);
      process.exitCode = 1;
    }
  }
  socket.once("error", finish);
  socket.on("data", (chunk) => {
    response += chunk.toString("utf8");
    if (!response.includes("\r\n\r\n")) return;
    const status = response.split("\r\n", 1)[0];
    if (!status.includes(" 101 ")) {
      finish(new Error("unexpected websocket response: " + status));
      return;
    }
    console.log("websocket_status=101");
    finish();
  });
  socket.once("connect", () => {
    socket.write([
      "GET /v1/events?role=client HTTP/1.1",
      "Host: 127.0.0.1:" + port,
      "Connection: Upgrade",
      "Upgrade: websocket",
      "Sec-WebSocket-Version: 13",
      "Sec-WebSocket-Key: " + websocketKey,
      "Authorization: Bearer " + token,
      "",
      "",
    ].join("\r\n"));
  });
'

image_id="$("$DOCKER_BIN" image inspect "$image_tag" --format '{{.Id}}')"
printf '%s\n' \
  "relay-container-summary status=pass candidate=$candidate image_id=$image_id uid=$container_uid module_sha256=$source_module_sha websocket=101"
