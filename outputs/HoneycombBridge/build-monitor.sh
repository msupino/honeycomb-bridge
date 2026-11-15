#!/bin/bash
set -euo pipefail
project_dir=$(cd -- "$(dirname -- "$0")" && pwd)
swift build --package-path "$project_dir" -c release
bin_dir=$(swift build --package-path "$project_dir" -c release --show-bin-path)
app_dir="$project_dir/Honeycomb Monitor.app"
mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Helpers" "$app_dir/Contents/Resources"
cp "$project_dir/Icon/AppIcon.icns" "$app_dir/Contents/Resources/AppIcon.icns"
cp "$bin_dir/honeycomb-monitor" "$app_dir/Contents/MacOS/honeycomb-monitor"
cp "$bin_dir/honeycomb-usb-read" "$app_dir/Contents/Helpers/honeycomb-usb-read"
cat > "$app_dir/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>local.honeycomb.research.monitor</string>
<key>CFBundleName</key><string>Honeycomb Monitor</string>
<key>CFBundleDisplayName</key><string>Honeycomb Monitor</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundleExecutable</key><string>honeycomb-monitor</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleVersion</key><string>1</string>
<key>CFBundleShortVersionString</key><string>0.1</string>
<key>LSMinimumSystemVersion</key><string>15.0</string>
<key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSPrincipalClass</key><string>NSApplication</string>
</dict></plist>
PLIST
xattr -dr com.apple.FinderInfo "$app_dir" 2>/dev/null || true
xattr -dr com.apple.ResourceFork "$app_dir" 2>/dev/null || true
codesign --force --sign - "$app_dir/Contents/Helpers/honeycomb-usb-read"
codesign --force --sign - "$app_dir"
codesign --verify --strict --deep "$app_dir"
printf 'Built %s\n' "$app_dir"
