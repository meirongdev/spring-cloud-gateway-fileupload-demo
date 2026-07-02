#!/usr/bin/env bash
# Automated verification of the h2c-upgrade 413 theory, with PASS/FAIL asserts.
#
# Theory: the upload backend enables h2c (SERVER_HTTP2_ENABLED=true); the gateway's
# JDK HttpClient prefers HTTP/2 and sends `Upgrade: h2c` on the FIRST request
# of every cold connection; Tomcat must buffer the body of an upgrade request
# (RFC 7230) but caps it at maxSavePostSize=4KB and rejects bigger bodies with
# a connector-level 413. Warm HTTP/2 connections stream uploads fine; Tomcat
# closes idle h2 connections after 20s, re-arming the trap.
#
# T1  cold gateway pod, first request = 3MB upload  -> 413
# T2  2KB upload (fits 4KB save buffer)             -> 200 over HTTP/2.0
# T3  3MB upload right after (warm h2 conn)         -> 200 over HTTP/2.0
# T4  idle 45s (> Tomcat h2 keepAliveTimeout=20s),
#     then 3MB                                      -> 413 again
# T5  direct-to-backend controls:
#     a) --http1.1 3MB (no upgrade)                 -> 200
#     b) --http2   3MB (h2c upgrade + big body)     -> 413, Tomcat HTML page
#     c) --http2   2KB                              -> 200 over h2
# T6  THE FIX: same gateway built with Apache HC5 on the classpath
#     (mvn -Phc5; SCG-MVC auto-prefers HC5, speaks HTTP/1.1, no upgrade):
#     cold pod, first request = 3MB                 -> 200 over HTTP/1.1
set -uo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$ROOT_DIR/.." && pwd)"
CLUSTER_NAME=h2c-413-repro
CTX="kind-${CLUSTER_NAME}"
NS=demo413
BACKEND_URL="http://backend413.demo413.svc.cluster.local:8081/api/file/upload"

PASS=0; FAIL=0
banner() { echo ""; echo "############################################################"; echo "# $*"; echo "############################################################"; }
check() { # $1=test-id $2=description $3=expected $4=actual
  if [ "$3" = "$4" ]; then
    PASS=$((PASS+1)); echo "  [PASS] $1: $2 (got: $4)"
  else
    FAIL=$((FAIL+1)); echo "  [FAIL] $1: $2 (expected: $3, got: $4)"
  fi
}
kc() { kubectl --context "$CTX" -n "$NS" "$@"; }
upload() { kc exec loadtester -- sh /tmp/up.sh "$1"; }
cold_gateway() {
  kc rollout restart deployment/gateway413 >/dev/null
  kc rollout status deployment/gateway413 --timeout=180s >/dev/null
  for _ in $(seq 1 60); do
    n=$(kc get pods -l app=gateway413 --no-headers 2>/dev/null | wc -l | tr -d ' ')
    [ "$n" = "1" ] && break
    sleep 2
  done
  sleep 3
}

banner "[setup] build normal + HC5-fixed gateway images, deploy 3 identical h2c backends"
( cd "$REPO_ROOT" && mvn -q -pl k8s-repro,k8s-repro/gateway,k8s-repro/backend -am -DskipTests clean package ) || exit 1
docker build -q -t gateway413:local "$ROOT_DIR/gateway" >/dev/null || exit 1
docker build -q -t backend413:local "$ROOT_DIR/backend" >/dev/null || exit 1
# NOTE: 'clean' is required — without it Maven reuses the previous jar and the
# profile's extra dependency never lands in the repackaged archive.
( cd "$REPO_ROOT" && mvn -q -pl k8s-repro/gateway -Phc5 -DskipTests clean package ) || exit 1
docker build -q -t gateway413:hc5 "$ROOT_DIR/gateway" >/dev/null || exit 1
kind get clusters | grep -qx "$CLUSTER_NAME" || kind create cluster --config "$ROOT_DIR/k8s/kind-config.yaml"
kind load docker-image gateway413:local gateway413:hc5 backend413:local --name "$CLUSTER_NAME" >/dev/null 2>&1
kubectl --context "$CTX" apply -f "$ROOT_DIR/k8s/namespace.yaml" >/dev/null
kc apply -f "$ROOT_DIR/k8s/backend-deploy.yaml" -f "$ROOT_DIR/k8s/gateway-config.yaml" -f "$ROOT_DIR/k8s/gateway-deploy.yaml" >/dev/null
kc patch configmap gateway413-config --type merge -p '{"data":{"BACKEND_URL":"http://backend413:8081"}}' >/dev/null
kc delete pod strict-peer413 --ignore-not-found --wait=true >/dev/null 2>&1
kc set image deployment/gateway413 gateway413=gateway413:local >/dev/null
kc scale deployment/gateway413 --replicas=1 >/dev/null
kc scale deployment/backend413 --replicas=3 >/dev/null
kc rollout restart deployment/backend413 >/dev/null
kc rollout status deployment/backend413 --timeout=180s >/dev/null
kc get pod loadtester >/dev/null 2>&1 || {
  kc run loadtester --image=curlimages/curl:latest --restart=Never --command -- sleep infinity >/dev/null
  kc wait --for=condition=Ready pod/loadtester --timeout=60s >/dev/null
}
kc cp "$ROOT_DIR/k8s/up.sh" loadtester:/tmp/up.sh
kc exec loadtester -- sh -c 'head -c 3000000 /dev/urandom > /tmp/t3.bin; head -c 2048 /dev/urandom > /tmp/t2k.bin'
echo "topology: $(kc get pods -l app=backend413 --no-headers | wc -l | tr -d ' ') identical h2c backend pods, 1 gateway pod (JDK client)"

