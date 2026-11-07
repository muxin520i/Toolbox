#!/usr/bin/env bash
# 在 macOS 上一条命令生成未签名的 .ipa
# 用法：./tools/build-ipa.sh
set -euo pipefail

cd "$(dirname "$0")/.."

SCHEME="VideoLinker"
PROJECT="VideoLinker.xcodeproj"
BUILD_DIR="build"
OUT="VideoLinker-unsigned.ipa"

if ! command -v xcodebuild >/dev/null 2>&1; then
  echo "找不到 xcodebuild。这个脚本必须在装了 Xcode 的 macOS 上运行。"
  exit 1
fi

echo "==> 清理旧产物"
rm -rf "$BUILD_DIR/Payload" "$BUILD_DIR/$OUT"

echo "==> 编译 Release（跳过签名）"
xcodebuild \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -configuration Release \
  -sdk iphoneos \
  -derivedDataPath "$BUILD_DIR" \
  CODE_SIGN_IDENTITY="" \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGNING_ALLOWED=NO \
  OTHER_CFLAGS="$(inherited) -DHAVE_TIME_H=1 -DHAVE_STDINT_H=1 -DHAVE_SYS_TYPES_H=1" \
  build

APP_PATH="$BUILD_DIR/Build/Products/Release-iphoneos/$SCHEME.app"
if [ ! -d "$APP_PATH" ]; then
  echo "编译产物不存在：$APP_PATH"
  exit 1
fi

echo "==> 打包 ipa"
mkdir -p "$BUILD_DIR/Payload"
cp -R "$APP_PATH" "$BUILD_DIR/Payload/"
( cd "$BUILD_DIR" && zip -qry "$OUT" Payload )
rm -rf "$BUILD_DIR/Payload"

SIZE=$(du -h "$BUILD_DIR/$OUT" | cut -f1)
echo "==> 完成：$(pwd)/$BUILD_DIR/$OUT（$SIZE）"
echo "    这个包未签名，需要 Sideloadly / AltStore 用你自己的 Apple ID 签名后安装。"
