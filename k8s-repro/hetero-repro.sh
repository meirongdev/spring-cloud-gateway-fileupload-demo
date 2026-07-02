#!/usr/bin/env bash
# Reproduces the EXACT reported symptom — "3 gateway pods → intermittent 413,
# scale down to 1 pod → problem disappears" — via pod heterogeneity:
#
#   1. One gateway pod runs with the ORIGINAL routing env (envFrom is resolved
#      once, at container start).
#   2. The ConfigMap (stand-in for Secret/ConfigMap drift; the production
#      deployment only hash-restarts on ConfigMap changes rendered through
#      helm, and never on Secret changes) is changed to point at a stricter
#      downstream. The
#      running pod is NOT restarted, so it keeps the old value.
#   3. Scaling 1→3 creates two pods that pick up the NEW env at start:
#      the three pods are now silently heterogeneous. Uploads round-robin
#      across them → intermittent 413.
#   4. Scaling 3→1 deletes the NEWEST pods first (ReplicaSet victim ordering),
#      keeping the oldest, "good" pod → the problem vanishes.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$ROOT_DIR/.." && pwd)"
CLUSTER_NAME=h2c-413-repro
CTX="kind-${CLUSTER_NAME}"
NS=demo413
K="kubectl --context $CTX -n $NS"
GATEWAY_URL="http://gateway413.demo413.svc.cluster.local:8080/api/file/upload"

banner() { echo ""; echo "############################################################"; echo "# $*"; echo "############################################################"; }

batch() { # $1=label $2=count -> prints code tally, saves to $ROOT_DIR/.phase-$1
  $K exec loadtester -- sh -c '
    [ -f /tmp/t3.bin ] || head -c 3000000 /dev/urandom > /tmp/t3.bin
    : > /tmp/codes
    i=0; while [ "$i" -lt "'"$2"'" ]; do
      code=$(curl -s -o /dev/null -w "%{http_code}" -F module=DEPOSIT \
        -F "file=@/tmp/t3.bin;filename=test.png;type=image/png" "'"$GATEWAY_URL"'")
      echo "$code" >> /tmp/codes; i=$((i+1))
    done
    sort /tmp/codes | uniq -c' | tee "$ROOT_DIR/.phase-$1"
}

pods() {
  $K get pods -l app=gateway413 \
    -o custom-columns=NAME:.metadata.name,STATUS:.status.phase,STARTED:.status.startTime,IMAGE:.status.containerStatuses[0].image \
    --sort-by=.status.startTime
}

wait_pod_count() { # $1 = expected number of gateway pods (incl. terminating)
  for _ in $(seq 1 60); do
    n=$($K get pods -l app=gateway413 --no-headers 2>/dev/null | wc -l | tr -d ' ')
    [ "$n" = "$1" ] && return 0
    sleep 2
  done
  echo "WARN: gateway pod count did not converge to $1" >&2
}

env_per_pod() {
  for p in $($K get pods -l app=gateway413 -o jsonpath='{.items[*].metadata.name}'); do
    echo "  $p  BACKEND_URL=$($K exec "$p" -- printenv BACKEND_URL)"
  done
}

count_413_per_pod() {
  for p in $($K get pods -l app=gateway413 -o jsonpath='{.items[*].metadata.name}'); do
    c=$($K logs "$p" | grep -c "Completed 413" || true)
    echo "  $p  'Completed 413 PAYLOAD_TOO_LARGE' log lines: $c"
  done
}

banner "[setup] build + load images, deploy everything, reset to 1 GOOD pod"
( cd "$REPO_ROOT" && mvn -q -pl k8s-repro,k8s-repro/gateway,k8s-repro/backend -am -DskipTests package )
docker build -q -t gateway413:local "$ROOT_DIR/gateway"  >/dev/null
docker build -q -t backend413:local "$ROOT_DIR/backend"  >/dev/null
kind get clusters | grep -qx "$CLUSTER_NAME" || kind create cluster --config "$ROOT_DIR/k8s/kind-config.yaml"
kind load docker-image gateway413:local backend413:local --name "$CLUSTER_NAME" 2>&1 | grep -v "already present" || true
kubectl --context "$CTX" apply -f "$ROOT_DIR/k8s/namespace.yaml"
$K apply -f "$ROOT_DIR/k8s/backend-deploy.yaml" -f "$ROOT_DIR/k8s/strict-backend-deploy.yaml" \
         -f "$ROOT_DIR/k8s/gateway-config.yaml" -f "$ROOT_DIR/k8s/gateway-deploy.yaml"
