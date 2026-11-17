// 截图表格/文字 OCR（macOS 自带 Vision，零外部依赖）
// 用法:
//   ocr text  <图片路径>            输出全部文字（阅读顺序）
//   ocr table <图片路径>            重建表格网格，输出 TSV
// 编译: swiftc -O -o ocr ocr.swift   （未编译时也可 swift ocr.swift 运行，慢 1-2 秒）
import Foundation
import Vision
import AppKit

// ---------- 数字归一化：千分位被 OCR 成 . 或混用时修成 ','；小数/百分数不动 ----------
func normNum(_ s: String) -> String {
    var t = s.replacingOccurrences(of: " ", with: "")
    // 箭头被 OCR 成汉字：末尾的 个/J/小/以 → ↑/↓（仅当前面是数字/百分号时）
    let arrowMap = ["个": "↑", "J": "↓", "小": "↓", "以": "↓"]
    if let last = t.last, let arrow = arrowMap[String(last)],
       t.dropLast().contains(where: { $0.isNumber || $0 == "%" }) {
        t = String(t.dropLast()) + arrow
    }
    let full = "^-?\\d{1,3}([.,]\\d{3})+$"
    let withDec = "^-?\\d{1,3}([.,]\\d{3})+[.,]\\d{1,2}$"
    if t.range(of: full, options: .regularExpression) != nil {
        return t.replacingOccurrences(of: "[.,]", with: ",", options: .regularExpression)
    }
    if t.range(of: withDec, options: .regularExpression) != nil {
        let re = try! NSRegularExpression(pattern: "^(-?\\d{1,3}(?:[.,]\\d{3})+)([.,])(\\d{1,2})$")
        if let m = re.firstMatch(in: t, range: NSRange(t.startIndex..., in: t)) {
            let g1 = String(t[Range(m.range(at: 1), in: t)!])
            let g3 = String(t[Range(m.range(at: 3), in: t)!])
            return g1.replacingOccurrences(of: "[.,]", with: ",", options: .regularExpression) + "." + g3
        }
    }
    return t // 含箭头修正结果；纯文本格不受影响（t 只在开头去空格）
}

struct Cell {
    let text: String
    let cx: Double, cy: Double, w: Double, h: Double
}

// ---------- 拆分被 Vision 粘连的单元格 ----------
// 窄列表格中 Vision 常把整行粘成一条观察（如 "DAU14,135,74313,593,187"）。
// 用数字语法（千分位/日期/百分数）可确定性拆开；按字符宽度比例估算各 token 的 x 位置。
private func matchAt(_ s: Substring, _ pattern: String) -> Range<String.Index>? {
    s.range(of: pattern, options: [.regularExpression, .anchored])
}

func tokenize(_ s: String) -> [(text: String, numeric: Bool)] {
    var tokens: [(text: String, numeric: Bool)] = []
    var buf = ""
    var i = s.startIndex
    while i < s.endIndex {
        let sub = s[i...]
        var matched: Range<String.Index>? = nil
        for p in ["^\\d{4}-\\d{2}",                              // 日期 2026-01
                  "^-?\\d+(\\.\\d+)?%(pp)?",                     // 百分数 22.63% / 0.26pp
                  "^-?\\d{1,3}(,\\d{3})+(\\.\\d{1,2})?",         // 千分位 14,135,743 / 1,258.40
                  "^-?\\d+\\.\\d+",                              // 普通小数 20.67
                  "^\\d{1,4}"] {                                  // 短整数 2026 / 881
            if let r = matchAt(sub, p) { matched = r; break }
        }
        if let r = matched {
            if !buf.isEmpty { tokens.append((buf, false)); buf = "" }
            tokens.append((String(s[i..<r.upperBound]), true))
            i = r.upperBound
        } else {
            if s[i].isWhitespace {
                if !buf.isEmpty { tokens.append((buf, false)); buf = "" }
            } else {
                buf.append(s[i])
            }
            i = s.index(after: i)
        }
    }
    if !buf.isEmpty { tokens.append((buf, false)) }
    // 合并相邻的非数字 token（如 "次" + "日复访率"）
    var merged: [(text: String, numeric: Bool)] = []
    for t in tokens {
        if !t.numeric, let last = merged.last, !last.numeric {
            merged[merged.count - 1].0 += t.0
        } else { merged.append(t) }
    }
    return merged
}

