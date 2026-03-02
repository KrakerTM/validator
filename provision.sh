#!/bin/bash
# provision.sh — Deploy infrastructure and dependencies (IDEMPOTENT)
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NAMESPACE="eth-validator"
MINIKUBE_CPUS=3
MINIKUBE_MEMORY=14336  # 14GB, leaving 2GB for OS
CHAIN="hoodi"
CHECKPOINT_SYNC_URL="https://beaconstate-hoodi.chainsafe.io"

log() { echo "[$(date -u '+%Y-%m-%dT%H:%M:%SZ')] $*"; }

# ── 1. Install system dependencies (idempotent) ──
log "Installing system dependencies..."
sudo apt-get update -qq
sudo apt-get install -y -qq docker.io conntrack socat jq openssl xxd curl unzip

# Add user to docker group and re-exec with the new group active in this session.
# Without re-exec, the group membership is not visible until next login and
# minikube --driver=docker will fail with "permission denied" on the socket.
if ! groups | grep -q docker; then
  sudo usermod -aG docker "$USER"
  exec sg docker "$0" "$@"
fi

# Install kubectl if missing
if ! command -v kubectl &>/dev/null; then
  ARCH=$(dpkg --print-architecture)
  curl -sLO "https://dl.k8s.io/release/$(curl -sL https://dl.k8s.io/release/stable.txt)/bin/linux/${ARCH}/kubectl"
  chmod +x kubectl && sudo mv kubectl /usr/local/bin/
fi

# Install Minikube if missing
if ! command -v minikube &>/dev/null; then
  ARCH=$(dpkg --print-architecture)
  curl -sLO "https://storage.googleapis.com/minikube/releases/latest/minikube-linux-${ARCH}"
  sudo install "minikube-linux-${ARCH}" /usr/local/bin/minikube
  rm "minikube-linux-${ARCH}"
fi

# Install AWS CLI v2 if missing
if ! command -v aws &>/dev/null; then
  ARCH=$(uname -m)
  curl -s "https://awscli.amazonaws.com/awscli-exe-linux-${ARCH}.zip" -o awscliv2.zip
  unzip -qo awscliv2.zip && sudo ./aws/install --update && rm -rf aws awscliv2.zip
fi

# ── 2. Start Minikube (idempotent) ──
log "Starting Minikube..."
if ! minikube status 2>/dev/null | grep -q "Running"; then
  minikube start \
    --driver=docker \
    --cpus=${MINIKUBE_CPUS} \
    --memory=${MINIKUBE_MEMORY} \
    --disk-size=80g \
    --addons=storage-provisioner,metrics-server
else
  log "Minikube already running"
fi

# ── 3. Create namespace and JWT secret ──
log "Configuring Kubernetes resources..."
kubectl get namespace ${NAMESPACE} 2>/dev/null || \
  kubectl create namespace ${NAMESPACE}

# Generate JWT secret if not exists (idempotent via dry-run+apply)
JWT_SECRET_FILE="/tmp/jwtsecret-$$"
[ -f "${SCRIPT_DIR}/shared/jwt.hex" ] && \
  JWT_HEX=$(cat "${SCRIPT_DIR}/shared/jwt.hex") || \
  JWT_HEX=$(openssl rand -hex 32)

mkdir -p "${SCRIPT_DIR}/shared"
echo -n "$JWT_HEX" > "${SCRIPT_DIR}/shared/jwt.hex"

kubectl create secret generic jwt-secret \
  --from-literal=jwt.hex="$JWT_HEX" \
  --namespace=${NAMESPACE} \
  --dry-run=client -o yaml | kubectl apply -f -

# ── 4. Create StorageClass for EBS gp3 (Minikube uses hostpath) ──
cat <<'EOF' | kubectl apply -f -
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: eth-storage
provisioner: k8s.io/minikube-hostpath
reclaimPolicy: Retain
volumeBindingMode: Immediate
allowVolumeExpansion: true
EOF

# ── 5. Apply all Kubernetes manifests ──
log "Applying Kubernetes manifests..."
kubectl apply -n ${NAMESPACE} -f "${SCRIPT_DIR}/manifests/"

