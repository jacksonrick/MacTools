#!/bin/zsh
# 创建本地自签名「代码签名」身份，解决 ad-hoc 签名的授权易失问题。
#
# 为什么需要它：
#   ad-hoc 签名（codesign -s -）的「指定要求」只有 CDHash，每次构建 / 重装都会变，
#   系统（TCC）因此把新构建当成另一个 App —— 辅助功能、屏幕录制的授权全部作废，
#   表现为「刚授权完又提示没权限」。换成固定证书签名后，指定要求变成
#    `identifier "dev.mactools.MacTools" and certificate leaf = H"…"`，
#   只要证书不变，授权就能跨构建、跨重装保留。
#
# 自签名证书就够用（不需要付费开发者账号）。它只用于本机签名：
#   · 不进入系统信任列表（Gatekeeper 只针对隔离标记的下载文件，本地构建不涉及）；
#   · 正式对外分发仍需开发者证书 + 公证。
#
# 用法：
#   ./scripts/make-signing-identity.sh          # 创建（已存在则直接退出）
#   ./scripts/make-signing-identity.sh --force   # 删掉同名身份重建
set -euo pipefail

IDENTITY_NAME="${MACTOOLS_SIGN_IDENTITY:-MacTools Dev}"
KEYCHAIN="${MACTOOLS_SIGN_KEYCHAIN:-$HOME/Library/Keychains/login.keychain-db}"
P12_PASSWORD="mactools"
FORCE=0

for argument in "$@"; do
  case "$argument" in
    --force) FORCE=1 ;;
    *) echo "未知参数：$argument" >&2; exit 2 ;;
  esac
done

if [[ ! -f "$KEYCHAIN" ]]; then
  echo "找不到钥匙串：$KEYCHAIN" >&2
  exit 1
fi

# 注意这里**不加 -v**：自签证书不在系统信任链里，`find-identity -v` 只列「有效」
# 身份，会把它当作不存在。而签名与校验本身都不需要这份信任 —— 实测
# `codesign --sign "MacTools Dev"` 成功、`codesign -v` 退出码 0。
exists() {
  security find-identity -p codesigning 2>/dev/null | grep -q "\"$IDENTITY_NAME\""
}

if exists && [[ "$FORCE" == "0" ]]; then
  echo "已存在签名身份「$IDENTITY_NAME」，无需重复创建。"
  security find-identity -p codesigning | grep "\"$IDENTITY_NAME\""
  echo "（列表里的 CSSMERR_TP_NOT_TRUSTED 是自签证书的正常状态，不影响签名。）"
  exit 0
fi

if exists && [[ "$FORCE" == "1" ]]; then
  echo "删除旧的「$IDENTITY_NAME」…"
  # 私钥与证书都删，避免同名但密钥不匹配的僵尸条目。
  security delete-identity -c "$IDENTITY_NAME" "$KEYCHAIN" >/dev/null 2>&1 || true
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# 用配置文件而不是 -addext：LibreSSL 与不同版本的 OpenSSL 对 -addext 支持不一致。
# 证书 CN 必须是身份名，所以这里直接插值，避免再依赖 sed（macOS 自带 sed 与
# 部分环境里的 GNU sed 对 `-i ''` 的解释不同，容易踩坑）。
cat > "$WORK/openssl.cnf" <<CONF
[ req ]
distinguished_name = dn
prompt             = no
x509_extensions    = codesign

[ dn ]
CN = $IDENTITY_NAME
O  = MacTools
C  = CN

[ codesign ]
basicConstraints       = critical,CA:false
keyUsage               = critical,digitalSignature
extendedKeyUsage       = critical,codeSigning
subjectKeyIdentifier   = hash
CONF

echo "生成自签名证书（$IDENTITY_NAME，10 年）…"
openssl req -x509 -newkey rsa:2048 -sha256 -days 3650 -nodes \
  -keyout "$WORK/key.pem" -out "$WORK/cert.pem" \
  -config "$WORK/openssl.cnf" 2>/dev/null

echo "打包成 p12 并导入钥匙串…"
# 必须用「老算法」打包：OpenSSL 3/4 默认的 AES-256 + PBKDF2-SHA256 macOS 的
# SecKeychainItemImport 读不了，会报 "MAC verification failed during PKCS12 import"。
# PBE-SHA1-3DES + SHA1 MAC 是它认识的那一套。
openssl pkcs12 -export \
  -inkey "$WORK/key.pem" -in "$WORK/cert.pem" \
  -name "$IDENTITY_NAME" -out "$WORK/identity.p12" \
  -passout "pass:$P12_PASSWORD" \
  -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES -macalg sha1 2>/dev/null

# -A：允许任意程序使用私钥（免去每次签名时弹「codesign 想要访问密钥」）；
# -T：额外显式授权 codesign / security，双重保险。
security import "$WORK/identity.p12" \
  -k "$KEYCHAIN" -P "$P12_PASSWORD" \
  -T /usr/bin/codesign -T /usr/bin/security -A >/dev/null

if ! exists; then
  echo "导入失败：钥匙串里没有出现可用的代码签名身份。" >&2
  echo "可以手动检查：security find-identity -v -p codesigning" >&2
  exit 1
fi

echo
echo "创建成功："
security find-identity -p codesigning | grep "\"$IDENTITY_NAME\""
echo "（CSSMERR_TP_NOT_TRUSTED 是自签证书的正常状态：签名与 codesign -v 都不需要系统信任。）"
cat <<'NOTE'

接下来：
  1. 重新安装一次，让 App 用新身份签名：
       ./scripts/install.sh Release
     （install.sh 会自动优先使用「MacTools Dev」，不需要额外传参）
  2. 因为签名变了，这次仍需重新授权：辅助功能 + 屏幕录制，然后退出重开。
  3. 之后只要不再重建证书，重新构建、重装都不会再让授权失效。
NOTE