func charWeight(_ s: String) -> Double {
    var w = 0.0
    for ch in s.unicodeScalars { w += ch.value >= 0x2E80 ? 2 : 1 } // CJK 约占 2 倍宽
    return max(w, 1)
}

func expandCell(_ c: Cell) -> [Cell] {
    let tokens = tokenize(c.text)
    guard tokens.count >= 2, tokens.dropFirst().allSatisfy({ $0.numeric }) else { return [c] }
    let total = tokens.reduce(0.0) { $0 + charWeight($1.text) }
    var out: [Cell] = []
    var x = c.cx - c.w / 2
    for t in tokens {
        let w = c.w * charWeight(t.text) / total
        out.append(Cell(text: t.text, cx: x + w / 2, cy: c.cy, w: w, h: c.h))
        x += w
    }
    return out
}

func loadImage(_ path: String) -> CGImage? {
    guard let img = NSImage(contentsOfFile: path),
          let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
    return cg
}

// ---------- 投影法表格提取：先找行列边界，再逐格裁剪 OCR（根治整行粘连） ----------
func pixelGray(_ cg: CGImage) -> [UInt8] {
    let w = cg.width, h = cg.height
    var data = [UInt8](repeating: 255, count: w * h)
    data.withUnsafeMutableBytes { ptr in
        guard let ctx = CGContext(data: ptr.baseAddress, width: w, height: h,
                                  bitsPerComponent: 8, bytesPerRow: w,
                                  space: CGColorSpaceCreateDeviceGray(),
                                  bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
    }
    return data
}


// 修掉千分位被切列：末格以逗号结尾且下一格是 1~3 位纯数字 → 合并（并左移补位）
func isShortDigit(_ s: String) -> Bool {
    let t = s.trimmingCharacters(in: .whitespaces)
    return !t.isEmpty && t.count <= 3 && t.allSatisfy { $0.isNumber }
}

func mergeSplitThousands(_ grid: [[String]]) -> [[String]] {
    return grid.map { row in
        var r = row
        var i = 0
        while i < r.count - 1 {
            let cur = r[i]
            if let last = cur.last, (last == "," || last == "，"),
               cur.contains(where: { $0.isNumber }), isShortDigit(r[i + 1]) {
                r[i] = String(cur.dropLast()) + "," + r[i + 1].trimmingCharacters(in: .whitespaces)
                r.remove(at: i + 1)
                r.append("")
            }
            i += 1
        }
        return r
    }
}

func projectionTable(_ cg: CGImage) -> [[String]]? {
    let w = cg.width, h = cg.height
    let px = pixelGray(cg)
    let darkThresh: UInt8 = 140   // 深色文字；浅灰水印/网格线被排除
    var colDark = [Int](repeating: 0, count: w)
    var rowDark = [Int](repeating: 0, count: h)
    for y in 0..<h {
        let base = y * w
        for x in 0..<w where px[base + x] < darkThresh {
            colDark[x] += 1; rowDark[y] += 1
        }
    }
    // 文本行带（连续暗行区间）
    var bands: [(s: Int, e: Int)] = []
    var y = 0
    while y < h {
        if rowDark[y] >= 2 {
            var e = y
            while e + 1 < h && rowDark[e + 1] >= 2 { e += 1 }
            bands.append((y, e)); y = e + 1
        } else { y += 1 }
    }
    // 行带去噪：高度≥8 的才是文字行（1-2px 的是网格线）；相邻带间隙<5px 合并
    var textBands: [(s: Int, e: Int)] = []
    for b in bands where b.e - b.s >= 8 {
        if let last = textBands.last, b.s - last.e < 5 { textBands[textBands.count - 1].e = b.e }
        else { textBands.append(b) }
    }
    // 列段（连续暗列区间），间隙≥14px 才算分列
    var cols: [(s: Int, e: Int)] = []
    var x = 0
    while x < w {
        if colDark[x] > 0 {
            var e = x
            while e + 1 < w && colDark[e + 1] > 0 { e += 1 }
            cols.append((x, e)); x = e + 1
        } else { x += 1 }
    }
    // 自适应列间距阈值：阈值取中位间隙的一半（字符间隙远小于列边界间隙）
    var gaps: [Int] = []
    for i in 1..<cols.count { gaps.append(cols[i].s - cols[i - 1].e) }
    var gapMin = Int.max
    if !gaps.isEmpty {
        let sg = gaps.sorted()
        let medG = sg[sg.count / 2]
        let maxG = sg.last!
        if maxG >= 8 { gapMin = max(5, medG / 2) }
        if ProcessInfo.processInfo.environment["OCR_DEBUG"] == "1" {
            fputs("[debug] 原始列段=\(cols.count) gaps=\(gaps) med=\(medG) max=\(maxG) gapMin=\(gapMin) bands=\(textBands.count)\n", stderr)
        }
    }
    if gapMin == Int.max { return nil } // 没有清晰的列结构 → 退回聚类路径
    var colSegs: [(s: Int, e: Int)] = []
    for c in cols {
        if let last = colSegs.last, c.s - last.e < gapMin { colSegs[colSegs.count - 1].e = c.e }
        else { colSegs.append(c) }
    }
    colSegs = colSegs.filter { $0.e - $0.s >= 2 } // 去除窄噪声列
    guard textBands.count >= 1, colSegs.count >= 2, colSegs.count <= 60 else { return nil }

    // 逐格裁剪 OCR（并发跑：每格一个 Vision 请求，用满多核）
    let nR = textBands.count, nC = colSegs.count
    var flat = [String](repeating: "", count: nR * nC)
    flat.withUnsafeMutableBufferPointer { buf in
        DispatchQueue.concurrentPerform(iterations: nR * nC) { k in
            autoreleasepool {
                let b = textBands[k / nC], c = colSegs[k % nC]
                let x0 = max(0, c.s - 4), x1 = min(w, c.e + 4)
                let y0 = max(0, b.s - 3), y1 = min(h, b.e + 3)
                var hasDark = false
                scan: for yy in y0..<y1 {
                    let base = yy * w
                    for xx in x0..<x1 where px[base + xx] < darkThresh { hasDark = true; break scan }
                }
                guard hasDark,
                      let crop = cg.cropping(to: CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0))
                else { return }
                let texts = recognize(crop).map { $0.text.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                if !texts.isEmpty { buf[k] = normNum(texts.joined(separator: " ")) }
            }
        }
    }
    let grid = mergeSplitThousands((0..<nR).map { ri in Array(flat[(ri * nC)..<((ri + 1) * nC)]) })
    // 至少一半的格子有内容才算有效
    let filled = grid.flatMap { $0 }.filter { !$0.isEmpty }.count
    return filled >= grid.count * colSegs.count / 2 ? grid : nil
}

func recognize(_ cg: CGImage) -> [(text: String, box: CGRect)] {
    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .accurate
    request.usesLanguageCorrection = false
    request.recognitionLanguages = ["zh-Hans", "en-US"]
    let handler = VNImageRequestHandler(cgImage: cg, options: [:])
    try? handler.perform([request])
    var out: [(String, CGRect)] = []
    for obs in request.results ?? [] {
        if let t = obs.topCandidates(1).first?.string, !t.trimmingCharacters(in: .whitespaces).isEmpty {
            out.append((t, obs.boundingBox))
        }
    }
    return out
}

let args = CommandLine.arguments
guard args.count >= 3, ["text", "table"].contains(args[1]),
      let cg = loadImage(args[2]) else {
    fputs("用法: ocr text|table <图片路径>\n", stderr); exit(2)
}
let W = Double(cg.width), H = Double(cg.height)

if args[1] == "text" {
    let observations = recognize(cg)
    // 按阅读顺序：先按 y 聚成行，行内按 x 排序
    var cells: [Cell] = observations.map {
        let x = $0.box.origin.x * W, yTop = (1 - $0.box.origin.y - $0.box.height) * H
        return Cell(text: $0.text.trimmingCharacters(in: .whitespaces),
                    cx: x + $0.box.width * W / 2, cy: yTop + $0.box.height * H / 2,
                    w: $0.box.width * W, h: $0.box.height * H)
    }
    cells.sort { $0.cy < $1.cy }
    var lines: [String] = [], cur: [Cell] = []
    var lastCy = -Double.greatestFiniteMagnitude
    let medH = cells.map(\.h).sorted()[mid(cells.count)]
    for c in cells {
        if c.cy - lastCy > medH * 0.6 && !cur.isEmpty { lines.append(lineText(cur)); cur = [] }
        cur.append(c); lastCy = c.cy
    }
    if !cur.isEmpty { lines.append(lineText(cur)) }
    print(lines.joined(separator: "\n"))
} else {
    // 优先投影法（逐格 OCR，数字保真）；失败则退回观察点聚类 + 粘连切分
    if let grid = projectionTable(cg), !grid.isEmpty {
        print(grid.map { $0.joined(separator: "\t") }.joined(separator: "\n"))
        exit(0)
    }
    let observations = recognize(cg)
    let rawCells: [Cell] = observations.map {
        let x = $0.box.origin.x * W, yTop = (1 - $0.box.origin.y - $0.box.height) * H
        return Cell(text: $0.text.trimmingCharacters(in: .whitespaces),
                    cx: x + $0.box.width * W / 2, cy: yTop + $0.box.height * H / 2,
                    w: $0.box.width * W, h: $0.box.height * H)
    }
    // 粘连单元格切分（窄列表格整行粘成一条观察的情况）
    let cells = rawCells.flatMap(expandCell)
    guard !cells.isEmpty else { print("ERROR: 图里没有识别到文字"); exit(1) }
    let medH = cells.map(\.h).sorted()[cells.count / 2]
    let medW = cells.map(\.w).sorted()[cells.count / 2]

    // 行聚类
    let byY = cells.sorted { $0.cy < $1.cy }
    var rows: [[Cell]] = []
    var cur: [Cell] = []
    var lastCy = -Double.greatestFiniteMagnitude
    for c in byY {
        if c.cy - lastCy > medH * 0.6 && !cur.isEmpty { rows.append(cur); cur = [] }
        cur.append(c); lastCy = c.cy
    }
    if !cur.isEmpty { rows.append(cur) }

    // 列聚类：所有格中心 x，间距超阈值则新列
    let centers = cells.map(\.cx).sorted()
    var colClusters: [Double] = [centers[0]]
    let colThresh = max(medW * 1.6, 25)
    for cx in centers.dropFirst() {
        if cx - colClusters.last! > colThresh { colClusters.append(cx) }
        else { colClusters[colClusters.count - 1] = (colClusters.last! + cx) / 2 }
    }
    func nearestCol(_ cx: Double) -> Int {
        var best = 0, bd = Double.greatestFiniteMagnitude
        for (j, cc) in colClusters.enumerated() where abs(cx - cc) < bd { bd = abs(cx - cc); best = j }
        return best
    }

    // 填网格（同格多条结果按 x 顺序拼接）
    var grid: [[String]] = []
    for r in rows {
        var line = [String](repeating: "", count: colClusters.count)
        for c in r.sorted(by: { $0.cx < $1.cx }) {
            let j = nearestCol(c.cx)
            line[j] = line[j].isEmpty ? c.text : line[j] + " " + c.text
        }
        grid.append(line.map(normNum))
    }
    // 去杂行：非空格全是"无数字且长度≤1"的碎屑（如选中框被误认成的"田"）
    let cleaned = grid.filter { row in
        let meaningful = row.filter { !$0.isEmpty }
        if meaningful.isEmpty { return true }
        return !meaningful.allSatisfy { $0.count <= 1 && !$0.contains(where: { $0.isNumber }) }
    }
    print(cleaned.map { $0.joined(separator: "\t") }.joined(separator: "\n"))
}

func lineText(_ cur: [Cell]) -> String {
    cur.sorted { $0.cx < $1.cx }.map(\.text).joined(separator: " ")
}

func mid(_ n: Int) -> Int { n / 2 }
