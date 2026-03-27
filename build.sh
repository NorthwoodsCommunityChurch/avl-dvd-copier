#!/bin/bash
set -e

APP_NAME="Disc Copier"
BINARY_NAME="DVDCopier"
APP_BUNDLE="${APP_NAME}.app"
CONTENTS="${APP_BUNDLE}/Contents"
MACOS="${CONTENTS}/MacOS"
RESOURCES="${CONTENTS}/Resources"
FRAMEWORKS="${CONTENTS}/Frameworks"

echo "==> Building ${APP_NAME}..."
swift build -c release 2>&1

echo "==> Assembling app bundle..."
rm -rf "${APP_BUNDLE}"
mkdir -p "${MACOS}" "${RESOURCES}" "${FRAMEWORKS}"

# Copy binary
cp ".build/release/${BINARY_NAME}" "${MACOS}/${BINARY_NAME}"

# Copy Info.plist
cp "Sources/DVDCopier/Info.plist" "${CONTENTS}/Info.plist"

# Copy app icon
if [ -f "AppIcon.icns" ]; then
    cp "AppIcon.icns" "${RESOURCES}/AppIcon.icns"
    echo "    Icon: AppIcon.icns"
fi

# Inject version from Version.swift into Info.plist
APP_VERSION=$(grep 'static let current' Sources/DVDCopier/Version.swift | sed 's/.*"\(.*\)".*/\1/')
BUILD_NUMBER=$(grep 'static let build' Sources/DVDCopier/Version.swift | sed 's/.*"\(.*\)".*/\1/')
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString ${APP_VERSION}" "${CONTENTS}/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion ${BUILD_NUMBER}" "${CONTENTS}/Info.plist"

# Bundle Sparkle.framework
SPARKLE_FRAMEWORK=$(find .build -path "*/artifacts/sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework" -print -quit 2>/dev/null)
if [ -z "$SPARKLE_FRAMEWORK" ]; then
    SPARKLE_FRAMEWORK=$(find .build -name "Sparkle.framework" -path "*/macos*" -print -quit 2>/dev/null)
fi

if [ -n "$SPARKLE_FRAMEWORK" ] && [ -d "$SPARKLE_FRAMEWORK" ]; then
    echo "    Bundling Sparkle.framework..."
    xattr -cr "$SPARKLE_FRAMEWORK"
    cp -R "$SPARKLE_FRAMEWORK" "${FRAMEWORKS}/"
    install_name_tool -add_rpath "@executable_path/../Frameworks" "${MACOS}/${BINARY_NAME}" 2>/dev/null || true
else
    echo "    WARNING: Sparkle.framework not found — app will build without auto-update"
fi

# Clear extended attributes (OneDrive adds these)
xattr -cr "${APP_BUNDLE}"

echo "==> Signing (ad hoc)..."
# Sign nested Sparkle components inside-out
if [ -d "${FRAMEWORKS}/Sparkle.framework" ]; then
    codesign --force --sign - "${FRAMEWORKS}/Sparkle.framework/Versions/B/XPCServices/Installer.xpc" 2>/dev/null || true
    codesign --force --sign - "${FRAMEWORKS}/Sparkle.framework/Versions/B/XPCServices/Downloader.xpc" 2>/dev/null || true
    codesign --force --sign - "${FRAMEWORKS}/Sparkle.framework/Versions/B/Updater.app" 2>/dev/null || true
    codesign --force --sign - "${FRAMEWORKS}/Sparkle.framework/Versions/B/Autoupdate" 2>/dev/null || true
    codesign --force --sign - "${FRAMEWORKS}/Sparkle.framework" 2>/dev/null || true
fi
codesign --force --deep --sign - "${APP_BUNDLE}"

echo "==> Done: ${APP_BUNDLE} (v${APP_VERSION}, build ${BUILD_NUMBER})"

# Kill any running instance and reopen
echo "==> Relaunching..."
pkill -f "${BINARY_NAME}" 2>/dev/null || true
sleep 0.5
open "${APP_BUNDLE}"
