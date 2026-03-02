#!/bin/bash
# start-validator.sh — Bring validator and execution layer online (IDEMPOTENT)
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NAMESPACE="eth-validator"
SYNC_TIMEOUT=600  # 10 min max wait for initial check

log() { echo "[$(date -u '+%Y-%m-%dT%H:%M:%SZ')] $*"; }

# ── 1. Ensure Minikube is running ──
log "Verifying Minikube status..."
if ! minikube status 2>/dev/null | grep -q "Running"; then
  log "Minikube not running. Starting..."
  minikube start --driver=docker
fi

# ── 2. Ensure manifests are applied (idempotent) ──
log "Applying manifests..."
kubectl apply -n ${NAMESPACE} -f "${SCRIPT_DIR}/manifests/"

# ── 3. Wait for pods to be ready ──
log "Waiting for Nethermind execution client..."
kubectl wait --for=condition=ready pod \
  -l app=nethermind -n ${NAMESPACE} --timeout=300s || {
  log "Nethermind pod not ready. Checking logs:"
  kubectl logs -l app=nethermind -n ${NAMESPACE} --tail=20
  exit 1
}

log "Waiting for Nimbus consensus+validator..."
kubectl wait --for=condition=ready pod \
  -l app=nimbus -n ${NAMESPACE} --timeout=300s || {
  log "Nimbus pod not ready. Checking logs:"
  kubectl logs -l app=nimbus -n ${NAMESPACE} --tail=20
  exit 1
}

# ── 4. Port-forward beacon API for health checks ──
# Kill any existing port-forwards
pkill -f "kubectl port-forward.*5052" 2>/dev/null || true
sleep 1

kubectl port-forward -n ${NAMESPACE} svc/nimbus 5052:5052 &>/dev/null &
PF_PID=$!
sleep 3

# ── 5. Verify execution layer connectivity ──
log "Checking execution layer sync status..."
RETRIES=0
while [ $RETRIES -lt 30 ]; do
  SYNC_DATA=$(curl -sf http://localhost:5052/eth/v1/node/syncing 2>/dev/null) && break
  RETRIES=$((RETRIES + 1))
  sleep 5
done

if [ -n "${SYNC_DATA:-}" ]; then
  IS_SYNCING=$(echo "$SYNC_DATA" | jq -r '.data.is_syncing')
  HEAD_SLOT=$(echo "$SYNC_DATA" | jq -r '.data.head_slot')
  SYNC_DISTANCE=$(echo "$SYNC_DATA" | jq -r '.data.sync_distance')

  if [ "$IS_SYNCING" = "true" ]; then
    log "Node is syncing. Head slot: $HEAD_SLOT, Distance: $SYNC_DISTANCE"
    log "Sync will continue in background. Validator will activate once synced."
  else
    log "Node is SYNCED. Head slot: $HEAD_SLOT"
  fi
else
  log "WARN: Could not reach beacon API. Node may still be initializing."
fi

# ── 6. Check peer connectivity ──
PEERS=$(curl -sf http://localhost:5052/eth/v1/node/peer_count 2>/dev/null)
if [ -n "${PEERS:-}" ]; then
  CONNECTED=$(echo "$PEERS" | jq -r '.data.connected')
  log "Connected peers: $CONNECTED"
else
  log "Peer data not yet available"
fi

# ── 7. Display pod status ──
log "Current pod status:"
kubectl get pods -n ${NAMESPACE} -o wide

# Clean up port-forward
kill $PF_PID 2>/dev/null || true

log "Validator stack is online. Run ./check-health.sh for detailed health report."
