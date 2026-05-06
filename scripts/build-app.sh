#!/bin/bash
set -e

APP_NAME="Flowtype"
BUNDLE_ID="com.flowtype.app"
VERSION="1.0.0"
BUILD_NUMBER="1"

echo "Building Flowtype.app..."

# Build release binary
swift build -c release

# Create app bundle structure
mkdir -p build/${APP_NAME}.app/Contents/MacOS
mkdir -p build/${APP_NAME}.app/Contents/Resources

# Copy binary
cp .build/release/FlowType build/${APP_NAME}.app/Contents/MacOS/

# Copy resources
cp Sources/flowtype/Resources/*.json build/${APP_NAME}.app/Contents/Resources/ 2>/dev/null || true
cp Sources/flowtype/Resources/*.icns build/${APP_NAME}.app/Contents/Resources/ 2>/dev/null || true
cp Sources/flowtype/Resources/status_bar_icon*.png build/${APP_NAME}.app/Contents/Resources/ 2>/dev/null || true

# Generate Info.plist
cat > build/${APP_NAME}.app/Contents/Info.plist << 'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key>
    <string>com.flowtype.app</string>
    <key>CFBundleName</key>
    <string>Flowtype</string>
    <key>CFBundleDisplayName</key>
    <string>Flowtype</string>
    <key>CFBundleExecutable</key>
    <string>FlowType</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSMicrophoneUsageDescription</key>
    <string>Flowtype 需要麦克风权限来录制你的语音输入。</string>
    <key>NSSpeechRecognitionUsageDescription</key>
    <string>Flowtype 需要语音识别权限将语音转换为文字。</string>
</dict>
</plist>
EOF

# Ad-hoc code sign the app bundle (required on macOS to avoid SIGKILL for invalid signature)
# Note: do NOT use --options runtime for ad-hoc signed apps; it enables Hardened Runtime
# which can silently block permission requests (mic, camera, etc.) on unsigned builds.
codesign --force --deep --sign - build/${APP_NAME}.app

# Clear quarantine attribute so macOS doesn't gate permission dialogs
xattr -cr build/${APP_NAME}.app 2>/dev/null || true

echo "✅ build/${APP_NAME}.app created successfully"
echo ""
echo "📦 App bundle: $(pwd)/build/${APP_NAME}.app"
echo "⚠️  IMPORTANT: This is an ad-hoc signed build."
echo "   - Microphone permission dialog may require quitting and relaunching the app."
echo "   - Accessibility permission must be granted manually in System Settings."
echo "   - See FIRST_LAUNCH.md for detailed setup instructions."
