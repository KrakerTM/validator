#!/bin/bash
set -euo pipefail
exec > >(tee /var/log/user-data.log | logger -t user-data -s 2>/dev/console) 2>&1

VOLUME_ID="${ebs_volume_id}"
AWS_REGION="${aws_region}"
MOUNT_POINT="${mount_point}"

echo "=== Ethereum Validator: user_data start ==="
echo "Volume: $VOLUME_ID | Region: $AWS_REGION | Mount: $MOUNT_POINT"

TOKEN=$(curl -sf -X PUT "http://169.254.169.254/latest/api/token" \
  -H "X-aws-ec2-metadata-token-ttl-seconds: 300")
INSTANCE_ID=$(curl -sf "http://169.254.169.254/latest/meta-data/instance-id" \
  -H "X-aws-ec2-metadata-token: $TOKEN")
echo "Instance: $INSTANCE_ID"

export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq nvme-cli awscli

ATTACHMENT=$(aws ec2 describe-volumes \
  --volume-ids "$VOLUME_ID" \
  --region "$AWS_REGION" \
  --query 'Volumes[0].Attachments[0]' \
  --output json 2>/dev/null || echo "{}")

ATTACHED_TO=$(echo "$ATTACHMENT" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('InstanceId','none'))" 2>/dev/null || echo "none")
ATTACH_STATE=$(echo "$ATTACHMENT" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('State','none'))" 2>/dev/null || echo "none")

echo "Volume attachment state: $ATTACH_STATE (instance: $ATTACHED_TO)"

if [ "$ATTACHED_TO" = "$INSTANCE_ID" ] && [ "$ATTACH_STATE" = "attached" ]; then
  echo "Volume already attached to this instance — skipping attach"
elif [ "$ATTACH_STATE" = "detaching" ]; then
  echo "Volume detaching from previous instance — waiting..."
  aws ec2 wait volume-available --volume-ids "$VOLUME_ID" --region "$AWS_REGION"
  aws ec2 attach-volume \
    --volume-id "$VOLUME_ID" \
    --instance-id "$INSTANCE_ID" \
    --device "/dev/sdf" \
    --region "$AWS_REGION"
elif [ "$ATTACH_STATE" = "available" ] || [ "$ATTACHED_TO" = "none" ]; then
  echo "Attaching volume $VOLUME_ID to $INSTANCE_ID..."
  aws ec2 attach-volume \
    --volume-id "$VOLUME_ID" \
    --instance-id "$INSTANCE_ID" \
    --device "/dev/sdf" \
    --region "$AWS_REGION"
fi

# Wait for the volume to reach in-use state in the AWS API
aws ec2 wait volume-in-use --volume-ids "$VOLUME_ID" --region "$AWS_REGION"
echo "Volume $VOLUME_ID is in-use"

STRIPPED_VOL_ID="${replace(ebs_volume_id, "-", "")}"

DATA_DEVICE=""
TIMEOUT=60
ELAPSED=0

while [ -z "$DATA_DEVICE" ] && [ $ELAPSED -lt $TIMEOUT ]; do
  for dev in /dev/nvme*n1; do
    [ -b "$dev" ] || continue
    # awk: find the 'sn' field and strip all spaces
    SN=$(nvme id-ctrl "$dev" 2>/dev/null | awk '/^sn/{gsub(/ /,""); print $NF}' || true)
    if [ "$SN" = "$STRIPPED_VOL_ID" ]; then
      DATA_DEVICE="$dev"
      break
    fi
  done

  if [ -z "$DATA_DEVICE" ]; then
    echo "Waiting for kernel to expose NVMe device... ($${ELAPSED}s)"
    sleep 2
    ELAPSED=$((ELAPSED + 2))
  fi
done

if [ -z "$DATA_DEVICE" ]; then
  echo "ERROR: NVMe device for volume $VOLUME_ID not found after $${TIMEOUT}s"
  echo "Available NVMe devices:"
  ls /dev/nvme*n1 2>/dev/null || echo "  none"
  exit 1
fi

echo "Data volume is at: $DATA_DEVICE"

FSTYPE=$(blkid -o value -s TYPE "$DATA_DEVICE" 2>/dev/null || echo "")
if [ -z "$FSTYPE" ]; then
  echo "No filesystem detected — formatting $DATA_DEVICE as ext4 (this is normal on first boot)"
  mkfs.ext4 -L validator-data \
    -E lazy_itable_init=0,lazy_journal_init=0 \
    "$DATA_DEVICE"
  echo "Format complete"
else
  echo "Existing filesystem detected: $FSTYPE — skipping format"
fi

mkdir -p "$MOUNT_POINT"

# Unmount first if already mounted (e.g. from a previous boot cycle)
if mountpoint -q "$MOUNT_POINT"; then
  echo "$MOUNT_POINT already mounted"
else
  mount "$DATA_DEVICE" "$MOUNT_POINT"
  echo "Mounted $DATA_DEVICE at $MOUNT_POINT"
fi

LABEL=$(blkid -o value -s LABEL "$DATA_DEVICE" 2>/dev/null || echo "")
if [ -n "$LABEL" ]; then
  if ! grep -q "LABEL=$LABEL" /etc/fstab; then
    echo "LABEL=$LABEL  $MOUNT_POINT  ext4  defaults,nofail  0  2" >> /etc/fstab
    echo "Added fstab entry for LABEL=$LABEL"
  fi
else
  if ! grep -q "$MOUNT_POINT" /etc/fstab; then
    echo "$DATA_DEVICE  $MOUNT_POINT  ext4  defaults,nofail  0  2" >> /etc/fstab
    echo "Added fstab entry for $DATA_DEVICE (no LABEL found)"
  fi
fi

mkdir -p \
  "$MOUNT_POINT/eth-validator/encrypted-keys" \
  "$MOUNT_POINT/eth-validator/shared" \
  "$MOUNT_POINT/minikube"

# Symlink Minikube's data directory to the persistent volume
# so chain data survives spot interruptions
UBUNTU_HOME="/home/ubuntu"
if [ ! -L "$UBUNTU_HOME/.minikube" ]; then
  mkdir -p "$UBUNTU_HOME"
  ln -sfn "$MOUNT_POINT/minikube" "$UBUNTU_HOME/.minikube"
  chown -h ubuntu:ubuntu "$UBUNTU_HOME/.minikube" 2>/dev/null || true
fi

chown -R ubuntu:ubuntu "$MOUNT_POINT/eth-validator" 2>/dev/null || true
chmod 700 "$MOUNT_POINT/eth-validator/encrypted-keys"

echo "=== user_data complete ==="
echo "Data volume mounted at: $MOUNT_POINT"
echo "Disk usage:"
df -h "$MOUNT_POINT"
echo ""
echo "Next steps (SSH in as ubuntu):"
echo "  1. Upload encrypted keystores to $MOUNT_POINT/eth-validator/encrypted-keys/"
echo "  2. cd /opt/validator/eth-validator && ./provision.sh"
echo "  3. ./start-validator.sh"
