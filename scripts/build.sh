#!/bin/zsh
# 构建脚本
#
# 需要完整 Xcode（不只是 CommandLineTools）：Swift 宏插件（@Observable）与 macOS SDK
# 都由 Xcode 提供。若 xcode-select 指向 CommandLineTools，这里会自动优先用 Xcode.app。
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${1:-Debug}"

if [[ -z "${DEVELOPER_DIR:-}" && -d "/Applications/Xcode.app/Contents/Developer" ]]; then
  export DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer"
fi

# `-Xfrontend -disable-sandbox` 关掉编译器插件沙箱：在禁止 sandbox-exec 的环境里
# （部分受管机器 / CI），SPM 清单编译与 @Observable 宏插件无法在沙箱内运行。
# 普通桌面环境留着无害；想恢复编译期沙箱可设 MACTOOLS_COMPILER_SANDBOX=1。
SWIFT_FLAGS=()
if [[ "${MACTOOLS_COMPILER_SANDBOX:-0}" != "1" ]]; then
  SWIFT_FLAGS+=("OTHER_SWIFT_FLAGS=-Xfrontend -disable-sandbox")
fi

xcodebuild \
  -project MacTools.xcodeproj \
  -scheme MacTools \
  -configuration "$CONFIG" \
  -derivedDataPath ./build \
  "${SWIFT_FLAGS[@]}" \
  build
