#!/usr/bin/env bash
set -euo pipefail

APP_DIR="GoogleTVVoiceBridge.app"
rm -rf "${APP_DIR}"
mkdir -p "${APP_DIR}/Contents/MacOS"
cp Info.plist "${APP_DIR}/Contents/Info.plist"

swiftc -O main.swift \
  -o "${APP_DIR}/Contents/MacOS/GoogleTVVoiceBridge" \
  -framework Cocoa \
  -framework CoreBluetooth \
  -framework AVFoundation \
  -framework CoreAudio \
  -framework AudioToolbox \
  -framework ApplicationServices

codesign --force --sign - "${APP_DIR}"
echo "Built ${APP_DIR} successfully."
