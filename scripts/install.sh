#!/usr/bin/env bash
# 把构建产物安装成「正经 App」并用 LaunchServices 启动。
#
# 为什么需要这一步（与 TCC 授权有关）：
#   1. 从终端直接跑 Contents/MacOS/MacTools，TCC 的「责任进程」是终端，屏幕录制/辅助功能
#      会继承终端的授权 —— 看着能用，实际 App 自己没有记录；换成 Finder 双击就又没权限。
#   2. 路径只影响可维护性（build/ 会被 xcodebuild clean 删掉），不影响授权是否有效。
#   3. 真正决定授权能不能长期保留的是签名：ad-hoc 签名的指定要求只有 CDHash，
#      每次重新构建都会变，系统就把新构建当成另一个 App。用固定证书签名（哪怕自签名）
#      后，指定要求变成 `identifier "…" and certificate root = H"…"`，与 CDHash 无关，
#      授权才能跨构建保留。本机有「MacTools Dev」身份时会自动用它
#      （没有就先跑 ./scripts/make-signing-identity.sh 建一个）。
#
# 用法：
#   ./scripts/install.sh                 # 安装 Release 到 /Applications
#   ./scripts/install.sh Debug           # 安装 Debug 构建
#   ./scripts/install.sh Release --reset # 安装并重置屏幕录制授权记录后再启动
#   MACTOOLS_SIGN_IDENTITY="MacTools Dev" ./scripts/install.sh   # 强制指定签名身份
set -euo pipefail

CONFIG="${1:-Release}"
shift || true

RESET_PERMISSION=0
for argument in "$@"; do
  case "$argument" in
    --reset) RESET_PERMISSION=1 ;;
    *) echo "未知参数：$argument" >&2; exit 2 ;;
  esac
done

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SOURCE="$ROOT/build/Build/Products/$CONFIG/MacTools.app"
BUNDLE_ID="dev.mactools.MacTools"

if [[ ! -d "$SOURCE" ]]; then
  echo "未找到 $CONFIG 构建产物：$SOURCE" >&2
  echo "先跑 ./scripts/build.sh $CONFIG" >&2
  exit 1
fi

# /Applications 通常可写；不可写时退到 ~/Applications（LaunchServices 同样认）。
if [[ -n "${MACTOOLS_INSTALL_DIR:-}" ]]; then
  DEST_DIR="$MACTOOLS_INSTALL_DIR"
  mkdir -p "$DEST_DIR"
else
  DEST_DIR="/Applications"
  if [[ ! -w "$DEST_DIR" ]]; then
    DEST_DIR="$HOME/Applications"
    mkdir -p "$DEST_DIR"
  fi
fi
DEST="$DEST_DIR/MacTools.app"

if pgrep -f "MacTools.app/Contents/MacOS/MacTools" >/dev/null 2>&1; then
  echo "正在退出已运行的 MacTools…"
  pkill -f "MacTools.app/Contents/MacOS/MacTools" || true
  sleep 1
fi

echo "安装：$SOURCE"
echo "   →  $DEST"
rm -rf "$DEST"
cp -R "$SOURCE" "$DEST"

# 复制后重签一次：固定标识、去掉构建机的扩展属性，避免 Gatekeeper 判定为损坏。
# 优先用固定签名身份（存在的话），否则退回 ad-hoc —— 见文件顶部第 3 条。
DEFAULT_IDENTITY="MacTools Dev"
if [[ -z "${MACTOOLS_SIGN_IDENTITY:-}" ]]; then
  if security find-identity -p codesigning 2>/dev/null | grep -q "\"$DEFAULT_IDENTITY\""; then
    MACTOOLS_SIGN_IDENTITY="$DEFAULT_IDENTITY"
  else
    MACTOOLS_SIGN_IDENTITY="-"
  fi
fi
SIGN_IDENTITY="$MACTOOLS_SIGN_IDENTITY"
if [[ "$SIGN_IDENTITY" == "-" ]]; then
  echo "签名：ad-hoc（cdhash 每次都变，TCC 授权会随重装失效）"
  echo "      想一劳永逸：./scripts/make-signing-identity.sh"
else
  # 花括号是必需的：本脚本的 shebang 是 bash，而 macOS 自带的 bash 3.2 会把紧随
  # 变量名的多字节字符首字节并入变量名（zsh 不会），`set -u` 下直接 unbound 报错。
  echo "签名：${SIGN_IDENTITY}（指定要求与 cdhash 无关，授权可跨构建保留）"
fi
xattr -cr "$DEST"
codesign --force --deep --sign "$SIGN_IDENTITY" "$DEST"

if [[ "$RESET_PERMISSION" == "1" ]]; then
  echo "重置屏幕录制授权记录（${BUNDLE_ID}）…"
  tccutil reset ScreenCapture "$BUNDLE_ID" || true
fi

codesign -d -r- "$DEST" 2>&1 | tail -1 || true

echo "启动（经 LaunchServices，父进程为 launchd，TCC 按 App 自身身份判定）…"
open "$DEST"

cat <<'NOTE'

接下来：
  1. 首次点截图 → 系统弹「屏幕录制」授权 → 勾选允许后，**必须退出并重新打开 MacTools** 才生效
     （面板里会给出「重启 MacTools」按钮，点它即可）。
  2. 之后只要覆盖安装的仍是同一个签名，授权就一直有效。
  3. 用固定身份签名时，重新构建 / 重装都**不会**让授权失效（指定要求里是证书 hash，
     没有 cdhash）；只有换了证书（或重新 ./scripts/make-signing-identity.sh --force）
     才需要在系统设置里删掉旧的 MacTools 条目再授权一次。
NOTE
