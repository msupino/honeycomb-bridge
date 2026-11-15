#!/bin/bash
set -euo pipefail
project_dir=$(cd -- "$(dirname -- "$0")" && pwd)
sdk_dir=${1:-}
if [[ -z "$sdk_dir" || ! -f "$sdk_dir/CHeaders/XPLM/XPLMPlugin.h" ]]; then
    printf 'Usage: %s /absolute/path/to/XPlaneSDK/SDK\n' "$0" >&2
    exit 2
fi
mkdir -p "$project_dir/.build"
xcrun clang++ -std=c++17 -DAPL=1 -DIBM=0 -DLIN=0 -DXPLM200=1 -DXPLM210=1 \
    -DXPLM300=1 -DXPLM301=1 -DXPLM303=1 -DXPLM400=1 \
    -I "$sdk_dir/CHeaders/XPLM" "$project_dir/XPlane/PluginTests.cpp" -o "$project_dir/.build/plugin-tests"
"$project_dir/.build/plugin-tests"
