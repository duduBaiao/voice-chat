#!/usr/bin/env bash
set -euo pipefail

export VOICE_CHAT_PROJECT_DIR="__VOICE_CHAT_PROJECT_DIR__"
exec "$(dirname "$0")/VoiceChatMacApp" "$@"
