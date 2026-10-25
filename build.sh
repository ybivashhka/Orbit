#!/bin/zsh
set -eu
PROJECT_DIR="${0:A:h}"
APP_PATH="${1:-${PROJECT_DIR:h}/Orbit.app}"
mkdir -p "$APP_PATH/Contents/MacOS" "$APP_PATH/Contents/Resources"
/usr/bin/python3 "$PROJECT_DIR/resources.py" "$APP_PATH"
if [[ -f "$PROJECT_DIR/Resources/Orbit.icns" ]]; then /bin/cp "$PROJECT_DIR/Resources/Orbit.icns" "$APP_PATH/Contents/Resources/Orbit.icns"; fi
/usr/bin/xcrun swiftc -swift-version 5 -O -target arm64-apple-macosx14.0 -module-cache-path "$PROJECT_DIR/.build/module-cache" \
  "$PROJECT_DIR/Sources/SelectionLink.swift" "$PROJECT_DIR/Sources/ResultDelivery.swift" "$PROJECT_DIR/Sources/Engine.swift" "$PROJECT_DIR/Sources/Extended.swift" "$PROJECT_DIR/Sources/Tools.swift" "$PROJECT_DIR/Sources/Wheel.swift" "$PROJECT_DIR/Sources/UI.swift" "$PROJECT_DIR/Sources/main.swift" \
  -framework AppKit -framework SwiftUI -framework PDFKit -framework ImageIO -framework UniformTypeIdentifiers -framework CoreText -framework AVFoundation -framework ServiceManagement -framework FinderSync \
  -o "$APP_PATH/Contents/MacOS/Orbit"
EXTENSION_PATH="$APP_PATH/Contents/PlugIns/OrbitFinder.appex"
mkdir -p "$EXTENSION_PATH/Contents/MacOS"
/usr/bin/xcrun swiftc -swift-version 5 -O -target arm64-apple-macosx14.0 -module-cache-path "$PROJECT_DIR/.build/module-cache" \
  -application-extension -parse-as-library -module-name OrbitFinder \
  "$PROJECT_DIR/Sources/SelectionLink.swift" "$PROJECT_DIR/FinderExtension/FinderSync.swift" -framework AppKit -framework FinderSync \
  -Xlinker -e -Xlinker _NSExtensionMain -o "$EXTENSION_PATH/Contents/MacOS/OrbitFinder"
/usr/bin/codesign --force --sign - --identifier dev.ybivashhka.orbit.finder --entitlements "$PROJECT_DIR/FinderExtension/entitlements.plist" "$EXTENSION_PATH"
/usr/bin/codesign --force --sign - --identifier dev.ybivashhka.orbit --entitlements "$PROJECT_DIR/Resources/entitlements.plist" "$APP_PATH"
/usr/bin/plutil -lint "$APP_PATH/Contents/Info.plist"
print "Готово: $APP_PATH"
