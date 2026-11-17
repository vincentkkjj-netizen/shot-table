#!/bin/bash
# 把剪贴板中的图片存为 PNG 并打印文件路径（stdout）。零依赖，仅用 macOS 自带工具。
# 用法: clipboard-image.sh [输出路径]
#   不带参数时输出到本 skill 的 tmp/ 目录，文件名带时间戳。
# 退出码: 0=成功; 1=剪贴板里没有图片; 2=保存失败
set -euo pipefail

SKILL_DIR="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${1:-$SKILL_DIR/tmp/clipboard-$(date +%Y%m%d-%H%M%S).png}"
mkdir -p "$(dirname "$OUT")"

RESULT="$(osascript -l JavaScript - "$OUT" <<'EOF'
ObjC.import("AppKit");
ObjC.import("Foundation");
function run(argv) {
  const out = argv[0];
  const pb = $.NSPasteboard.generalPasteboard;
  const types = ObjC.deepUnwrap(pb.types) || [];
  function save(type, path) {
    const data = pb.dataForType(type);
    if (!data || data.length === 0) return false;
    return data.writeToFileAtomically(path, true);
  }
  if (types.indexOf("public.tiff") !== -1 && save("public.tiff", out + ".tmp.tiff")) {
    return "TIFF";
  }
  if (types.indexOf("public.png") !== -1 && save("public.png", out)) {
    return "PNG";
  }
  if (types.indexOf("public.file-url") !== -1) {
    const data = pb.dataForType("public.file-url");
    const url = ObjC.unwrap($.NSString.alloc.initWithDataEncoding(data, 4)); // 4 = NSUTF8
    return "FILEURL:" + url;
  }
  return "NO_IMAGE";
}
EOF
)" || true

case "$RESULT" in
  TIFF)
    sips -s format png "$OUT.tmp.tiff" --out "$OUT" >/dev/null 2>&1
    rm -f "$OUT.tmp.tiff"
    [ -f "$OUT" ] && { echo "$OUT"; exit 0; }
    echo "ERROR: TIFF 转 PNG 失败" >&2; exit 2
    ;;
  PNG)
    [ -f "$OUT" ] && { echo "$OUT"; exit 0; }
    echo "ERROR: 图片保存失败" >&2; exit 2
    ;;
  FILEURL:*)
    SRC_PATH="${RESULT#FILEURL:file://}"
    SRC_PATH="$(python3 -c "import sys,urllib.parse;print(urllib.parse.unquote(sys.argv[1]))" "$SRC_PATH" 2>/dev/null || echo "$SRC_PATH")"
    if [ ! -f "$SRC_PATH" ]; then
      echo "ERROR: 剪贴板里的文件路径不存在: $SRC_PATH" >&2; exit 2
    fi
    echo "$SRC_PATH"
    exit 0
    ;;
  *)
    echo "ERROR: 剪贴板里没有图片。请先截图到剪贴板（Cmd+Shift+Ctrl+4）再试" >&2
    exit 1
    ;;
esac