banner "T1-T4: cold/warm connection sequence through the gateway (JDK client)"
cold_gateway
r=$(upload /tmp/t3.bin);  check T1 "cold conn + 3MB upload -> 413"            "413"              "${r%%|*}"
r=$(upload /tmp/t2k.bin); check T2 "2KB upload -> 200 over HTTP/2.0"          "200|HTTP/2.0"     "$(echo "$r" | cut -d'|' -f1,3)"
r=$(upload /tmp/t3.bin);  check T3 "3MB on warm h2 conn -> 200 over HTTP/2.0" "200|HTTP/2.0"     "$(echo "$r" | cut -d'|' -f1,3)"
echo "  ... idling 45s (Tomcat h2 keepAliveTimeout is 20s) ..."
sleep 45
r=$(upload /tmp/t3.bin);  check T4 "3MB after 45s idle -> 413 again"          "413"              "${r%%|*}"

banner "T5: direct-to-backend controls (bypassing the gateway)"
r=$(kc exec loadtester -- sh -c "curl -s -o /dev/null -w '%{http_code}' --http1.1 -F module=DEPOSIT -F 'file=@/tmp/t3.bin;type=image/png' $BACKEND_URL")
check T5a "plain HTTP/1.1 3MB (no upgrade) -> 200" "200" "$r"
r=$(kc exec loadtester -- sh -c "curl -s -o /tmp/r5b -w '%{http_code}' --http2 -F module=DEPOSIT -F 'file=@/tmp/t3.bin;type=image/png' $BACKEND_URL")
check T5b "h2c upgrade + 3MB -> 413" "413" "$r"
r=$(kc exec loadtester -- sh -c "grep -c 'HTTP Status 413' /tmp/r5b" || echo 0)
check T5b2 "...and the 413 body is Tomcat's connector-level HTML error page" "1" "$r"
r=$(kc exec loadtester -- sh -c "curl -s -o /dev/null -w '%{http_code} %{http_version}' --http2 -F module=DEPOSIT -F 'file=@/tmp/t2k.bin;type=image/png' $BACKEND_URL")
check T5c "h2c upgrade + 2KB (fits maxSavePostSize=4096) -> 200 over h2" "200 2" "$r"

banner "T6: THE FIX — same gateway, Apache HC5 on classpath (HTTP/1.1, no upgrade)"
kc set image deployment/gateway413 gateway413=gateway413:hc5 >/dev/null
cold_gateway
r=$(upload /tmp/t3.bin);  check T6 "cold conn + 3MB with HC5 gateway -> 200 over HTTP/1.1" "200|HTTP/1.1" "$(echo "$r" | cut -d'|' -f1,3)"

# restore the vulnerable image so the repro remains re-runnable
kc set image deployment/gateway413 gateway413=gateway413:local >/dev/null
kc rollout status deployment/gateway413 --timeout=180s >/dev/null

banner "RESULT"
echo "  PASS=$PASS FAIL=$FAIL"
if [ "$FAIL" -eq 0 ]; then
  echo "  ALL CHECKS PASSED — theory verified end to end."
  exit 0
else
  echo "  SOME CHECKS FAILED — theory NOT fully verified."
  exit 1
fi
