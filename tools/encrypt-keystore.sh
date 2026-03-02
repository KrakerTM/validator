#!/bin/bash
# encrypt-keystore.sh — Envelope-encrypts a validator keystore with KMS
# Usage: ./encrypt-keystore.sh <keystore.json> <output-dir> <keystore-password>
set -euo pipefail

if [ $# -lt 2 ]; then
  echo "Usage: $0 <keystore.json> <output-dir> [keystore-password]"
  echo "  keystore.json      — EIP-2335 keystore file from ethstaker-deposit-cli"
  echo "  output-dir         — Directory to write encrypted files into"
  echo "  keystore-password  — Password protecting the keystore (prompted if omitted)"
  exit 1
fi

KEYSTORE="$1"
OUTPUT_DIR="$2"
KMS_ALIAS="alias/eth-validator-keystore"
BASE=$(basename "$KEYSTORE" .json)

if [ ! -f "$KEYSTORE" ]; then
  echo "ERROR: Keystore file not found: $KEYSTORE"
  exit 1
fi

mkdir -p "$OUTPUT_DIR"

# Get keystore password
if [ -n "${3:-}" ]; then
  KEYSTORE_PASSWORD="$3"
else
  read -rs -p "Enter keystore password: " KEYSTORE_PASSWORD
  echo
fi

echo "Generating data key from KMS..."

# Generate data key from KMS
DK_JSON=$(aws kms generate-data-key \
  --region "us-east-1" \
  --key-id "$KMS_ALIAS" \
  --key-spec AES_256 \
  --encryption-context "purpose=validator-keystore,file=${BASE}")

# Extract plaintext key (hex) and ciphertext blob
PK_HEX=$(echo "$DK_JSON" | jq -r '.Plaintext' | base64 -d | xxd -p -c 64)
echo "$DK_JSON" | jq -r '.CiphertextBlob' | base64 -d > "${OUTPUT_DIR}/${BASE}.key.enc"

# Generate random IV
IV=$(openssl rand -hex 16)
echo "$IV" > "${OUTPUT_DIR}/${BASE}.iv"

# Encrypt keystore JSON with AES-256-CBC
openssl enc -aes-256-cbc -K "$PK_HEX" -iv "$IV" \
  -in "$KEYSTORE" -out "${OUTPUT_DIR}/${BASE}.enc"

# Encrypt keystore password
echo -n "$KEYSTORE_PASSWORD" | openssl enc -aes-256-cbc \
  -K "$PK_HEX" -iv "$IV" -out "${OUTPUT_DIR}/${BASE}.pass.enc"

# Scrub plaintext from memory
unset PK_HEX DK_JSON KEYSTORE_PASSWORD

echo "Encrypted files written to: $OUTPUT_DIR"
echo "  ${BASE}.enc       — Encrypted keystore"
echo "  ${BASE}.key.enc   — KMS-encrypted data key"
echo "  ${BASE}.iv        — Initialization vector"
echo "  ${BASE}.pass.enc  — Encrypted keystore password"
echo ""
echo "Transfer only these encrypted files to the EC2 instance encrypted-keys/ directory."
echo "Never transfer the original keystore or password in plaintext."
