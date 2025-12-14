#!/bin/bash
# Build Claude Island for release
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
BUILD_DIR="$PROJECT_DIR/build"
ARCHIVE_PATH="$BUILD_DIR/ClaudeIsland.xcarchive"
EXPORT_PATH="$BUILD_DIR/export"

echo "=== Building Claude Island ==="
echo ""

# Clean previous builds
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

cd "$PROJECT_DIR"

# Build and archive
echo "Archiving..."
xcodebuild archive \
    -scheme ClaudeIsland \
    -configuration Release \
    -archivePath "$ARCHIVE_PATH" \
    -destination "generic/platform=macOS" \
    ENABLE_HARDENED_RUNTIME=YES \
    CODE_SIGN_STYLE=Automatic \
    | xcpretty || xcodebuild archive \
    -scheme ClaudeIsland \
    -configuration Release \
    -archivePath "$ARCHIVE_PATH" \
    -destination "generic/platform=macOS" \
    ENABLE_HARDENED_RUNTIME=YES \
    CODE_SIGN_STYLE=Automatic

# Create ExportOptions.plist if it doesn't exist
EXPORT_OPTIONS="$BUILD_DIR/ExportOptions.plist"
cat > "$EXPORT_OPTIONS" << 'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key>
    <string>developer-id</string>
    <key>destination</key>
    <string>export</string>
    <key>signingStyle</key>
    <string>automatic</string>
</dict>
</plist>
EOF

# Export the archive
echo ""
echo "Exporting..."
set +e
xcodebuild -exportArchive \
    -archivePath "$ARCHIVE_PATH" \
    -exportPath "$EXPORT_PATH" \
    -exportOptionsPlist "$EXPORT_OPTIONS" \
    | xcpretty
EXPORT_RESULT=${PIPESTATUS[0]}
if [ $EXPORT_RESULT -ne 0 ]; then
    xcodebuild -exportArchive \
        -archivePath "$ARCHIVE_PATH" \
        -exportPath "$EXPORT_PATH" \
        -exportOptionsPlist "$EXPORT_OPTIONS"
    EXPORT_RESULT=$?
fi
set -e

if [ $EXPORT_RESULT -ne 0 ]; then
    echo ""
    echo "Export failed (likely missing signing Team). Falling back to local installable app from archive..."
    mkdir -p "$EXPORT_PATH"
    rm -rf "$EXPORT_PATH/Claude Island.app"
    cp -R "$ARCHIVE_PATH/Products/Applications/Claude Island.app" "$EXPORT_PATH/"
    echo "App copied to: $EXPORT_PATH/Claude Island.app"
fi

# ============================================
# Step 2: Sign the app for local use
# ============================================
echo ""
echo "=== Signing App for Local Use ==="

APP_PATH="$EXPORT_PATH/Claude Island.app"

# Kill any running instances
echo "Stopping any running instances..."
pkill -f "Claude Island" || true
sleep 1

# Sign the main app
echo "Signing main app..."
codesign --force --deep --sign - "$APP_PATH" 2>/dev/null || echo "Warning: Main app signing had issues"

# Sign all frameworks
echo "Signing frameworks..."
find "$APP_PATH/Contents/Frameworks" -name "*.framework" -exec codesign --force --sign - {} \; 2>/dev/null || true

# Sign all binaries in MacOS
echo "Signing binaries..."
find "$APP_PATH/Contents/MacOS" -type f -exec codesign --force --sign - {} \; 2>/dev/null || true

echo "Signing complete!"

# ============================================
# Step 3: Install the app
# ============================================
echo ""
echo "=== Installing App ==="

# Check if app exists in Applications
if [ -d "/Applications/Claude Island.app" ]; then
    echo "Removing old version from Applications..."
    rm -rf "/Applications/Claude Island.app"
fi

# Copy to Applications
echo "Installing to /Applications..."
cp -R "$APP_PATH" /Applications/

echo "App installed to /Applications/"

# ============================================
# Step 4: Launch the app
# ============================================
echo ""
echo "=== Launching App ==="

# Launch the installed app
open -a "Claude Island" 2>/dev/null || echo "Failed to launch app. You can manually start it from Applications folder."

echo ""
echo "=== Build and Install Complete ==="
echo "App exported to: $EXPORT_PATH/Claude Island.app"
echo "App installed to: /Applications/Claude Island.app"
echo "App is now running in the menu bar!"
echo ""
echo "Next: Run ./scripts/create-release.sh to create DMG for distribution"
