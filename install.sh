#!/bin/bash
# shot-table 一键安装：编译 OCR（如需）→ 接管 Hammerspoon 配置 → 启动
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
echo "==> shot-table 安装目录: $ROOT"

# 1. Hammerspoon 检查 / 安装
if [ ! -d "/Applications/Hammerspoon.app" ] && [ ! -d "$HOME/Applications/Hammerspoon.app" ]; then
  echo "==> 未检测到 Hammerspoon，尝试用 Homebrew 安装..."
  if command -v brew >/dev/null 2>&1; then
    brew install --cask hammerspoon
  else
    echo "!! 未安装 Homebrew。请手动下载 Hammerspoon: https://www.hammerspoon.org/" >&2
    exit 1
  fi
else
  echo "==> Hammerspoon 已安装 ✓"
fi

# 2. OCR 二进制：架构不匹配或缺clang时现场编译
if ! "$ROOT/scripts/ocr" text /dev/null >/dev/null 2>&1; then
  echo "==> 自带二进制不可用，正在为本机编译 OCR（需要 Xcode Command Line Tools）..."
  if ! command -v swiftc >/dev/null 2>&1; then
    echo "!! 未找到 swiftc。请先运行: xcode-select --install" >&2
    exit 1
  fi
  (cd "$ROOT/scripts" && swiftc -O -o ocr ocr.swift)
  echo "==> 编译完成 ✓"
else
  echo "==> OCR 二进制可用 ✓"
fi

# 3. 让 Hammerspoon 加载本仓库的 init.lua
defaults write org.hammerspoon.Hammerspoon MJConfigFile -string "$ROOT/hammerspoon/init.lua"
echo "==> 已将 Hammerspoon 配置指向本仓库 ✓"

# 4. 启动 / 重载
open -a Hammerspoon 2>/dev/null || true
sleep 2
osascript -e 'tell application "Hammerspoon" to execute lua code "hs.reload()"' >/dev/null 2>&1 || true

cat <<'TIP'

==============================================================
 安装完成！首次使用还需要授权两项权限（各一次）：

 1. 屏幕录制：系统设置 → 隐私与安全性 → 屏幕录制 → 勾选 Hammerspoon
    （Cmd+Alt+4 选区截图需要）
 2. 辅助功能：系统设置 → 隐私与安全性 → 辅助功能 → 勾选 Hammerspoon
    （模拟 Cmd+V 粘贴需要）

 授权后若不生效，点菜单栏锤子图标 → Reload Config。

 用法：
   Cmd+Alt+4  选区截图（进剪贴板，不弹窗）
   Cmd+Alt+V  弹出面板：表格 / 文字 / 原图，选完自动粘贴
   普通 Cmd+V 完全不受影响
==============================================================
TIP
