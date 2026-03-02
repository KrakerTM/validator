## TL:DR

The design and code was obiously written and fixed with AI same as This readme. Hope it's readable enogh.
Of course If we want to achieve real goal with only 3 commands, terraform should be a part of provisioning. Qick-fix will be to add makefile here, but with local state which I used for development it seems to be unnecessary - the IaC part was not expected in the exercise (or at least described :))




# Ethereum Testnet Validator — 3-Command Deployment

Hoodi testnet validator on AWS Graviton spot, KMS-encrypted keys, Minikube.

**Stack:** Nethermind (EL) + Nimbus (CL + validator) · EC2 t4g.xlarge spot · AWS KMS · Prometheus + Grafana

**Cost:** ~$106/month spot · ~$175/month on-demand

---

## Architecture

```
┌─────────────────── EC2 t4g.xlarge (Spot) ───────────────────┐
│  Ubuntu 24.04 LTS (ARM64) + Docker + Minikube               │
│  ┌─────────────────── Minikube Cluster ────────────────────┐ │
│  │  ┌──────────────┐  JWT   ┌────────────────────────────┐ │ │
│  │  │  Nethermind   │◄──────►│  Nimbus (Beacon+Validator) │ │ │
│  │  │  (Execution)  │ :8551  │  REST :5052                │ │ │
│  │  │  P2P :30303   │        │  P2P :9000                 │ │ │
│  │  └──────┬───────┘        └──────────┬─────────────────┘ │ │
│  │  el-data PVC (400GB)     cl-data PVC (100GB)            │ │
│  │  ┌──────────────────────────────────────────┐           │ │
│  │  │  Prometheus :9090  →  Grafana :3000       │           │ │
│  │  └──────────────────────────────────────────┘           │ │
│  └─────────────────────────────────────────────────────────┘ │
│  /opt/validator/encrypted-keys  (KMS-encrypted keystores)    │
│  ◄──── EBS gp3 500GB (persistent across spot replacements) ──►│
└───────────────────────────────────────────────────────────────┘
         │                              │
         ▼                              ▼
   AWS KMS CMK                   Hoodi P2P Network
   (decrypt-only role)           (ports 30303, 9000)
```

---

## Prerequisites

| Requirement | Notes |
|---|---|
| AWS account | EC2, EBS, KMS, IAM, ASG permissions |
| AWS CLI | `aws configure` |
| Terraform | >= 1.5.0 |
| 32 Hoodi ETH | Free — see below |

---

## Getting 32 Hoodi ETH

Hoodi testnet ETH has no real value. Get it from the pk910 faucet — browser-based PoW mining, no account needed.