# ── 6. Decrypt validator keystores via KMS ──
log "Decrypting validator keystores..."
ENCRYPTED_DIR="${SCRIPT_DIR}/encrypted-keys"
TMPFS_DIR="/dev/shm/validator-keys"
mkdir -p "$TMPFS_DIR"
chmod 700 "$TMPFS_DIR"

if [ -d "$ENCRYPTED_DIR" ] && ls "$ENCRYPTED_DIR"/*.enc 1>/dev/null 2>&1; then
  for enc_file in "$ENCRYPTED_DIR"/*.enc; do
    BASE=$(basename "$enc_file" .enc)
    [[ "$BASE" == *.pass ]] && continue  # Skip password files in this loop

    KEY_FILE="${ENCRYPTED_DIR}/${BASE}.key.enc"
    IV_FILE="${ENCRYPTED_DIR}/${BASE}.iv"
    PASS_FILE="${ENCRYPTED_DIR}/${BASE}.pass.enc"

    [ -f "$KEY_FILE" ] && [ -f "$IV_FILE" ] || { log "WARN: Missing files for $BASE"; continue; }

    # Decrypt data key via KMS
    PK_B64=$(aws kms decrypt \
      --ciphertext-blob "fileb://${KEY_FILE}" \
      --encryption-context "purpose=validator-keystore,file=${BASE}" \
      --output text --query Plaintext)
    PK_HEX=$(echo -n "$PK_B64" | base64 -d | xxd -p -c 64)
    IV=$(cat "$IV_FILE")

    # Decrypt keystore JSON to tmpfs
    openssl enc -aes-256-cbc -d -K "$PK_HEX" -iv "$IV" \
      -in "$enc_file" -out "${TMPFS_DIR}/${BASE}.json"
    chmod 400 "${TMPFS_DIR}/${BASE}.json"

    # Decrypt keystore password to tmpfs
    if [ -f "$PASS_FILE" ]; then
      openssl enc -aes-256-cbc -d -K "$PK_HEX" -iv "$IV" \
        -in "$PASS_FILE" -out "${TMPFS_DIR}/${BASE}.pass"
      chmod 400 "${TMPFS_DIR}/${BASE}.pass"
    fi

    unset PK_B64 PK_HEX
    log "Decrypted keystore: $BASE"
  done

  # Create Kubernetes secret from decrypted keystores
  KEYSTORE_ARGS=""
  PASSWORD_ARGS=""
  for f in "$TMPFS_DIR"/*.json; do
    [ -f "$f" ] && KEYSTORE_ARGS+=" --from-file=$(basename $f)=$f"
  done
  for f in "$TMPFS_DIR"/*.pass; do
    [ -f "$f" ] && PASSWORD_ARGS+=" --from-file=$(basename $f)=$f"
  done

  kubectl create secret generic validator-keys \
    ${KEYSTORE_ARGS} ${PASSWORD_ARGS} \
    --namespace=${NAMESPACE} \
    --dry-run=client -o yaml | kubectl apply -f -

  # Clean tmpfs
  find "$TMPFS_DIR" -type f -exec shred -u {} \;
  rm -rf "$TMPFS_DIR"
else
  log "No encrypted keystores found in $ENCRYPTED_DIR — skipping KMS decryption"
  log "Generate keys with: ./deposit new-mnemonic --chain hoodi --num_validators 1"
fi

# ── 7. Create systemd service for Minikube auto-start ──
log "Installing systemd service..."
sudo tee /etc/systemd/system/minikube-validator.service > /dev/null <<SYSTEMD
[Unit]
Description=Minikube Ethereum Validator
After=network-online.target docker.service
Wants=network-online.target
Requires=docker.service

[Service]
Type=oneshot
RemainAfterExit=yes
User=${USER}
Environment=HOME=/home/${USER}
Environment=MINIKUBE_HOME=/home/${USER}/.minikube
ExecStart=/usr/local/bin/minikube start --driver=docker --cpus=${MINIKUBE_CPUS} --memory=${MINIKUBE_MEMORY}
ExecStop=/usr/local/bin/minikube stop
TimeoutStartSec=300
TimeoutStopSec=120

[Install]
WantedBy=multi-user.target
SYSTEMD

sudo systemctl daemon-reload
sudo systemctl enable minikube-validator.service

log "Provisioning complete. Run ./start-validator.sh to bring services online."