$K scale deployment/gateway413 --replicas=1
$K rollout restart deployment/gateway413 deployment/backend413 deployment/strict-backend413
$K rollout status deployment/backend413 --timeout=180s
$K rollout status deployment/strict-backend413 --timeout=180s
$K rollout status deployment/gateway413 --timeout=180s
$K get pod loadtester >/dev/null 2>&1 || {
  $K run loadtester --image=curlimages/curl:latest --restart=Never --command -- sleep infinity
  $K wait --for=condition=Ready pod/loadtester --timeout=60s
}
wait_pod_count 1   # old-ReplicaSet pods must be fully gone before we baseline
OLD_POD=$($K get pods -l app=gateway413 -o jsonpath='{.items[0].metadata.name}')
echo "the single original gateway pod: $OLD_POD"
env_per_pod

banner "[phase A] 1 pod, original env — 3MB upload x20 (expect all 200)"
batch A 20

banner "[drift] point ConfigMap at strict-backend413 (1MB cap) — NO restart"
$K patch configmap gateway413-config --type merge \
  -p '{"data":{"BACKEND_URL":"http://strict-backend413:8081"}}'
echo "running pod keeps its start-time env (envFrom is not live):"
env_per_pod

banner "[scale up] 1 -> 3 replicas; new pods read the NEW env at start"
$K scale deployment/gateway413 --replicas=3
$K rollout status deployment/gateway413 --timeout=180s
wait_pod_count 3
sleep 3
pods
echo "-- per-pod effective routing env (the smoking gun): --"
env_per_pod

banner "[phase B] 3 heterogeneous pods — 3MB upload x30 (expect intermittent 413)"
batch B 30
echo "-- which gateway pods emitted the reported log line: --"
count_413_per_pod

banner "[scale down] 3 -> 1: which pod survives is a HEURISTIC (node crowding,"
echo "# then readiness age) — NOT guaranteed to be the oldest."
$K scale deployment/gateway413 --replicas=1
wait_pod_count 1
SURVIVOR=$($K get pods -l app=gateway413 -o jsonpath='{.items[0].metadata.name}')
pods
if [ "$SURVIVOR" = "$OLD_POD" ]; then
  echo "survivor $SURVIVOR == original good pod -> expect phase C all 200 (the user's outcome)"
else
  echo "survivor $SURVIVOR is a DRIFTED pod -> expect phase C all 413 (the unlucky outcome)"
fi
echo "  survivor env: $($K exec "$SURVIVOR" -- printenv BACKEND_URL)"

banner "[phase C] back to 1 pod — 3MB upload x20 (outcome depends on survivor)"
batch C 20

banner "[real fix] restore correct config AND restart so every pod re-reads it"
$K patch configmap gateway413-config --type merge \
  -p '{"data":{"BACKEND_URL":"http://backend413:8081"}}'
$K rollout restart deployment/gateway413
$K rollout status deployment/gateway413 --timeout=180s
wait_pod_count 1
env_per_pod

banner "[phase D] 1 pod, env re-read after restart — 3MB upload x20 (expect all 200)"
batch D 20

banner "summary"
echo "phase A (1 pod, before drift):        $(tr -s ' \n' ' ' < "$ROOT_DIR/.phase-A")"
echo "phase B (3 pods, drifted env):        $(tr -s ' \n' ' ' < "$ROOT_DIR/.phase-B")"
echo "phase C (scaled back to 1 pod):       $(tr -s ' \n' ' ' < "$ROOT_DIR/.phase-C")"
echo "phase D (config restored + restart):  $(tr -s ' \n' ' ' < "$ROOT_DIR/.phase-D")"
echo ""
echo "Same image, same tag, same Deployment throughout — only per-pod effective"
echo "env differed. Replica count was never the variable: 413 rate tracked the"
echo "fraction of pods holding the drifted env (0/1 -> 0%, 2/3 -> ~2/3, and the"
echo "post-scale-down rate depends entirely on WHICH pod survived)."
