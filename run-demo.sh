#!/usr/bin/env bash
#
# Builds both apps, starts them under a deliberately small heap, generates a
# file that is much LARGER than that heap, uploads it through the gateway, and
# prints the result. If the pipeline buffered the body anywhere it would hit
# OutOfMemoryError and the JVM would exit (-XX:+ExitOnOutOfMemoryError); a
# successful run with bytesReceived >> jvmMaxHeapMB proves it streamed.
#
# Tunables (env vars):
#   HEAP=128m       max heap for BOTH the gateway and the backend
#   SIZE_MB=1024    size of the test upload in MB (default 1 GB = 8x the heap)
#
set -euo pipefail

HEAP="${HEAP:-128m}"
SIZE_MB="${SIZE_MB:-1024}"

ROOT="$(cd "$(dirname "$0")" && pwd)"
WORK="$(mktemp -d)"
BIGFILE="$WORK/upload.bin"
GATEWAY_LOG="$WORK/gateway.log"
BACKEND_LOG="$WORK/backend.log"
GATEWAY_PID=""
BACKEND_PID=""

cleanup() {
  [ -n "$BACKEND_PID" ] && kill "$BACKEND_PID" 2>/dev/null || true
  [ -n "$GATEWAY_PID" ] && kill "$GATEWAY_PID" 2>/dev/null || true
  rm -rf "$WORK"
}
trap cleanup EXIT

echo "==> Building (mvn -q package -DskipTests)"
(cd "$ROOT" && mvn -q -DskipTests package)

JAVA_OPTS="-Xmx${HEAP} -XX:+ExitOnOutOfMemoryError"
echo "==> Starting backend  (:8081, heap ${HEAP})"
# shellcheck disable=SC2086
java $JAVA_OPTS -jar "$ROOT/backend/target/backend-0.0.1-SNAPSHOT.jar" >"$BACKEND_LOG" 2>&1 &
BACKEND_PID=$!
echo "==> Starting gateway  (:8080, heap ${HEAP})"
# shellcheck disable=SC2086
java $JAVA_OPTS -jar "$ROOT/gateway/target/gateway-0.0.1-SNAPSHOT.jar" >"$GATEWAY_LOG" 2>&1 &
GATEWAY_PID=$!

wait_up() { # $1=url  $2=name
  for _ in $(seq 1 60); do
    if curl -s -o /dev/null "$1"; then echo "    $2 is up"; return 0; fi
    if ! kill -0 "$3" 2>/dev/null; then echo "!! $2 died on startup:"; tail -n 40 "$4"; exit 1; fi
    sleep 1
  done
  echo "!! $2 did not come up in time:"; tail -n 40 "$4"; exit 1
}
echo "==> Waiting for services"
wait_up "http://localhost:8081/upload" backend "$BACKEND_PID" "$BACKEND_LOG"
wait_up "http://localhost:8080/upload" gateway "$GATEWAY_PID" "$GATEWAY_LOG"

echo "==> Generating a ${SIZE_MB} MB test file"
dd if=/dev/zero of="$BIGFILE" bs=1048576 count="$SIZE_MB" status=none
echo "    $(ls -lh "$BIGFILE" | awk '{print $5}')  ->  heap cap is ${HEAP}"

echo "==> POST ${SIZE_MB} MB through the gateway (:8080) -> backend (:8081)"
echo "----------------------------------------------------------------------"
curl -sS -X POST -T "$BIGFILE" \
     -H "Content-Type: application/octet-stream" \
     http://localhost:8080/upload
echo
echo "----------------------------------------------------------------------"

if kill -0 "$GATEWAY_PID" 2>/dev/null && kill -0 "$BACKEND_PID" 2>/dev/null; then
  echo "==> PASS: both JVMs survived with -Xmx${HEAP} while a ${SIZE_MB} MB body streamed through."
else
  echo "==> FAIL: a JVM exited (likely OutOfMemoryError). Logs:"
  echo "--- gateway ---"; tail -n 30 "$GATEWAY_LOG"
  echo "--- backend ---"; tail -n 30 "$BACKEND_LOG"
  exit 1
fi
