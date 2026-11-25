#!/usr/bin/env bash
#
# 在 macOS 上产出一个未签名 IPA：build/out/SuperKill-unsigned.ipa
#
#   用法：
#     ./scripts/build_ipa.sh                 # xcodegen 生成工程 + 编译 + 打包
#     ./scripts/build_ipa.sh --skip-build    # 只用已有产物打包
#
#   环境变量：
#     APP_GROUP   你的 App Group identifier（写进 Info.plist 的 SKAppGroup）
#     BUNDLE_ID   你的 bundle id
#
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

APP_GROUP="${APP_GROUP:-group.cc.replace.superkill}"
BUNDLE_ID="${BUNDLE_ID:-cc.replace.superkill}"
APP_NAME="${APP_NAME:-Koznak}"

BUILD_DIR="$ROOT/build"
APP_DIR="$BUILD_DIR/app"
OUT="$BUILD_DIR/out"
APP="$APP_DIR/SuperKill.app"

if [[ "${1:-}" != "--skip-build" ]]; then
  if ! command -v xcodegen >/dev/null 2>&1; then
    echo "[!] 需要 xcodegen：brew install xcodegen"
    exit 1
  fi

  xcodegen generate --spec project.yml

  # -target + CONFIGURATION_BUILD_DIR：不依赖 scheme / derived data 布局，产物路径确定
  xcodebuild -project SuperKill.xcodeproj \
             -target SuperKill \
             -configuration Release \
             -sdk iphoneos \
             CONFIGURATION_BUILD_DIR="$APP_DIR" \
             PRODUCT_BUNDLE_IDENTIFIER="$BUNDLE_ID" \
             SK_APP_GROUP="$APP_GROUP" \
             CODE_SIGNING_ALLOWED=NO \
             CODE_SIGNING_REQUIRED=NO \
             CODE_SIGN_IDENTITY="" \
             build
fi

if [[ ! -d "$APP" ]]; then
  echo "[!] 找不到构建产物：$APP"
  echo "    当前 build 目录内容："
  find "$BUILD_DIR" -maxdepth 4 -name "*.app" -print 2>/dev/null || true
  exit 1
fi

rm -rf "$OUT"
mkdir -p "$OUT/Payload"
cp -R "$APP" "$OUT/Payload/SuperKill.app"

# 图标：显式拷进 bundle 根目录，不依赖 Xcode 的资源阶段
cp "$ROOT"/Resources/AppIcon60x60@2x.png "$ROOT"/Resources/AppIcon60x60@3x.png \
   "$ROOT"/Resources/AppIcon76x76.png "$ROOT"/Resources/AppIcon76x76@2x.png \
   "$OUT/Payload/SuperKill.app/" 2>/dev/null || true

# 附加资源（20MB 内置数据文件，不影响功能）
cp "$ROOT"/Resources/core_assets.bin "$OUT/Payload/SuperKill.app/" 2>/dev/null || true

# 未签名构建不写 entitlements，至少保证运行期能读到 App Group 字符串
/usr/libexec/PlistBuddy -c "Set :SKAppGroup $APP_GROUP" "$OUT/Payload/SuperKill.app/Info.plist" >/dev/null 2>&1 || true

# 桌面显示名（改名字只需要改 APP_NAME 环境变量，不用动工程）
/usr/libexec/PlistBuddy -c "Set :CFBundleDisplayName $APP_NAME" "$OUT/Payload/SuperKill.app/Info.plist" >/dev/null 2>&1 || true

(cd "$OUT" && zip -qry "SuperKill-unsigned.ipa" Payload)

echo "[+] 产物：$OUT/SuperKill-unsigned.ipa"
echo "[+] bundle id：$BUNDLE_ID   App Group：$APP_GROUP"
echo "[*] 下一步：用你的证书 + 带该 App Group 的描述文件重签（scripts/sign_local.sh / Sideloadly / ESign）"
