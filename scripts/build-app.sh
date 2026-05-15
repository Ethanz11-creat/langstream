#!/bin/bash
set -e

APP_NAME="FlowType"
BUNDLE_ID="com.flowtype.app"
VERSION="1.0.0"
BUILD_NUMBER="1"

echo "Building FlowType.app..."

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

# Copy MLX Metal shader library (required for Qwen3-ASR GPU inference).
# SPM cannot compile .metal shaders; we use the pre-compiled metallib from
# the Python mlx-metal wheel cached by pip/uv.
MLX_METALLIB=""
for candidate in \
    "$HOME/.cache/uv/archive-v0/"*/mlx/lib/mlx.metallib \
    "$HOME/.cache/pip/"*/mlx/lib/mlx.metallib \
    "$(python3 -c 'import mlx, pathlib; print(pathlib.Path(mlx.__file__).parent / "lib" / "mlx.metallib")' 2>/dev/null)"; do
    if [ -f "$candidate" ]; then
        MLX_METALLIB="$candidate"
        break
    fi
done
if [ -n "$MLX_METALLIB" ]; then
    cp "$MLX_METALLIB" build/${APP_NAME}.app/Contents/MacOS/mlx.metallib
    echo "✅ MLX metallib copied from $MLX_METALLIB"
else
    echo "⚠️  WARNING: mlx.metallib not found. Install Python mlx-metal (pip install mlx) to provide it."
    echo "   Qwen3-ASR will crash at runtime without this file."
fi

# Generate Info.plist
cat > build/${APP_NAME}.app/Contents/Info.plist << 'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key>
    <string>com.flowtype.app</string>
    <key>CFBundleName</key>
    <string>FlowType</string>
    <key>CFBundleDisplayName</key>
    <string>FlowType</string>
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
    <key>LSMinimumSystemVersion</key>
    <string>15.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSMicrophoneUsageDescription</key>
    <string>FlowType needs microphone access to record your voice input.</string>
    <key>NSSpeechRecognitionUsageDescription</key>
    <string>FlowType needs speech recognition access to convert voice to text.</string>
    <key>NSAccessibilityUsageDescription</key>
    <string>FlowType needs accessibility access to detect global hotkeys and inject text into other applications.</string>
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
echo "   - First-time users: right-click the app → Open, or run: xattr -cr build/${APP_NAME}.app"
echo "   - Microphone permission dialog may require quitting and relaunching the app."
echo "   - Accessibility permission must be granted manually in System Settings."
