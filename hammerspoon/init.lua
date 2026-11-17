-- img-table-ocr 截图粘贴助手
-- Cmd+Alt+4 = 选区截图 → 鼠标旁选「表格 / 文字 / 原图」→ 自动粘贴
-- Cmd+Alt+V = 处理剪贴板里已有的截图（普通 Cmd+V 完全不受影响）
-- 表格/文字用 macOS 自带 Vision OCR（快速版；要精确结果去 CatPaw 说"转成表格"）

-- 路径全部相对本配置文件，clone 到任意位置都能用
local BASE = (debug.getinfo(1, "S").source:sub(2):match("(.*/)") or "./") -- .../hammerspoon/
local SKILL = (BASE:gsub("hammerspoon/$", "")) -- 仓库根目录（带尾斜杠）
local TMP = SKILL .. "tmp"
pcall(function() hs.fs.mkdir(TMP) end)

hs.allowAppleScript(true) -- 允许外部 osascript 触发 hs.reload()

local function trim(s) return s and s:gsub("^%s*(.-)%s*$", "%1") or "" end

local function notify(title, text)
    hs.notify.new({ title = title, informativeText = text, withdrawAfter = 5 }):send()
end

local timers = {} -- 持有 timer 引用，防止被 GC 回收
local tasks = {}  -- 持有 hs.task 引用，同上

local function later(delay, fn)
    table.insert(timers, hs.timer.doAfter(delay, fn))
end

-- 面板期间记录的目标窗口：粘贴前重新聚焦，解决学城/浏览器里贴不进去
local target = { app = nil, win = nil }

local function rememberTarget()
    target.app = hs.application.frontmostApplication()
    target.win = hs.window.focusedWindow()
end

local function pasteFrontmost()
    later(0.15, function()
        pcall(function()
            if target.win and target.win:isVisible() then target.win:focus() end
        end)
        pcall(function()
            if target.app and not target.app:isFrontmost() then target.app:activate() end
        end)
        later(0.2, function()
            hs.eventtap.keyStroke({ "cmd" }, "v")
        end)
    end)
end

-- ---------- 后台预识别：面板一弹出就开跑，用户点选时结果通常已就绪 ----------
local pre = { img = nil, tableDone = false, textDone = false, tableOut = nil, textOut = nil }

local function startPrefetch(imgPath)
    pre = { img = imgPath, tableDone = false, textDone = false, tableOut = nil, textOut = nil }
    local function run(mode)
        local t = hs.task.new(SKILL .. "/scripts/ocr", function(code, out)
            if mode == "table" then
                if code == 0 and out and trim(out) ~= "" then pre.tableOut = out end
                pre.tableDone = true
            else
                if code == 0 and out and trim(out) ~= "" then pre.textOut = out end
                pre.textDone = true
            end
        end, { mode, imgPath })
        table.insert(tasks, t)
        t:start()
    end
    run("table")
    run("text")
end

local function waitPrefetch(flag, deadline, cb)
    local waited = 0
    local function check()
        if pre[flag] or waited >= deadline then return cb(pre[flag]) end
        waited = waited + 0.1
        later(0.1, check)
    end
    check()
end

local function writeFile(path, content)
    local f = io.open(path, "w")
    if not f then return false end
    f:write(content); f:close()
    return true
end

-- ---------- 选择后的动作 ----------
local function handleChoice(choice, imgPath)
    if choice == "原图" then
        pasteFrontmost()

    elseif choice == "表格" then
        local function done(tsv)
            if not tsv or trim(tsv) == "" or trim(tsv):sub(1, 5) == "ERROR" then
                notify("截图粘贴助手", "表格识别失败（图里可能没有规整表格）。要精确识别请去 CatPaw 说\"转成表格\"")
                return
            end
            local tsvPath = TMP .. "/hotkey-latest.tsv"
            if not writeFile(tsvPath, tsv) then
                notify("截图粘贴助手", "写入临时文件失败")
                return
            end
            local _, ok = hs.execute("bash '" .. SKILL .. "/scripts/tsv-to-clipboard.sh' '" .. tsvPath .. "' >/dev/null 2>&1")
            if not ok then
                notify("截图粘贴助手", "写入剪贴板失败，请重试")
                return
            end
            pasteFrontmost()
            notify("截图粘贴助手", "表格已粘贴（快速 OCR 版）。数字建议抽查；精确版去 CatPaw")
        end
        if pre.img == imgPath and pre.tableDone then
            done(pre.tableOut)
        else
            waitPrefetch("tableDone", 3.0, function(_)
                done(pre.img == imgPath and pre.tableOut or nil)
            end)
        end

    elseif choice == "文字" then
        local function done(txt)
            if not txt or trim(txt) == "" or trim(txt):sub(1, 5) == "ERROR" then
                notify("截图粘贴助手", "文字识别失败。请重试或去 CatPaw 处理")
                return
            end
            hs.pasteboard.writeObjects(txt)
            pasteFrontmost()
            notify("截图粘贴助手", "文字已粘贴（快速 OCR 版）")
        end
        if pre.img == imgPath and pre.textDone then
            done(pre.textOut)
        else
            waitPrefetch("textDone", 3.0, function(_)
                done(pre.img == imgPath and pre.textOut or nil)
            end)
        end
    end
