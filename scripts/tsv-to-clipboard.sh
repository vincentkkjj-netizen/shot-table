#!/bin/bash
# 把 TSV 内容以【双格式】写入剪贴板：
#   - public.utf8-plain-text = TSV（粘到 Excel/飞书表格/Numbers，按单元格拆分）
#   - public.html = HTML <table>（粘到学城/飞书文档/微信等富文本编辑器，直接变真表格）
# 用法: tsv-to-clipboard.sh <tsv文件路径>
#       cat xxx.tsv | tsv-to-clipboard.sh
set -euo pipefail
export LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8

SKILL_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TSV_FILE="${1:-/dev/stdin}"
if [ ! -f "$TSV_FILE" ] && [ "$TSV_FILE" != "/dev/stdin" ]; then
  echo "ERROR: 文件不存在: $TSV_FILE" >&2
  exit 2
fi
# /dev/stdin 时先落到临时文件，JXA 读不到管道
TMP_TSV="$SKILL_DIR/tmp/.clipboard-in.tsv"
if [ "$TSV_FILE" = "/dev/stdin" ]; then
  cat > "$TMP_TSV"
  TSV_FILE="$TMP_TSV"
fi

# 生成 HTML 表格（转义 &<>，制表符→单元格，换行→行；空表头单元格保留为空）
HTML_FILE="$SKILL_DIR/tmp/.clipboard-in.html"
python3 - "$TSV_FILE" > "$HTML_FILE" <<'PYEOF'
import sys, html
lines = open(sys.argv[1], encoding="utf-8").read().rstrip("\n").split("\n")
rows = [line.split("\t") for line in lines if line.strip()]
print("<meta charset='utf-8'><table border='1' cellspacing='0' cellpadding='4'>")
for i, row in enumerate(rows):
    tag = "th" if i == 0 else "td"
    cells = "".join(f"<{tag}>{html.escape(c)}</{tag}>" for c in row)
    print(f"<tr>{cells}</tr>")
print("</table>")
PYEOF

# 双格式写入剪贴板
RESULT="$(osascript -l JavaScript - "$TSV_FILE" "$HTML_FILE" <<'EOF'
ObjC.import("AppKit");
ObjC.import("Foundation");
function run(argv) {
  const pb = $.NSPasteboard.generalPasteboard;
  const tsvData = $.NSData.dataWithContentsOfFile(argv[0]);
  const htmlData = $.NSData.dataWithContentsOfFile(argv[1]);
  if (!tsvData || tsvData.length === 0) return "FAIL:TSV为空";
  pb.clearContents;
  const r1 = pb.setDataForType(tsvData, "public.utf8-plain-text");
  let r2 = false;
  if (htmlData && htmlData.length > 0) {
    r2 = pb.setDataForType(htmlData, "public.html");
  }
  return (r1 && r2) ? "OK" : "FAIL:html=" + r2;
}
EOF
)" || true

rm -f "$TMP_TSV" "$HTML_FILE"

if [ "$RESULT" != "OK" ]; then
  echo "ERROR: 写入剪贴板失败 ($RESULT)" >&2
  exit 3
fi
echo "OK: 表格已进剪贴板（TSV + HTML 双格式，Excel/学城/飞书都能粘成表格）"
