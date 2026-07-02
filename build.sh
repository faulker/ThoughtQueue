#!/bin/bash
set -e

INPUT="${1:-Debug}"
CONFIG="$(tr '[:lower:]' '[:upper:]' <<< "${INPUT:0:1}")$(tr '[:upper:]' '[:lower:]' <<< "${INPUT:1}")"
BUILD_DIR="build"

echo "==> Generating Xcode project..."
xcodegen generate

SIGN_ARGS=()
if [ "$CONFIG" = "Release" ]; then
  echo "==> Locating Developer ID Application identity..."
  IDENTITY_LINE="$(security find-identity -v -p codesigning | grep "Developer ID Application" | head -1 || true)"

  if [ -z "$IDENTITY_LINE" ]; then
    echo "==> ERROR: no 'Developer ID Application' identity in keychain."
    echo "    Install your certificate from developer.apple.com, then re-run."
    exit 1
  fi

  IDENTITY="$(sed -E 's/.*"(Developer ID Application: [^"]+)".*/\1/' <<< "$IDENTITY_LINE")"
  TEAM_ID="$(sed -E 's/.*\(([A-Z0-9]+)\)"?$/\1/' <<< "$IDENTITY")"

  echo "    Identity: $IDENTITY"
  echo "    Team ID:  $TEAM_ID"

  SIGN_ARGS=(
    CODE_SIGN_STYLE=Manual
    CODE_SIGN_IDENTITY="$IDENTITY"
    DEVELOPMENT_TEAM="$TEAM_ID"
    ENABLE_HARDENED_RUNTIME=YES
    OTHER_CODE_SIGN_FLAGS="--timestamp --options=runtime"
  )
fi

echo "==> Building ThoughtQueue ($CONFIG)..."
xcodebuild -project ThoughtQueue.xcodeproj \
  -scheme ThoughtQueue \
  -configuration "$CONFIG" \
  -derivedDataPath "$BUILD_DIR" \
  "${SIGN_ARGS[@]}" \
  build | tail -5

APP_PATH="$BUILD_DIR/Build/Products/$CONFIG/ThoughtQueue.app"

if [ ! -f "$APP_PATH/Contents/MacOS/ThoughtQueue" ]; then
  echo "==> Build failed"
  exit 1
fi

echo "==> Build succeeded: $APP_PATH"

if [ "$CONFIG" = "Release" ]; then
  echo "==> Verifying signature..."
  codesign --verify --deep --strict --verbose=2 "$APP_PATH"
  codesign --display --verbose=2 "$APP_PATH" 2>&1 | grep -E "^(Identifier|Authority|TeamIdentifier|Timestamp|Runtime)" || true
fi

echo ""
echo "Run with:  open $APP_PATH"
