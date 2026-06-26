#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

swift build --product VoiceChatMacApp

APP_DIR="$ROOT_DIR/.build/VoiceChat.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"

rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR"

cp "$ROOT_DIR/.build/arm64-apple-macosx/debug/VoiceChatMacApp" "$MACOS_DIR/VoiceChatMacApp"
cp "$ROOT_DIR/Support/VoiceChatAppInfo.plist" "$CONTENTS_DIR/Info.plist"
sed "s#__VOICE_CHAT_PROJECT_DIR__#$ROOT_DIR#g" "$ROOT_DIR/Support/launcher.sh" > "$MACOS_DIR/VoiceChatLauncher"
chmod +x "$MACOS_DIR/VoiceChatMacApp"
chmod +x "$MACOS_DIR/VoiceChatLauncher"

/usr/bin/codesign \
  --force \
  --deep \
  --sign - \
  --entitlements "$ROOT_DIR/Support/VoiceChat.entitlements" \
  "$APP_DIR"

echo "Built $APP_DIR"
echo "Open it with: open .build/VoiceChat.app"