end

-- ---------- 三选一面板（hs.dialog.alert 只支持 2 个按钮，故自绘） ----------
local function showChooser(imgPath)
    rememberTarget()

    local m = hs.mouse.absolutePosition()
    local W, HDR, ROWH = 320, 36, 46
    local Hh = HDR + ROWH * 3 + 12
    local screen = hs.mouse.getCurrentScreen()
    local frame = screen and screen:frame() or { x2 = m.x + 400, y2 = m.y + 300 }
    local x = math.min(m.x + 20, frame.x2 - W - 10)
    local y = math.min(m.y + 20, frame.y2 - Hh - 10)

    local labels = {
        { "📄 表格", "识别成表格后粘贴", "表格" },
        { "📝 文字", "提取全部文字后粘贴", "文字" },
        { "🖼 原图", "直接粘贴截图", "原图" },
    }
    local c = hs.canvas.new({ x = x, y = y, w = W, h = Hh })
    c:level(hs.canvas.windowLevels.floating)
    c:behavior(hs.canvas.windowBehaviors.canJoinAllSpaces) -- 全屏空间也能显示
    c:clickActivating(false) -- 点击不抢焦点，目标 App 保持前台
    c[1] = { type = "rectangle", action = "fill", fillColor = { alpha = 0.97, white = 0.13 },
             roundedRectRadii = { xRadius = 10, yRadius = 10 }, frame = { x = 0, y = 0, w = W, h = Hh } }
    c[2] = { type = "text", text = "粘贴成什么？（点此=直接贴原图）", frame = { x = 16, y = 8, w = W - 32, h = 22 },
             textColor = { white = 0.65 }, textSize = 12 }
    for i, it in ipairs(labels) do
        local ry = HDR + (i - 1) * ROWH
        c[#c + 1] = { type = "rectangle", action = "fill", fillColor = { alpha = 0.9, white = 0.22 },
                      roundedRectRadii = { xRadius = 7, yRadius = 7 }, frame = { x = 10, y = ry, w = W - 20, h = ROWH - 10 } }
        c[#c + 1] = { type = "text", text = it[1] .. "　" .. it[2], frame = { x = 24, y = ry + 8, w = W - 44, h = ROWH - 22 },
                      textColor = { white = 0.96 }, textSize = 14 }
    end

    local closed = false
    local function close()
        if closed then return end
        closed = true
        pcall(function() c:delete() end)
    end
    local timer = hs.timer.doAfter(20, function() -- 20 秒未选 = 直接贴原图
        close()
        pasteFrontmost()
    end)

    c:mouseCallback(function(_, msg, _, _, cy) -- 参数顺序: canvas, message, id, x, y
        if msg ~= "mouseDown" then return end
        timer:stop()
        if cy and cy >= HDR then
            local idx = math.min(3, math.max(1, math.floor((cy - HDR) / ROWH) + 1))
            close()
            handleChoice(labels[idx][3], imgPath)
        else
            close() -- 点标题 = 不转换，直接贴原图
            pasteFrontmost()
        end
    end)
    c:canvasMouseEvents(true, true)
    c:show()

    startPrefetch(imgPath) -- 面板一出现就后台识别（并行跑表格+文字）
end

-- ---------- 取图入口 ----------
local function lastCapturedImage()
    local h = io.popen("ls -t '" .. TMP .. "'/clipboard-*.png 2>/dev/null | head -1")
    local p = h and h:read("*l") or nil
    if h then h:close() end
    if p and trim(p) ~= "" then return trim(p) end
    return nil
end

-- Cmd+Alt+V：处理剪贴板里已有的截图
hs.hotkey.bind({ "cmd", "alt" }, "v", function()
    local out, ok = hs.execute(SKILL .. "/scripts/clipboard-image.sh 2>/dev/null")
    local p = ok and trim(out) or ""
    if p == "" then
        local last = lastCapturedImage()
        if last then
            notify("截图粘贴助手", "剪贴板里没有图片，改用最近一次截图")
            showChooser(last)
        else
            notify("截图粘贴助手", "剪贴板里没有图片。请先用 Cmd+Alt+4 截图")
        end
        return
    end
    showChooser(p)
end)

-- Cmd+Alt+4：只选区截图（进剪贴板），不弹面板；弹面板走 Cmd+Alt+V
hs.hotkey.bind({ "cmd", "alt" }, "4", function()
    hs.execute("/usr/sbin/screencapture -i -c") -- 阻塞直到选区完成或按 Esc
    -- 剪贴板写入可能比 screencapture 退出晚一拍，稍等下再确认是否截到
    later(0.25, function()
        local out, ok = hs.execute(SKILL .. "/scripts/clipboard-image.sh 2>/dev/null")
        if ok and trim(out) ~= "" then
            notify("截图粘贴助手", "已截图。按 Cmd+Alt+V 选粘贴成表格/文字/原图")
        end
    end)
end)

notify("截图粘贴助手", "已加载。Cmd+Alt+4=截图；Cmd+Alt+V=选格式粘贴；普通 Cmd+V 不受影响")
