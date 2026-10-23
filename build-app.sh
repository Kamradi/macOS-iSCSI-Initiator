#!/bin/zsh
set -eu
cd "${0:A:h}"
swift build -c release
APP="${ISCSI_APP_OUTPUT:-dist/SynologyInitiator.app}"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/SynologyInitiator "$APP/Contents/MacOS/SynologyInitiator"
cp .build/release/iscsi-bridge "$APP/Contents/MacOS/iscsi-bridge"
cp .build/release/iscsi dist/iscsi
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>SynologyInitiator</string>
<key>CFBundleIdentifier</key><string>local.synologyinitiator.app</string>
<key>CFBundleName</key><string>Synology iSCSI</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.3.2</string>
<key>CFBundleVersion</key><string>5</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSLocalNetworkUsageDescription</key><string>Подключение к iSCSI Target на вашем Synology NAS.</string>
</dict></plist>
PLIST
codesign --force --sign - "$APP/Contents/MacOS/iscsi-bridge"
codesign --force --sign - "$APP"
codesign --verify --deep --strict "$APP"
echo "Собрано: $PWD/$APP"
