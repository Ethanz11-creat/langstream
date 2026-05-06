#!/bin/bash
set -e

APP_NAME="Flowtype"
VERSION="1.0.0"
DMG_NAME="${APP_NAME}-${VERSION}.dmg"
BUILD_DIR="build"

echo "Building DMG..."

# Ensure .app exists
if [ ! -d "${BUILD_DIR}/${APP_NAME}.app" ]; then
    echo "Error: ${BUILD_DIR}/${APP_NAME}.app not found. Run build-app.sh first."
    exit 1
fi

# Clean up old DMG
rm -f "${BUILD_DIR}/${DMG_NAME}"

# Create a temporary directory for DMG contents
TMP_DIR=$(mktemp -d)
cp -R "${BUILD_DIR}/${APP_NAME}.app" "${TMP_DIR}/"

# Create a symlink to /Applications for drag-and-drop install
ln -s /Applications "${TMP_DIR}/Applications"

# Create the DMG
hdiutil create \
    -volname "${APP_NAME}" \
    -srcfolder "${TMP_DIR}" \
    -ov \
    -format UDZO \
    "${BUILD_DIR}/${DMG_NAME}"

# Clean up temp directory
rm -rf "${TMP_DIR}"

echo "✅ ${BUILD_DIR}/${DMG_NAME} created successfully"
echo ""
echo "Upload to GitHub Releases:"
echo "  gh release create v${VERSION} ${BUILD_DIR}/${DMG_NAME} --title 'Flowtype v${VERSION}' --notes 'Release notes here'"
