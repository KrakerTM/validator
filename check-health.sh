#!/bin/bash
# check-health.sh — Verify validator readiness via API endpoints (IDEMPOTENT)
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NAMESPACE="eth-validator"
BEACON_PORT=5052
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'

pass() { echo -e "  ${GREEN}✓${NC} $*"; }
warn() { echo -e "  ${YELLOW}⚠${NC} $*"; }
fail() { echo -e "  ${RED}✗${NC} $*"; }

# ── Setup port-forward ──
pkill -f "kubectl port-forward.*${BEACON_PORT}" 2>/dev/null || true
sleep 1
kubectl port-forward -n ${NAMESPACE} svc/nimbus ${BEACON_PORT}:${BEACON_PORT} &>/dev/null &
PF_PID=$!
trap "kill $PF_PID 2>/dev/null" EXIT
sleep 3

echo "═══════════════════════════════════════════════"
echo "  Ethereum Validator Health Check (Hoodi)"
echo "  $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
echo "═══════════════════════════════════════════════"

# ── 1. Kubernetes Pod Health ──
echo ""
echo "▸ KUBERNETES PODS"
PODS=$(kubectl get pods -n ${NAMESPACE} --no-headers 2>/dev/null)
echo "$PODS" | while read line; do
  NAME=$(echo "$line" | awk '{print $1}')
  STATUS=$(echo "$line" | awk '{print $3}')
  RESTARTS=$(echo "$line" | awk '{print $4}')
  if [ "$STATUS" = "Running" ]; then
    pass "$NAME — Running (restarts: $RESTARTS)"
  else
    fail "$NAME — $STATUS (restarts: $RESTARTS)"
  fi
done

# ── 2. Node Health (HTTP Status) ──
echo ""
echo "▸ BEACON NODE HEALTH"
HTTP_CODE=$(curl -sf -o /dev/null -w "%{http_code}" \
  "http://localhost:${BEACON_PORT}/eth/v1/node/health" 2>/dev/null || echo "000")

case "$HTTP_CODE" in
  200) pass "Beacon node healthy (HTTP 200 — fully synced)" ;;
  206) warn "Beacon node syncing (HTTP 206 — not yet synced)" ;;
  *)   fail "Beacon node unreachable (HTTP $HTTP_CODE)" ;;
esac

# ── 3. Sync Status ──
echo ""
echo "▸ SYNC STATUS"
SYNC=$(curl -sf "http://localhost:${BEACON_PORT}/eth/v1/node/syncing" 2>/dev/null)
if [ -n "${SYNC:-}" ]; then
  IS_SYNCING=$(echo "$SYNC" | jq -r '.data.is_syncing')
  HEAD_SLOT=$(echo "$SYNC" | jq -r '.data.head_slot')
  SYNC_DIST=$(echo "$SYNC" | jq -r '.data.sync_distance')
  IS_OPTIMISTIC=$(echo "$SYNC" | jq -r '.data.is_optimistic')

  if [ "$IS_SYNCING" = "false" ]; then
    pass "Fully synced — head slot: $HEAD_SLOT"
  else
    warn "Syncing — head: $HEAD_SLOT, remaining: $SYNC_DIST slots"
  fi
  [ "$IS_OPTIMISTIC" = "true" ] && warn "Optimistic mode (EL still syncing)"
else
  fail "Cannot retrieve sync status"
fi

# ── 4. Client Version ──
echo ""
echo "▸ CLIENT VERSION"
VERSION=$(curl -sf "http://localhost:${BEACON_PORT}/eth/v1/node/version" 2>/dev/null)
if [ -n "${VERSION:-}" ]; then
  CLIENT=$(echo "$VERSION" | jq -r '.data.version')
  pass "Client: $CLIENT"
else
  fail "Cannot retrieve version"
fi

# ── 5. Peer Connectivity ──
echo ""
echo "▸ PEER CONNECTIVITY"
PEERS=$(curl -sf "http://localhost:${BEACON_PORT}/eth/v1/node/peer_count" 2>/dev/null)
if [ -n "${PEERS:-}" ]; then
  CONNECTED=$(echo "$PEERS" | jq -r '.data.connected')
  DISCONNECTED=$(echo "$PEERS" | jq -r '.data.disconnected')
  if [ "$CONNECTED" -gt 10 ]; then
    pass "Connected peers: $CONNECTED (disconnected: $DISCONNECTED)"
  elif [ "$CONNECTED" -gt 0 ]; then
    warn "Low peer count: $CONNECTED (target: >10)"
  else
    fail "No connected peers"
  fi
else
  fail "Cannot retrieve peer count"
fi

# ── 6. Finality ──
echo ""
echo "▸ CHAIN FINALITY"
FINALITY=$(curl -sf "http://localhost:${BEACON_PORT}/eth/v1/beacon/states/head/finality_checkpoints" 2>/dev/null)
if [ -n "${FINALITY:-}" ]; then
  FIN_EPOCH=$(echo "$FINALITY" | jq -r '.data.finalized.epoch')
  JUST_EPOCH=$(echo "$FINALITY" | jq -r '.data.current_justified.epoch')
  pass "Finalized epoch: $FIN_EPOCH | Justified epoch: $JUST_EPOCH"
else
  warn "Finality data not available (node may still be syncing)"
fi

# ── 7. Validator Status (if pubkey configured) ──
echo ""
echo "▸ VALIDATOR STATUS"
VALIDATOR_PUBKEY_FILE="${SCRIPT_DIR}/validator-pubkey.txt"
if [ -f "$VALIDATOR_PUBKEY_FILE" ]; then
  PUBKEY=$(cat "$VALIDATOR_PUBKEY_FILE")
  VAL_STATUS=$(curl -sf \
    "http://localhost:${BEACON_PORT}/eth/v1/beacon/states/head/validators?id=${PUBKEY}" 2>/dev/null)
  if [ -n "${VAL_STATUS:-}" ]; then
    STATUS=$(echo "$VAL_STATUS" | jq -r '.data[0].status')
    BALANCE=$(echo "$VAL_STATUS" | jq -r '.data[0].balance')
    INDEX=$(echo "$VAL_STATUS" | jq -r '.data[0].index')
    case "$STATUS" in
      active_ongoing) pass "Validator $INDEX: ACTIVE (balance: $BALANCE gwei)" ;;
      pending_queued) warn "Validator $INDEX: PENDING (waiting for activation)" ;;
      pending_initialized) warn "Validator: Deposit seen, waiting for processing" ;;
      *) warn "Validator status: $STATUS" ;;
    esac
  else
    warn "Could not query validator status"
  fi
else
  warn "No validator pubkey file found at $VALIDATOR_PUBKEY_FILE"
  warn "Create it with: echo '0xYOUR_PUBKEY' > $VALIDATOR_PUBKEY_FILE"
fi

# ── 8. Disk Usage ──
echo ""
echo "▸ PERSISTENT STORAGE"
kubectl exec -n ${NAMESPACE} nethermind-0 -- df -h /data 2>/dev/null | tail -1 | \
  awk '{printf "  Nethermind: %s used of %s (%s)\n", $3, $2, $5}' || \
  warn "Cannot check Nethermind disk usage"
kubectl exec -n ${NAMESPACE} nimbus-0 -- df -h /data 2>/dev/null | tail -1 | \
  awk '{printf "  Nimbus: %s used of %s (%s)\n", $3, $2, $5}' || \
  warn "Cannot check Nimbus disk usage"

echo ""
echo "═══════════════════════════════════════════════"
