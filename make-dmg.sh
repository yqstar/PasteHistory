#!/bin/bash
# 把已编译好的 PasteHistory.app 打包成可分发的 .dmg。
# 用法： bash make-dmg.sh
# 若 build/PasteHistory.app 不存在，会先调用 build.sh 编译。
set -e

DIR="$(cd "$(dirname "$0")" && pwd)"
APP="$DIR/build/PasteHistory.app"
DMG="$DIR/build/PasteHistory.dmg"
VOL="粘贴历史"

if [ ! -d "$APP" ]; then
    echo "==> 未发现 $APP，先编译"
    bash "$DIR/build.sh"
fi

echo "==> 准备临时打包目录"
STAGE="$(mktemp -d -t pastehistory-dmg)"
trap 'rm -rf "$STAGE"' EXIT
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"

echo "==> 清理旧 DMG"
rm -f "$DMG"

echo "==> 生成 DMG"
hdiutil create \
    -volname "$VOL" \
    -srcfolder "$STAGE" \
    -ov \
    -format UDZO \
    "$DMG" >/dev/null

SIZE="$(du -h "$DMG" | cut -f1)"
echo "==> 完成: $DMG ($SIZE)"
echo "    双击挂载后将 PasteHistory.app 拖进 Applications 即可。"
