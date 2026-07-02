#!/usr/bin/env bash
# Builds gateway413/backend413, stands them up in a local kind cluster, and
# fires identical multipart uploads at the gateway Service at 1 replica vs 3
# replicas to test whether 413 rate depends on gateway pod count or purely on
# file size vs. the gateway's un-configured multipart default.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"   # .../k8s-repro
REPO_ROOT="$(cd "$ROOT_DIR/.." && pwd)"                     # repo root
CLUSTER_NAME=h2c-413-repro
CTX="kind-${CLUSTER_NAME}"
NAMESPACE=demo413

echo "==> [1/6] Building jars"
( cd "$REPO_ROOT" && mvn -q -pl k8s-repro,k8s-repro/gateway,k8s-repro/backend -am -DskipTests package )

echo "==> [2/6] Building docker images"
docker build -q -t gateway413:local "$ROOT_DIR/gateway" >/dev/null
docker build -q -t backend413:local "$ROOT_DIR/backend" >/dev/null

echo "==> [3/6] Ensuring kind cluster '$CLUSTER_NAME' exists"
if ! kind get clusters | grep -qx "$CLUSTER_NAME"; then
  kind create cluster --config "$ROOT_DIR/k8s/kind-config.yaml"
fi

echo "==> [4/6] Loading images into kind"
kind load docker-image gateway413:local backend413:local --name "$CLUSTER_NAME"

echo "==> [5/6] Applying manifests"
kubectl --context "$CTX" apply -f "$ROOT_DIR/k8s/namespace.yaml"
kubectl --context "$CTX" -n "$NAMESPACE" apply -f "$ROOT_DIR/k8s/backend-deploy.yaml"
kubectl --context "$CTX" -n "$NAMESPACE" apply -f "$ROOT_DIR/k8s/gateway-config.yaml"
kubectl --context "$CTX" -n "$NAMESPACE" apply -f "$ROOT_DIR/k8s/gateway-deploy.yaml"
kubectl --context "$CTX" -n "$NAMESPACE" rollout status deployment/backend413 --timeout=120s
kubectl --context "$CTX" -n "$NAMESPACE" rollout status deployment/gateway413 --timeout=120s

echo "==> [6/6] Setting up in-cluster load tester"
kubectl --context "$CTX" -n "$NAMESPACE" delete pod loadtester --ignore-not-found --wait=true
kubectl --context "$CTX" -n "$NAMESPACE" run loadtester --image=curlimages/curl:latest --restart=Never --command -- sleep infinity
kubectl --context "$CTX" -n "$NAMESPACE" wait --for=condition=Ready pod/loadtester --timeout=60s
kubectl --context "$CTX" -n "$NAMESPACE" cp "$ROOT_DIR/k8s/loadtest.sh" loadtester:/tmp/loadtest.sh

run_at_replicas() {
  local replicas=$1
  local label=$2
  echo ""
  echo "############################################"
  echo "# gateway413 scaled to $replicas replica(s)"
  echo "############################################"
  kubectl --context "$CTX" -n "$NAMESPACE" scale deployment/gateway413 --replicas="$replicas"
  kubectl --context "$CTX" -n "$NAMESPACE" rollout status deployment/gateway413 --timeout=120s
  sleep 3 # let the Service's endpoint list settle across all pods
  kubectl --context "$CTX" -n "$NAMESPACE" exec loadtester -- sh /tmp/loadtest.sh "$label"
}

run_at_replicas 1 "1-pod"
run_at_replicas 3 "3-pod"

echo ""
echo "==> Done. Cluster '$CLUSTER_NAME' left running for follow-up:"
echo "      kubectl --context $CTX -n $NAMESPACE get pods -o wide"
echo "      kubectl --context $CTX -n $NAMESPACE logs deploy/gateway413 --all-containers --prefix"
echo "==> Tear down with: kind delete cluster --name $CLUSTER_NAME"
