#!/bin/zsh
# 无人工交互的状态机/存储验收：直接驱动 HUDRouter 与各 Store。
# 输出逐条断言，退出码 0 = 全部通过。
set -euo pipefail
cd "$(dirname "$0")/.."

APP="./build/Build/Products/Debug/MacTools.app/Contents/MacOS/MacTools"
if [[ ! -x "$APP" ]]; then
  echo "未找到 Debug 产物：$APP" >&2
  echo "先运行 ./scripts/build.sh Debug（注意 xcodebuild clean 会同时清掉 Debug 与 Release 产物）" >&2
  exit 1
fi

pkill -f "MacTools.app/Contents/MacOS/MacTools" 2>/dev/null || true
MACTOOLS_DEBUG_SELFTEST=1 "$APP" 2>&1 | grep -v "TSMSendMessageToUIServer"
