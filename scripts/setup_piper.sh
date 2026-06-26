#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PIPER_DIR="$ROOT_DIR/.local/piper"
BIN_DIR="$PIPER_DIR/piper"
PHONEMIZE_DIR="$PIPER_DIR/piper-phonemize"
VOICES_DIR="$PIPER_DIR/voices"

case "$(uname -m)" in
  arm64)
    PIPER_ARCH="aarch64"
    ;;
  x86_64)
    PIPER_ARCH="x64"
    ;;
  *)
    echo "Unsupported macOS architecture: $(uname -m)" >&2
    exit 1
    ;;
esac

PIPER_URL="https://github.com/rhasspy/piper/releases/download/2023.11.14-2/piper_macos_${PIPER_ARCH}.tar.gz"
PHONEMIZE_URL="https://github.com/rhasspy/piper-phonemize/releases/download/2023.11.14-4/piper-phonemize_macos_${PIPER_ARCH}.tar.gz"
VOICE_BASE_URL="https://huggingface.co/rhasspy/piper-voices/resolve/v1.0.0/en/en_US/lessac/medium"
VOICE_MODEL="en_US-lessac-medium.onnx"
VOICE_CONFIG="en_US-lessac-medium.onnx.json"

mkdir -p "$PIPER_DIR" "$VOICES_DIR"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

echo "Downloading Piper..."
curl -L --fail --show-error -o "$TMP_DIR/piper.tar.gz" "$PIPER_URL"
rm -rf "$BIN_DIR"
tar -xzf "$TMP_DIR/piper.tar.gz" -C "$PIPER_DIR"
chmod +x "$BIN_DIR/piper"

echo "Downloading Piper runtime libraries..."
curl -L --fail --show-error -o "$TMP_DIR/piper-phonemize.tar.gz" "$PHONEMIZE_URL"
rm -rf "$PHONEMIZE_DIR"
tar -xzf "$TMP_DIR/piper-phonemize.tar.gz" -C "$PIPER_DIR"

echo "Downloading default voice..."
curl -L --fail --show-error -o "$VOICES_DIR/$VOICE_MODEL" "$VOICE_BASE_URL/$VOICE_MODEL?download=true"
curl -L --fail --show-error -o "$VOICES_DIR/$VOICE_CONFIG" "$VOICE_BASE_URL/$VOICE_CONFIG?download=true"

echo "Piper is installed at: $BIN_DIR/piper"
echo "Voice model is installed at: $VOICES_DIR/$VOICE_MODEL"
echo
echo "The app will auto-detect this setup when launched from this repo."
echo "For CLI use from another directory, set:"
echo "  export PIPER_BIN=\"$BIN_DIR/piper\""
echo "  export PIPER_MODEL=\"$VOICES_DIR/$VOICE_MODEL\""
echo "  export PIPER_CONFIG=\"$VOICES_DIR/$VOICE_CONFIG\""
echo "  export DYLD_LIBRARY_PATH=\"$PHONEMIZE_DIR/lib\""
