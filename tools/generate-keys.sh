#!/bin/bash
# generate-keys.sh — Download ethstaker-deposit-cli and generate Hoodi validator keys
# Run this on your local workstation, NOT on the EC2 instance.
set -euo pipefail

NUM_VALIDATORS="${1:-1}"
WITHDRAWAL_ADDRESS="${2:-}"

CLI_VERSION="v1.2.2"
CLI_COMMIT="b13dcb9"   # git hash embedded in the release artifact filename
REPO="ethstaker/ethstaker-deposit-cli"
BASE_URL="https://github.com/${REPO}/releases/download/${CLI_VERSION}"

# Detect OS and arch
OS=$(uname -s | tr '[:upper:]' '[:lower:]')   # darwin or linux
ARCH=$(uname -m)
case "$ARCH" in
  aarch64|arm64) ARCH="arm64" ;;
  x86_64)        ARCH="amd64" ;;
  *)
    echo "ERROR: Unsupported architecture: $ARCH"
    exit 1
    ;;
esac

CLI_BINARY="ethstaker_deposit-cli-${CLI_COMMIT}-${OS}-${ARCH}"
CLI_TARBALL="${CLI_BINARY}.tar.gz"
CLI_URL="${BASE_URL}/${CLI_TARBALL}"
SHA_URL="${CLI_URL}.sha256"

echo "=== Hoodi Validator Key Generation ==="
echo "Validators to generate : $NUM_VALIDATORS"
echo "OS / Arch              : $OS / $ARCH"
echo "Tool version           : $CLI_VERSION ($CLI_COMMIT)"
echo ""

if [ -z "$WITHDRAWAL_ADDRESS" ]; then
  read -rp "Enter your Hoodi withdrawal address (0x...): " WITHDRAWAL_ADDRESS
fi

if [[ ! "$WITHDRAWAL_ADDRESS" =~ ^0x[0-9a-fA-F]{40}$ ]]; then
  echo "ERROR: Invalid Ethereum address: $WITHDRAWAL_ADDRESS"
  exit 1
fi

# ── Download binary ──
if [ ! -f "./${CLI_BINARY}/deposit" ]; then
  echo "Downloading ethstaker-deposit-cli ${CLI_VERSION} (${OS}/${ARCH})..."
  curl -fLO --progress-bar "$CLI_URL" || {
    echo "ERROR: Download failed — $CLI_URL"
    exit 1
  }

  # Verify checksum
  # GitHub .sha256 files contain just the hash with no filename,
  # so we compare manually instead of using --check
  echo "Verifying checksum..."
  curl -fsLO "$SHA_URL" || echo "WARN: Could not fetch checksum file — skipping verification"
  if [ -f "${CLI_TARBALL}.sha256" ]; then
    EXPECTED=$(awk '{print $1}' "${CLI_TARBALL}.sha256")
    if command -v sha256sum &>/dev/null; then
      ACTUAL=$(sha256sum "$CLI_TARBALL" | awk '{print $1}')
    else
      ACTUAL=$(shasum -a 256 "$CLI_TARBALL" | awk '{print $1}')
    fi
    if [ "$EXPECTED" = "$ACTUAL" ]; then
      echo "Checksum OK."
    else
      echo "ERROR: Checksum mismatch — download may be corrupt."
      echo "  Expected: $EXPECTED"
      echo "  Actual:   $ACTUAL"
      rm -f "$CLI_TARBALL" "${CLI_TARBALL}.sha256"
      exit 1
    fi
    rm "${CLI_TARBALL}.sha256"
  fi

  tar xzf "$CLI_TARBALL"
  rm "$CLI_TARBALL"
  echo "Ready."
fi

# ── Generate keys ──
echo ""
echo "Generating $NUM_VALIDATORS validator key(s) for Hoodi..."
echo "You will be prompted to:"
echo "  1. Create a mnemonic (24 words) — write it on paper, never store digitally"
echo "  2. Set a keystore password — you will need this when loading keys into Nimbus"
echo ""

"./${CLI_BINARY}/deposit" new-mnemonic \
  --num_validators "$NUM_VALIDATORS" \
  --chain hoodi \
  --execution_address "$WITHDRAWAL_ADDRESS"

echo ""
echo "=== Key generation complete ==="
echo ""
echo "Files created in validator_keys/:"
echo "  keystore-m_*.json    — encrypted keystore (needs KMS encryption before upload)"
echo "  deposit_data-*.json  — submit this to https://hoodi.launchpad.ethstaker.cc"
echo ""
echo "Next steps:"
echo "  1. Store your mnemonic offline (paper only)."
echo "  2. Encrypt: ./encrypt-keystore.sh validator_keys/keystore-m_*.json ../encrypted-keys/"
echo "  3. Submit deposit_data to the Hoodi Launchpad."
echo "  4. Upload encrypted-keys/ to the EC2 instance."
