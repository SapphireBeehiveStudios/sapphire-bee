#!/bin/bash
# fetch_godot.sh - Downloads and verifies Godot headless binary for Linux
#
# Supports both x86_64 and arm64 architectures (auto-detected).
#
# Download sources:
#   - godotengine/godot-builds (GitHub) - All releases (stable, beta, rc, dev)
#   - godotengine/godot (GitHub) - Stable releases only
#   - downloads.tuxfamily.org - Alternative mirror
#
# See: https://godotengine.org/download/archive/

set -euo pipefail

GODOT_VERSION="${GODOT_VERSION:-4.6}"
GODOT_RELEASE_TYPE="${GODOT_RELEASE_TYPE:-beta2}"

# Detect architecture
ARCH=$(uname -m)
case "$ARCH" in
    x86_64|amd64)
        GODOT_ARCH="x86_64"
        ;;
    aarch64|arm64)
        GODOT_ARCH="arm64"
        ;;
    *)
        echo "ERROR: Unsupported architecture: $ARCH"
        exit 1
        ;;
esac

# Godot binary naming convention: Godot_v{VERSION}-{TYPE}_linux.{ARCH}
GODOT_BINARY_NAME="Godot_v${GODOT_VERSION}-${GODOT_RELEASE_TYPE}_linux.${GODOT_ARCH}"

# Build download URLs
# GitHub repos:
#   godotengine/godot       - stable releases only
#   godotengine/godot-builds - ALL releases (stable, beta, rc, dev)
# TuxFamily mirror - alternative source

if [[ "$GODOT_RELEASE_TYPE" == "stable" ]]; then
    # Stable releases are on both repos
    GITHUB_BASE="https://github.com/godotengine/godot/releases/download/${GODOT_VERSION}-${GODOT_RELEASE_TYPE}"
    TUXFAMILY_URL="https://downloads.tuxfamily.org/godotengine/${GODOT_VERSION}/${GODOT_BINARY_NAME}.zip"
else
    # Pre-releases (beta, rc, dev) are ONLY on godot-builds repo
    GITHUB_BASE="https://github.com/godotengine/godot-builds/releases/download/${GODOT_VERSION}-${GODOT_RELEASE_TYPE}"
    TUXFAMILY_URL="https://downloads.tuxfamily.org/godotengine/${GODOT_VERSION}/${GODOT_RELEASE_TYPE}/${GODOT_BINARY_NAME}.zip"
fi

GITHUB_URL="${GITHUB_BASE}/${GODOT_BINARY_NAME}.zip"
SHA512_SUMS_URL="${GITHUB_BASE}/SHA512-SUMS.txt"

INSTALL_DIR="${INSTALL_DIR:-/opt/godot}"
TEMP_DIR=$(mktemp -d)

cleanup() {
    rm -rf "$TEMP_DIR"
}
trap cleanup EXIT

echo "=== Godot Headless/Server Binary Fetcher ==="
echo "Version: ${GODOT_VERSION}-${GODOT_RELEASE_TYPE}"
echo "Architecture: ${GODOT_ARCH} (detected: ${ARCH})"
echo "Binary name: ${GODOT_BINARY_NAME}"
echo "Install directory: ${INSTALL_DIR}"
echo ""
echo "Download URLs:"
echo "  Binary:   ${GITHUB_URL}"
echo "  Checksums: ${SHA512_SUMS_URL}"
echo "  Fallback: ${TUXFAMILY_URL}"
echo ""

cd "$TEMP_DIR"

# Download the binary - try GitHub first, then TuxFamily as fallback
download_success=false

for url in "$GITHUB_URL" "$TUXFAMILY_URL"; do
    echo "Downloading Godot from: ${url}"
    if command -v curl &> /dev/null; then
        if curl -fSL --progress-bar -o godot.zip "$url"; then
            download_success=true
            echo "Download successful!"
            break
        else
            echo "curl failed with exit code: $?"
        fi
    elif command -v wget &> /dev/null; then
        if wget -q --show-progress -O godot.zip "$url"; then
            download_success=true
            echo "Download successful!"
            break
        else
            echo "wget failed with exit code: $?"
        fi
    else
        echo "ERROR: Neither curl nor wget available"
        exit 1
    fi
    echo "Failed to download from ${url}, trying next mirror..."
done

if [[ "$download_success" != "true" ]]; then
    echo "ERROR: Failed to download Godot from all mirrors"
    echo "Tried:"
    echo "  - ${GITHUB_URL}"
    echo "  - ${TUXFAMILY_URL}"
    exit 1
fi

# Download and verify using official SHA512 checksums
echo ""
echo "Downloading SHA512 checksums from: ${SHA512_SUMS_URL}"
if curl -fsSL -o SHA512-SUMS.txt "$SHA512_SUMS_URL"; then
    echo "Verifying SHA512 checksum..."
    
    # Extract expected checksum for our binary
    EXPECTED_SHA512=$(grep "${GODOT_BINARY_NAME}.zip" SHA512-SUMS.txt | awk '{print $1}')
    
    if [[ -z "$EXPECTED_SHA512" ]]; then
        echo "WARNING: Could not find checksum for ${GODOT_BINARY_NAME}.zip in SHA512-SUMS.txt"
        echo "Skipping verification..."
    else
        ACTUAL_SHA512=$(sha512sum godot.zip | awk '{print $1}')
        
        if [[ "$ACTUAL_SHA512" != "$EXPECTED_SHA512" ]]; then
            echo "ERROR: Checksum verification failed!"
            echo "Expected: ${EXPECTED_SHA512}"
            echo "Got:      ${ACTUAL_SHA512}"
            echo ""
            echo "This could indicate:"
            echo "- Corrupted download"
            echo "- Tampered file"
            exit 1
        fi
        
        echo "✓ SHA512 checksum verified successfully!"
    fi
else
    echo "WARNING: Could not download SHA512-SUMS.txt, skipping verification"
fi

echo "Extracting to ${INSTALL_DIR}..."
mkdir -p "$INSTALL_DIR"
unzip -q godot.zip -d "$INSTALL_DIR"

# Rename to a consistent name
mv "${INSTALL_DIR}/${GODOT_BINARY_NAME}" "${INSTALL_DIR}/godot"
chmod +x "${INSTALL_DIR}/godot"

echo "Creating symlink in /usr/local/bin..."
ln -sf "${INSTALL_DIR}/godot" /usr/local/bin/godot

echo ""
echo "=== Installation complete ==="
echo "Godot binary: ${INSTALL_DIR}/godot"
echo "Symlink: /usr/local/bin/godot"
echo ""
echo "Verify with: godot --headless --version"

