#!/usr/bin/env bash
# Reproduces the refined report: gateway pods are HOMOGENEOUS (fresh deploy),
# the upload backend has 3 pods — yet 413 appears only when the gateway runs 3 pods.
#
# Mechanism under test: ONE of the three bff endpoints behaves differently
# (here: a 1MB multipart cap), and the gateway's JDK HttpClient reuses one
# connection per origin (h2c multiplex / HTTP1.1 keepalive). kube-proxy picks
# the bff pod PER TCP CONNECTION, so each gateway pod "pins" to one bff pod:
#   gateway@1  -> all traffic rides one pinned conn -> all-200 or all-413
#                 (2/3 chance of landing on a good pod: "1 pod never fails")
#   gateway@3  -> three pins, ~1/3 of traffic hits the bad bff pod -> 偶发 413
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$ROOT_DIR/.." && pwd)"
CLUSTER_NAME=h2c-413-repro
CTX="kind-${CLUSTER_NAME}"
NS=demo413
K="kubectl --context $CTX -n $NS"
GATEWAY_URL="http://gateway413.demo413.svc.cluster.local:8080/api/file/upload"

banner() { echo ""; echo "############################################################"; echo "# $*"; echo "############################################################"; }

wait_gw_count() {
  for _ in $(seq 1 60); do
    n=$($K get pods -l app=gateway413 --no-headers 2>/dev/null | wc -l | tr -d ' ')
    [ "$n" = "$1" ] && return 0
    sleep 2
  done
  echo "WARN: gateway pod count did not converge to $1" >&2
}

batch() { # $1=label $2=count — tallies http codes and, for 200s, which bff pod served over which protocol
  $K exec loadtester -- sh -c '
    [ -f /tmp/t3.bin ] || head -c 3000000 /dev/urandom > /tmp/t3.bin
    : > /tmp/lines
    i=0; while [ "$i" -lt "'"$2"'" ]; do
      out=$(curl -s -w "|%{http_code}" -F module=DEPOSIT \
        -F "file=@/tmp/t3.bin;filename=test.png;type=image/png" "'"$GATEWAY_URL"'")
      code=${out##*|}; body=${out%|*}
      served=$(echo "$body" | grep -o "\"servedBy\":\"[^\"]*\"" | cut -d: -f2 | tr -d "\"")
      proto=$(echo  "$body" | grep -o "\"protocol\":\"[^\"]*\""  | cut -d: -f2- | tr -d "\"")
      echo "$code ${served:--} ${proto:--}" >> /tmp/lines
      i=$((i+1))
    done
    echo "--- '"$1"' ($2 x 3MB) code / servedBy / protocol ---"
    sort /tmp/lines | uniq -c' | tee "$ROOT_DIR/.bff-$1"
}

restart_gateway() { # re-roll which bff pod each gateway pod pins to
  $K rollout restart deployment/gateway413
  $K rollout status deployment/gateway413 --timeout=180s
  wait_gw_count "$1"
  sleep 3
}

banner "[setup] build, load, deploy: 2 good bff pods + 1 strict peer = 3 endpoints"
( cd "$REPO_ROOT" && mvn -q -pl k8s-repro,k8s-repro/gateway,k8s-repro/backend -am -DskipTests package )
docker build -q -t gateway413:local "$ROOT_DIR/gateway"  >/dev/null
docker build -q -t backend413:local "$ROOT_DIR/backend"  >/dev/null
kind get clusters | grep -qx "$CLUSTER_NAME" || kind create cluster --config "$ROOT_DIR/k8s/kind-config.yaml"
kind load docker-image gateway413:local backend413:local --name "$CLUSTER_NAME" 2>&1 | grep -v "already present" || true
kubectl --context "$CTX" apply -f "$ROOT_DIR/k8s/namespace.yaml"
$K apply -f "$ROOT_DIR/k8s/backend-deploy.yaml" -f "$ROOT_DIR/k8s/gateway-config.yaml" -f "$ROOT_DIR/k8s/gateway-deploy.yaml"
$K patch configmap gateway413-config --type merge -p '{"data":{"BACKEND_URL":"http://backend413:8081"}}'
$K delete pod strict-peer413 --ignore-not-found --wait=true
$K scale deployment/backend413 --replicas=2
$K rollout restart deployment/backend413
$K rollout status deployment/backend413 --timeout=180s
$K apply -f "$ROOT_DIR/k8s/strict-peer-pod.yaml"
$K wait --for=condition=Ready pod/strict-peer413 --timeout=120s
$K get pod loadtester >/dev/null 2>&1 || {
  $K run loadtester --image=curlimages/curl:latest --restart=Never --command -- sleep infinity
  $K wait --for=condition=Ready pod/loadtester --timeout=60s
}
echo "backend413 Service endpoints (2 good + 1 strict):"
$K get endpointslices -l kubernetes.io/service-name=backend413 -o jsonpath='{range .items[*].endpoints[*]}{.targetRef.name}{"\n"}{end}'
$K scale deployment/gateway413 --replicas=1

banner "[gateway@1] three rounds, gateway restarted between rounds (re-rolls the pinned bff pod)"
for round in 1 2 3; do
  restart_gateway 1
  batch "gw1-round$round" 20
done

banner "[gateway@3] one round of 30"
$K scale deployment/gateway413 --replicas=3
restart_gateway 3
batch "gw3" 30

banner "evidence: 413s per bff pod (DispatcherServlet 'Completed 413' lines)"
for p in $($K get pods -l app=backend413 -o jsonpath='{.items[*].metadata.name}'); do
  c=$($K logs "$p" -c backend413 2>/dev/null | grep -c "Completed 413" || true)
  echo "  $p : $c"
done

banner "summary"
for f in "$ROOT_DIR"/.bff-gw1-round1 "$ROOT_DIR"/.bff-gw1-round2 "$ROOT_DIR"/.bff-gw1-round3 "$ROOT_DIR"/.bff-gw3; do
  echo "== $(basename "$f")"; cat "$f"
done
echo ""
echo "Interpretation: at 1 gateway pod each round is all-or-nothing (one pinned"
echo "bff pod, usually a good one). At 3 gateway pods the three pins cover more"
echo "of the endpoint set, so the bad bff pod surfaces as INTERMITTENT 413s —"
echo "the gateway pods themselves are perfectly identical throughout."
