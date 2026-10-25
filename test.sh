#!/bin/zsh
set -eu
PROJECT_DIR="${0:A:h}"
mkdir -p "$PROJECT_DIR/.build"
/usr/bin/xcrun swiftc -swift-version 5 -module-cache-path "$PROJECT_DIR/.build/module-cache" \
  "$PROJECT_DIR/Sources/SelectionLink.swift" "$PROJECT_DIR/Sources/ResultDelivery.swift" "$PROJECT_DIR/Sources/Engine.swift" "$PROJECT_DIR/Sources/Extended.swift" "$PROJECT_DIR/Sources/Tools.swift" "$PROJECT_DIR/Sources/Wheel.swift" "$PROJECT_DIR/Sources/UI.swift" "$PROJECT_DIR/Tests/main.swift" \
  -framework AppKit -framework SwiftUI -framework PDFKit -framework ImageIO -framework UniformTypeIdentifiers -framework CoreText -framework AVFoundation -framework ServiceManagement -framework FinderSync \
  -o "$PROJECT_DIR/.build/OrbitTests"
"$PROJECT_DIR/.build/OrbitTests" "$@"