1. Open **[hoodi-faucet.pk910.de](https://hoodi-faucet.pk910.de)**
2. Enter your wallet address, click **Start Mining**
3. Leave the tab open (~0.5–2 ETH/hour depending on CPU)
4. Click **Claim** once you hit 32 ETH

Alternatively, ask in the **#🚰-testnet-faucet** channel on [EthStaker Discord](https://discord.gg/ethstaker).

---

## Deployment

### Step 0 — Generate validator keys (on your workstation, not EC2)

```bash
cd tools/
./generate-keys.sh 1
# Enter your withdrawal address when prompted
# Outputs:
#   validator_keys/keystore-m_*.json    — encrypted keystore
#   validator_keys/deposit_data-*.json  — submit to launchpad
```

Submit the deposit at **[hoodi.launchpad.ethstaker.cc](https://hoodi.launchpad.ethstaker.cc)** — upload `deposit_data-*.json` and confirm the 32 ETH transaction. Activation takes ~16–24 hours but you don't need to wait before continuing.

---

### Step 1 — Provision AWS infrastructure

```bash
cd terraform/
terraform init
cp terraform.tfvars.example terraform.tfvars
terraform apply
```

Note the outputs — you'll need `asg_name` and the instance IP.

**Encrypt and upload your keystores:**

```bash
cd tools/
./encrypt-keystore.sh \
  ../validator_keys/keystore-m_*.json \
  ../encrypted-keys/

# Get instance IP
INSTANCE_ID=$(aws autoscaling describe-auto-scaling-groups \
  --auto-scaling-group-names eth-validator-testnet-asg \
  --query 'AutoScalingGroups[0].Instances[0].InstanceId' --output text)
PUBLIC_IP=$(aws ec2 describe-instances \
  --instance-ids "$INSTANCE_ID" \
  --query 'Reservations[0].Instances[0].PublicIpAddress' --output text)

# SCP to home dir first — the repo doesn't exist on the instance yet
scp -r encrypted-keys/ ubuntu@$PUBLIC_IP:~/
```

---

### Step 2 — Clone repo and place keys on the instance

```bash
ssh ubuntu@$PUBLIC_IP
# or: aws ssm start-session --target "$INSTANCE_ID"
```

```bash
sudo mkdir -p /opt/validator && sudo chown ubuntu:ubuntu /opt/validator
cd /opt/validator
git clone https://github.com/YOUR_USERNAME/eth-validator.git validator
cd validator
chmod +x provision.sh start-validator.sh check-health.sh

# Move encrypted keys into place
mv ~/encrypted-keys/ .
```

> On spot replacement the EBS volume (including this repo and keys) survives automatically — no re-cloning needed.

---

### Step 3 — Run the three commands

```bash
cd /opt/validator/validator

./provision.sh       # installs Docker/Minikube/kubectl, decrypts keys via KMS, loads into K8s
./start-validator.sh # applies manifests, waits for pods
./check-health.sh    # sync status, peers, finality, validator status
```

Expected output once synced and active:

```
▸ KUBERNETES PODS
  ✓ nethermind-0 — Running (restarts: 0)
  ✓ nimbus-0     — Running (restarts: 0)

▸ SYNC STATUS
  ✓ Fully synced — head slot: 412847

▸ VALIDATOR STATUS
  ✓ Validator 123456: ACTIVE (balance: 32004821000 gwei)
```

---

## Sync timeline

| Layer | Method | Expected time |
|---|---|---|
| Consensus (Nimbus) | Checkpoint sync | 5–15 min |
| Execution (Nethermind) | Snap sync | 2–6 hours |
| Validator activation | Entry queue after deposit | ~16–24 hours |

While syncing, `check-health.sh` shows the current head slot and how far behind it is. Validator duties start automatically once sync is complete — nothing to do.

---

## Monitoring

```bash
# Grafana (http://localhost:3000, admin/admin)
kubectl port-forward -n eth-validator svc/grafana 3000:3000

# Prometheus
kubectl port-forward -n eth-validator svc/prometheus 9090:9090

# Beacon API
kubectl port-forward -n eth-validator svc/nimbus 5052:5052
```

From your workstation:
```bash
ssh -L 3000:localhost:3000 ubuntu@$PUBLIC_IP \
  "kubectl port-forward -n eth-validator svc/grafana 3000:3000"
```

---

## Teardown

```bash
# Scale down first
aws autoscaling set-desired-capacity \
  --auto-scaling-group-name eth-validator-testnet-asg --desired-capacity 0

# Remove prevent_destroy from terraform/storage.tf, then:
cd terraform/ && terraform destroy
```

---

## Design notes

**Hoodi testnet** — Holesky was deprecated September 2025 after Pectra instability. Hoodi launched March 2025, active until September 2028.

**Nethermind + Nimbus** — minority client pair (~17% network share combined). Nimbus has a built-in validator client so there's no separate validator pod. Combined RAM ~10GB, fits in 16GB t4g.xlarge.

**KMS envelope encryption** — keystores are AES-256-CBC encrypted at rest. Plaintext only exists in memory (tmpfs) during K8s secret creation, then shredded. The EC2 role has `kms:Decrypt` only.

**Spot + persistent EBS** — spot interruptions only stop the instance, not the chain data. The ASG relaunches and user data reattaches the EBS volume automatically via NVMe serial detection (Nitro instances don't expose `/dev/sdf`).

**StatefulSets replicas: 1** — two validator instances with the same key = double-signing = slashable offence, even on testnet.

---

## Project structure

```
eth-validator/
├── provision.sh                    # Command 1
├── start-validator.sh              # Command 2
├── check-health.sh                 # Command 3
├── encrypted-keys/                 # KMS-encrypted keystores
├── tools/
│   ├── generate-keys.sh
│   └── encrypt-keystore.sh
├── manifests/
│   ├── nethermind-statefulset.yaml
│   ├── nimbus-statefulset.yaml
│   └── monitoring.yaml
└── terraform/
    ├── kms.tf
    ├── iam.tf
    ├── ec2.tf
    ├── storage.tf
    ├── security_groups.tf
    └── terraform.tfvars.example
```
