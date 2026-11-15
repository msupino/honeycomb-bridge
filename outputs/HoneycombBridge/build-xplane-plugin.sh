#!/bin/bash
set -euo pipefail
project_dir=$(cd -- "$(dirname -- "$0")" && pwd)
sdk_dir=${1:-}
if [[ -z "$sdk_dir" || ! -f "$sdk_dir/CHeaders/XPLM/XPLMPlugin.h" ]]; then
    printf 'Usage: %s /absolute/path/to/XPlaneSDK/SDK\n' "$0" >&2
    exit 2
fi
plugin_dir="$project_dir/HoneycombInput/mac_x64"
mkdir -p "$plugin_dir"
xcrun clang++ -std=c++17 -arch arm64 -mmacosx-version-min=15.0 -bundle -fPIC \
    -DAPL=1 -DIBM=0 -DLIN=0 -DXPLM200=1 -DXPLM210=1 -DXPLM300=1 -DXPLM301=1 -DXPLM303=1 -DXPLM400=1 \
    -I "$sdk_dir/CHeaders/XPLM" -F "$sdk_dir/Libraries/Mac" -framework XPLM \
    "$project_dir/XPlane/Plugin.cpp" -o "$plugin_dir/HoneycombInput.xpl"
codesign --force --sign - "$plugin_dir/HoneycombInput.xpl"
printf 'Built %s\n' "$plugin_dir/HoneycombInput.xpl"
