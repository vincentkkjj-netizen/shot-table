# shot-table 📸→📋

**截图里的表格，一键变成可编辑的文本表格，直接贴进任何 App。**

按下 `Cmd+Alt+4` 框选表格 → `Cmd+Alt+V` 选「表格」→ 约 1 秒后，表格已经贴在你光标所在的输入框里了。全程本机处理，不上传任何数据。

![demo](docs/demo.gif) <!-- TODO: 补一张演示动图 -->

## 功能

| 快捷键 | 行为 |
|---|---|
| `Cmd+Alt+4` | 选区截图 → 自动进剪贴板（不弹窗） |
| `Cmd+Alt+V` | 弹出面板三选一：📄 表格 / 📝 文字 / 🖼 原图 → 选完自动粘贴 |
| 普通 `Cmd+V` | 完全不受影响 |

- **表格**：还原行列结构，以 TSV + HTML 双格式进剪贴板——贴 Excel/Numbers 按单元格拆分，贴飞书文档/语雀/Notion 等富文本编辑器直接变真表格
- **文字**：提取全部文字
- **原图**：什么都不做，直接贴截图
- 识别在**本机**完成（Apple Vision 框架），无网络依赖、无隐私外泄

## 安装

```bash
git clone https://github.com/<你>/shot-table.git
cd shot-table
./install.sh
```

`install.sh` 会自动：检测/安装 Hammerspoon → 按需编译 OCR 二进制（Apple Silicon 二进制已内置）→ 接管 Hammerspoon 配置 → 引导授权。

> 首次使用需在「系统设置 → 隐私与安全性」里给 Hammerspoon 授权 **屏幕录制** 和 **辅助功能**（各一次，安装脚本结束时会提示路径）。

### 卸载

```bash
defaults delete org.hammerspoon.Hammerspoon MJConfigFile   # 恢复 Hammerspoon 默认配置
```

## 它是怎么工作的

```
Cmd+Alt+4   screencapture 选区截图进剪贴板
Cmd+Alt+V   Hammerspoon 弹出面板，同时后台并行预跑 OCR
表格分支     ① 灰度像素按行/列投影切出单元格网格
            ② 逐格裁剪 + Vision 识别（多核并发）
            ③ 千分位逗号被切列的自动合并修复
            ④ TSV + HTML <table> 双格式写入剪贴板
粘贴        重新聚焦目标窗口 → 合成 Cmd+V
```

**为什么要"先切格再逐格识别"？** 直接让 OCR 识别整张表，它会把挤在一起的行合并成一坨文本、还会擅自重排 `1,234` 里的逗号，且无法从结果恢复。按空隙像素投影切出网格后逐格识别，从源头绕开这两个问题。

## 已知限制（快速 OCR 版的边界）

- 被遮挡/贴边的单元格、手写字、跨行合并单元格会识别错或漏
- 靠边界的列偶尔被切偏（已对千分位做了自动合并兜底）
- **数字建议抽查**——这是为了速度牺牲精度的本机快速版

需要 100% 精确（会标出不确定的格子）时，把截图贴给 AI 助手（如 CatPaw）做视觉识别即可，两者互补。

## 依赖

- macOS 11+（Vision 中文字识别需 macOS 10.15+，zh-Hans 建议 12+）
- [Hammerspoon](https://www.hammerspoon.org/)（MIT 开源）
- Xcode Command Line Tools（仅当自带二进制不可用需要现场编译时）

## License

MIT
