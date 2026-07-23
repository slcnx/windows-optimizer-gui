Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

namespace WindowsOptimizerGUI {
    public struct ScrollPoint {
        public int X;
        public int Y;
    }

    public static class RichTextScroll {
        [DllImport("user32.dll")]
        public static extern IntPtr SendMessage(IntPtr hWnd, uint message, IntPtr wParam, ref ScrollPoint lParam);
    }
}
'@

# 隐藏控制台黑框
Add-Type -Name Window -Namespace Console -MemberDefinition '
[DllImport("Kernel32.dll")] public static extern IntPtr GetConsoleWindow();
[DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
'
$consolePtr = [Console.Window]::GetConsoleWindow()
[Console.Window]::ShowWindow($consolePtr, 0) | Out-Null

# 确保管理员权限
$principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Start-Process powershell -ArgumentList "-ExecutionPolicy Bypass -WindowStyle Normal -File `"$PSCommandPath`"" -Verb RunAs
    Exit
}

$logFile = "$env:USERPROFILE\optimizer_log.txt"
$script:lockedProcesses = @{} # 记忆已绑核限速的进程，方便刷新时追踪
$script:EmbeddedWin11DebloatZipBase64 = "" # BUILD_EMBED_MARKER
$script:Win11DebloatProcess = $null
$script:Win11DebloatTimer = $null
$script:Win11DebloatVersion = "2026.07.11"
$script:Win11DebloatLogFile = $null
$script:Win11DebloatLogLineCount = 0
$script:Win11DebloatRemovalCurrent = 0
$script:Win11DebloatRemovalTotal = 0
$script:Win11DebloatAppNames = @{}
$script:SelectedDebloatAppIds = @()

function Resolve-Win11DebloatScript {
    if (-not [string]::IsNullOrWhiteSpace($PSScriptRoot)) {
        $sourceScript = Join-Path $PSScriptRoot "vendor\Win11Debloat\Win11Debloat.ps1"
        if (Test-Path -LiteralPath $sourceScript) {
            return $sourceScript
        }
    }

    if ([string]::IsNullOrWhiteSpace($script:EmbeddedWin11DebloatZipBase64)) {
        throw "未找到内嵌的 Win11Debloat 资源。请使用 Build-Release.ps1 重新构建发布版。"
    }

    $cacheRoot = Join-Path $env:LOCALAPPDATA "WindowsOptimizerGUI\Win11Debloat\$($script:Win11DebloatVersion)"
    $cachedScript = Join-Path $cacheRoot "Win11Debloat.ps1"
    if (Test-Path -LiteralPath $cachedScript) {
        return $cachedScript
    }

    if (Test-Path -LiteralPath $cacheRoot) {
        Remove-Item -LiteralPath $cacheRoot -Recurse -Force
    }
    New-Item -ItemType Directory -Path $cacheRoot -Force | Out-Null
    $zipPath = Join-Path $cacheRoot "payload.zip"
    try {
        [System.IO.File]::WriteAllBytes($zipPath, [Convert]::FromBase64String($script:EmbeddedWin11DebloatZipBase64))
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        [System.IO.Compression.ZipFile]::ExtractToDirectory($zipPath, $cacheRoot)
    } finally {
        Remove-Item -LiteralPath $zipPath -Force -ErrorAction SilentlyContinue
    }

    if (-not (Test-Path -LiteralPath $cachedScript)) {
        throw "Win11Debloat 内嵌资源解压失败。"
    }
    return $cachedScript
}

function Get-Win11DebloatAppCatalog {
    $debloatScript = Resolve-Win11DebloatScript
    $appsFile = Join-Path (Split-Path -Parent $debloatScript) "Config\Apps.json"
    if (-not (Test-Path -LiteralPath $appsFile)) {
        throw "找不到 Win11Debloat 应用清单：$appsFile"
    }
    return @((Get-Content -Raw -Encoding UTF8 -LiteralPath $appsFile | ConvertFrom-Json).Apps)
}

function Get-AppDescriptionCN {
    param($App)

    $english = [string]$App.Description
    $usage = switch -Regex ($english) {
        'video editor|video editing' { "视频剪辑与编辑应用"; break }
        'photo editing|photo viewing|photo collage' { "图片查看、编辑或创作应用"; break }
        'news|Finance news|Sports news' { "新闻资讯与内容聚合应用"; break }
        'weather forecast' { "天气预报应用"; break }
        'translation service' { "语言翻译应用"; break }
        'AI assistant|AI-enhanced|AI Hub' { "人工智能助手或 AI 功能组件"; break }
        'system cleanup|system optimization' { "系统清理与优化工具"; break }
        'tips|introductory guide|tutorial' { "系统使用提示与入门引导应用"; break }
        'note-taking|sticky notes|Digital note' { "笔记与信息记录应用"; break }
        'Office|Microsoft 365' { "Microsoft 365 / Office 相关应用"; break }
        'game|Gaming|Xbox|puzzle|strategy|casino|Farming|Racing' { "游戏或 Xbox 娱乐组件"; break }
        'streaming|Live TV|music streaming|Media player|plays local audio' { "音视频播放或流媒体应用"; break }
        'social media|social network|professional networking' { "社交网络应用"; break }
        'remote assistance|Remote Desktop' { "远程连接与协助工具"; break }
        'mail|Calendar' { "邮件或日历应用"; break }
        'drawing|sketching|paint' { "绘图与创作应用"; break }
        'PDF' { "PDF 阅读或批注应用"; break }
        'language learning' { "语言学习应用"; break }
        'shopping' { "购物服务应用"; break }
        'compression|extraction' { "文件压缩与解压工具"; break }
        'OEM|HP|Lenovo|Dell|LG' { "设备厂商预装的管理、支持或推广软件"; break }
        'Widgets' { "Windows 小组件相关运行组件"; break }
        'browser' { "网页浏览器应用"; break }
        'Calculator' { "系统计算器应用"; break }
        'Camera' { "相机与摄像头应用"; break }
        'Notepad|text editor' { "文本编辑应用"; break }
        'Store' { "Microsoft Store 应用商店组件"; break }
        'terminal' { "Windows 命令行终端组件"; break }
        default { "$($App.FriendlyName) 对应的 Windows 应用或组件" }
    }

    $risk = switch ([string]$App.Recommendation) {
        "safe" { "通常属于非必要预装、已停用产品或推广内容，可按需清理。" }
        "optional" { "可能仍有使用价值，建议确认自己不需要后再卸载。" }
        "unsafe" { "系统或其他应用可能依赖它，卸载后可能不易恢复，建议保留。" }
        default { "请根据实际用途决定是否卸载。" }
    }
    return "$usage。$risk"
}

function Get-AppRecommendationCN {
    param($App)
    $label = switch ([string]$App.Recommendation) {
        "safe" { "推荐安全清理" }
        "optional" { "可选应用" }
        "unsafe" { "谨慎保留" }
        default { "请确认" }
    }
    return $label
}

function Start-Win11Debloat {
    param([string[]]$Arguments)

    if ($script:Win11DebloatProcess -and -not $script:Win11DebloatProcess.HasExited) {
        Write-Log "[系统精简] Win11Debloat 正在执行，请等待当前任务完成。" "#e67e22"
        return
    }

    try {
        $debloatScript = Resolve-Win11DebloatScript
        $runLogDirectory = Join-Path $env:LOCALAPPDATA "WindowsOptimizerGUI\Logs"
        New-Item -ItemType Directory -Path $runLogDirectory -Force | Out-Null
        $script:Win11DebloatLogFile = Join-Path $runLogDirectory "Win11Debloat.log"
        Remove-Item -LiteralPath $script:Win11DebloatLogFile -Force -ErrorAction SilentlyContinue
        $script:Win11DebloatLogLineCount = 0
        $script:Win11DebloatRemovalCurrent = 0
        $script:Win11DebloatRemovalTotal = 0
        $script:Win11DebloatAppNames = @{}

        if (($Arguments -contains "-RemoveApps") -or
            ($Arguments -contains "-RemoveGamingApps") -or
            ($Arguments -contains "-DisableBing") -or
            ($Arguments -contains "-DisableCopilot") -or
            ($Arguments -contains "-DisableWidgets")) {
            $catalog = @(Get-Win11DebloatAppCatalog)
            $selectedAppIds = New-Object System.Collections.Generic.HashSet[string]
            foreach ($app in $catalog) {
                foreach ($appId in @($app.AppId)) { $script:Win11DebloatAppNames[[string]$appId] = [string]$app.FriendlyName }
            }
            if ($Arguments -contains "-RemoveApps") {
                if ($script:SelectedDebloatAppIds.Count -eq 0) {
                    $script:SelectedDebloatAppIds = @($catalog | Where-Object SelectedByDefault | ForEach-Object { @($_.AppId) })
                }
                foreach ($appId in $script:SelectedDebloatAppIds) { [void]$selectedAppIds.Add([string]$appId) }
            }
            if ($Arguments -contains "-RemoveGamingApps") {
                $debloatRoot = Split-Path -Parent $debloatScript
                $appsJson = Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $debloatRoot "Config\Apps.json") | ConvertFrom-Json
                $gamingPreset = $appsJson.Presets | Where-Object Name -eq "Xbox gaming apps" | Select-Object -First 1
                foreach ($appId in @($gamingPreset.AppIds)) { [void]$selectedAppIds.Add([string]$appId) }
            }
            if ($Arguments -contains "-DisableBing") {
                [void]$selectedAppIds.Add("Microsoft.BingSearch")
                $script:Win11DebloatAppNames["Microsoft.BingSearch"] = "Bing Search"
            }
            if ($Arguments -contains "-DisableCopilot") {
                [void]$selectedAppIds.Add("Microsoft.Copilot")
                [void]$selectedAppIds.Add("XP9CXNGPPJ97XX")
                $script:Win11DebloatAppNames["Microsoft.Copilot"] = "Microsoft Copilot"
                $script:Win11DebloatAppNames["XP9CXNGPPJ97XX"] = "Microsoft Copilot"
            }
            if ($Arguments -contains "-DisableWidgets") {
                foreach ($appId in @("Microsoft.StartExperiencesApp", "MicrosoftWindows.Client.WebExperience", "Microsoft.WidgetsPlatformRuntime")) {
                    [void]$selectedAppIds.Add($appId)
                }
            }
            $script:Win11DebloatRemovalTotal = $selectedAppIds.Count
        }

        $argumentList = @(
            "-NoProfile",
            "-ExecutionPolicy", "Bypass",
            "-File", ('"{0}"' -f $debloatScript),
            "-Silent",
            "-NoRestartExplorer",
            "-LogPath", ('"{0}"' -f $runLogDirectory)
        ) + $Arguments
        if (($Arguments -contains "-RemoveApps") -and $script:SelectedDebloatAppIds.Count -gt 0) {
            $argumentList += @("-Apps", ('"{0}"' -f ($script:SelectedDebloatAppIds -join ",")))
        }

        $script:Win11DebloatProcess = Start-Process -FilePath "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" `
            -ArgumentList $argumentList -WindowStyle Hidden -PassThru
        if ($script:Win11DebloatTimer) { $script:Win11DebloatTimer.Start() }
        if ($progressDebloat) {
            if ($script:Win11DebloatRemovalTotal -gt 0) {
                $progressDebloat.Style = [System.Windows.Forms.ProgressBarStyle]::Continuous
                $progressDebloat.Minimum = 0
                $progressDebloat.Maximum = $script:Win11DebloatRemovalTotal
                $progressDebloat.Value = 0
                $lblDebloatProgress.Text = "准备卸载应用：0 / $($script:Win11DebloatRemovalTotal)"
            } else {
                $progressDebloat.Style = [System.Windows.Forms.ProgressBarStyle]::Marquee
                $lblDebloatProgress.Text = "正在应用系统设置，请稍候……"
            }
        }
        Write-Log "[系统精简] 已启动离线 Win11Debloat $($script:Win11DebloatVersion)：$($Arguments -join ' ')" "#2980b9"
    } catch {
        Write-Log "[系统精简❌] 启动失败：$($_.Exception.Message)" "#e74c3c"
    }
}

function Write-Log {
    param([string]$msg, [string]$color = "#000000")
    $ts = Get-Date -Format "HH:mm:ss"
    $line = "[$ts] $msg"
    Add-Content -Path $logFile -Value $line -Encoding UTF8
    if ($txtLog -and $txtLog.IsHandleCreated) {
        $txtLog.Invoke([Action]{
            $scrollPosition = New-Object WindowsOptimizerGUI.ScrollPoint
            [void][WindowsOptimizerGUI.RichTextScroll]::SendMessage($txtLog.Handle, 0x04DD, [IntPtr]::Zero, [ref]$scrollPosition)
            $lastVisibleCharacter = $txtLog.GetCharIndexFromPosition(
                (New-Object System.Drawing.Point -ArgumentList @(
                    [int]($txtLog.ClientSize.Width - 2),
                    [int]($txtLog.ClientSize.Height - 2)
                ))
            )
            $wasAtBottom = ($txtLog.TextLength -eq 0) -or ($lastVisibleCharacter -ge ($txtLog.TextLength - 2))

            $txtLog.SelectionStart = $txtLog.TextLength
            $txtLog.SelectionLength = 0
            $txtLog.SelectionColor = [System.Drawing.ColorTranslator]::FromHtml($color)
            $txtLog.AppendText("$line`r`n")
            if ($wasAtBottom) {
                $txtLog.ScrollToCaret()
            } else {
                [void][WindowsOptimizerGUI.RichTextScroll]::SendMessage($txtLog.Handle, 0x04DE, [IntPtr]::Zero, [ref]$scrollPosition)
            }
        })
    }
}

function Format-PriorityCN {
    param ($prioEnum)
    if ($null -eq $prioEnum) { return "未知/受保护" }
    $pStr = $prioEnum.ToString()
    $res = switch ($pStr) {
        "RealTime"    { "实时 (极高)" }
        "High"        { "高" }
        "AboveNormal" { "高于标准" }
        "Normal"      { "标准 (普通)" }
        "BelowNormal" { "低于标准" }
        "Idle"        { "低 (空闲)" }
        default       { $pStr }
    }
    return $res
}

function Invoke-BackgroundAutoLock {
    if (-not $chkAutoLock -or -not $chkAutoLock.Checked -or $script:lockedProcesses.Count -eq 0) { return }
    foreach ($procName in @($script:lockedProcesses.Keys)) {
        $lockObj = $script:lockedProcesses[$procName]
        $targetCores = if ($lockObj -is [hashtable]) { $lockObj.Cores } else { [int]$lockObj }
        $targetPrio = if ($lockObj -is [hashtable]) { $lockObj.Priority } else { $null }
        $targetMask = (1 -shl $targetCores) - 1
        $runningProcs = Get-Process -Name $procName -ErrorAction SilentlyContinue
        foreach ($p in $runningProcs) {
            try {
                $needUpdate = $false
                if ($p.ProcessorAffinity -ne [IntPtr]$targetMask) {
                    $p.ProcessorAffinity = [IntPtr]$targetMask
                    $needUpdate = $true
                }
                if ($targetPrio -and $p.PriorityClass -ne $targetPrio) {
                    $p.PriorityClass = $targetPrio
                    $needUpdate = $true
                }
                if ($needUpdate) {
                    $prioStrCN = try { Format-PriorityCN $p.PriorityClass } catch { "未知" }
                    Write-Log "[后台自动守护⚡] 自动拦截变动/新衍生 PID=$($p.Id) [$($p.ProcessName)] 强锁 $targetCores 核 | 优先级: $prioStrCN" "#e67e22"
                }
            } catch {}
        }
    }
}

# ===== 主窗体 =====
$form = New-Object System.Windows.Forms.Form
$form.Text = "Windows 高阶性能优化器 — 精细控制与靶向绑核"
$form.Size = New-Object System.Drawing.Size(740, 840)
$form.StartPosition = "CenterScreen"
$form.FormBorderStyle = "FixedSingle"
$form.MaximizeBox = $false
$form.TopMost = $true
$form.ShowInTaskbar = $true
$form.Font = New-Object System.Drawing.Font("Microsoft YaHei UI", 9)

# ===== 托盘与窗体图标 =====
$notifyIcon = New-Object System.Windows.Forms.NotifyIcon
$appIcon = try {
    if ([System.IO.File]::Exists("C:\Users\EDY\WindowsOptimizer.ico")) {
        New-Object System.Drawing.Icon("C:\Users\EDY\WindowsOptimizer.ico")
    } else {
        [System.Drawing.Icon]::ExtractAssociatedIcon([System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName)
    }
} catch {
    [System.Drawing.Icon]::ExtractAssociatedIcon("$pshome\powershell.exe")
}
$form.Icon = $appIcon
$notifyIcon.Icon = $appIcon
$notifyIcon.Text = "高阶性能优化器 (后台监控运行中)"
$notifyIcon.Visible = $true

$trayMenu = New-Object System.Windows.Forms.ContextMenuStrip
$trayMenu.Font = New-Object System.Drawing.Font("Microsoft YaHei UI", 9)

$menuShow = $trayMenu.Items.Add("🖥️ 显示主界面 / 恢复窗口")
$menuShow.add_Click({
    $form.Show()
    $form.WindowState = 'Normal'
    $form.Activate()
})

$menuQuickCheck = $trayMenu.Items.Add("⚡ 立即触发一次后台限制追锁")
$menuQuickCheck.add_Click({
    Write-Log "[托盘快控⚡] 手动触发对所有已绑定进程的后台扫描与强制限制..." "#2980b9"
    Invoke-BackgroundAutoLock
    if ($form.Visible -and $form.WindowState -ne 'Minimized') {
        & $refreshProcAction
    }
})

[void]$trayMenu.Items.Add("-")

$script:isExplicitExit = $false

$menuExit = $trayMenu.Items.Add("❌ 彻底退出程序")
$menuExit.add_Click({
    $script:isExplicitExit = $true
    $notifyIcon.Visible = $false
    $notifyIcon.Dispose()
    $form.Close()
})

$notifyIcon.ContextMenuStrip = $trayMenu
$form.ContextMenuStrip = $trayMenu

$notifyIcon.add_MouseClick({
    param($sender, $e)
    if ($e.Button -eq [System.Windows.Forms.MouseButtons]::Left) {
        $form.Show()
        $form.WindowState = 'Normal'
        $form.Activate()
    }
})

$notifyIcon.add_DoubleClick({
    $form.Show()
    $form.WindowState = 'Normal'
    $form.Activate()
})

$notifyIcon.add_BalloonTipClicked({
    $form.Show()
    $form.WindowState = 'Normal'
    $form.Activate()
})

$form.add_Resize({
    if ($form.WindowState -eq 'Minimized') {
        $notifyIcon.Visible = $true
        $notifyIcon.ShowBalloonTip(3000, "高阶性能优化器后台监控中", "已最小化。任务栏图标保持保留，同时右下角系统托盘可右键呼出菜单或左键唤回界面！", [System.Windows.Forms.ToolTipIcon]::Info)
    }
})

$script:isClosingPromptOpen = $false

$form.add_FormClosing({
    param($sender, $e)
    if ($script:isExplicitExit) { return }
    if ($script:isClosingPromptOpen) {
        $e.Cancel = $true
        return
    }
    if ($e.CloseReason -eq [System.Windows.Forms.CloseReason]::UserClosing) {
        $script:isClosingPromptOpen = $true
        try {
            $res = [System.Windows.Forms.MessageBox]::Show(
                "您点击了右上角关闭按钮 [ X ]。`n`n选择【是 (Yes)】：最小化至右下角系统托盘，继续在后台帮您自动追锁核心与优先级；`n选择【否 (No)】：彻底退出程序并停止所有后台优化监控。`n`n是否将程序保留在后台托盘继续运行？",
                "提示：关闭选择 — 高阶性能优化器",
                [System.Windows.Forms.MessageBoxButtons]::YesNoCancel,
                [System.Windows.Forms.MessageBoxIcon]::Question,
                [System.Windows.Forms.MessageBoxDefaultButton]::Button1
            )
            if ($res -eq [System.Windows.Forms.DialogResult]::Yes) {
                $e.Cancel = $true
                $form.Hide()
                $notifyIcon.Visible = $true
                $notifyIcon.ShowBalloonTip(3000, "高阶性能优化器后台守护中", "已为您最小化至系统托盘。左键单击图标或右键弹出菜单即可唤回主界面！", [System.Windows.Forms.ToolTipIcon]::Info)
            } elseif ($res -eq [System.Windows.Forms.DialogResult]::No) {
                $script:isExplicitExit = $true
                $notifyIcon.Visible = $false
                $notifyIcon.Dispose()
            } else {
                $e.Cancel = $true
            }
        } finally {
            $script:isClosingPromptOpen = $false
        }
    }
})

# ===== 主布局容器 =====
$mainContainer = New-Object System.Windows.Forms.Panel
$mainContainer.Dock = "Fill"
$mainContainer.Padding = New-Object System.Windows.Forms.Padding(10)
[void]$form.Controls.Add($mainContainer)

# ===== 顶部标签页 (TabControl) =====
$tabControl = New-Object System.Windows.Forms.TabControl
$tabControl.Dock = "Top"
$tabControl.Height = 540
[void]$mainContainer.Controls.Add($tabControl)

# --- 标签页 1: 进程监控与核心绑定 ---
$tabProc = New-Object System.Windows.Forms.TabPage
$tabProc.Text = "🎯 进程核心绑定 & 资源监控"
$tabProc.Padding = New-Object System.Windows.Forms.Padding(10)
$tabProc.BackColor = [System.Drawing.Color]::FromArgb(248, 249, 250)
[void]$tabControl.TabPages.Add($tabProc)

# --- 标签页 2: 系统服务与定时任务精细控制 ---
$tabSvc = New-Object System.Windows.Forms.TabPage
$tabSvc.Text = "⚙️ 系统服务与任务精细控制 (单项开关)"
$tabSvc.Padding = New-Object System.Windows.Forms.Padding(10)
$tabSvc.BackColor = [System.Drawing.Color]::FromArgb(248, 249, 250)
[void]$tabControl.TabPages.Add($tabSvc)

# --- 标签页 3: 内嵌 Win11Debloat 中文前端 ---
$tabDebloat = New-Object System.Windows.Forms.TabPage
$tabDebloat.Text = "🧹 系统精简（离线内嵌）"
$tabDebloat.Padding = New-Object System.Windows.Forms.Padding(10)
$tabDebloat.BackColor = [System.Drawing.Color]::FromArgb(248, 249, 250)
[void]$tabControl.TabPages.Add($tabDebloat)

# =========================================================================
#                       TAB 1: 进程监控与核心绑定
# =========================================================================

# 进程限制操作区域 GroupBox
$grpLimit = New-Object System.Windows.Forms.GroupBox
$grpLimit.Location = New-Object System.Drawing.Point(10, 10)
$grpLimit.Size = New-Object System.Drawing.Size(686, 95)
$grpLimit.Text = "靶向限制进程 CPU 亲和性与优先级"
$grpLimit.Font = New-Object System.Drawing.Font("Microsoft YaHei UI", 9.5, [System.Drawing.FontStyle]::Bold)
[void]$tabProc.Controls.Add($grpLimit)

$lblProcName = New-Object System.Windows.Forms.Label
$lblProcName.Location = New-Object System.Drawing.Point(10, 30)
$lblProcName.Size = New-Object System.Drawing.Size(55, 24)
$lblProcName.Text = "进程名:"
$lblProcName.Font = New-Object System.Drawing.Font("Microsoft YaHei UI", 9)
[void]$grpLimit.Controls.Add($lblProcName)

$txtProcName = New-Object System.Windows.Forms.TextBox
$txtProcName.Location = New-Object System.Drawing.Point(65, 28)
$txtProcName.Size = New-Object System.Drawing.Size(115, 24)
$txtProcName.Font = New-Object System.Drawing.Font("Consolas", 9.5)
[void]$grpLimit.Controls.Add($txtProcName)

$lblCores = New-Object System.Windows.Forms.Label
$lblCores.Location = New-Object System.Drawing.Point(185, 30)
$lblCores.Size = New-Object System.Drawing.Size(65, 24)
$lblCores.Text = "限制核心:"
$lblCores.Font = New-Object System.Drawing.Font("Microsoft YaHei UI", 9)
[void]$grpLimit.Controls.Add($lblCores)

$numCores = New-Object System.Windows.Forms.NumericUpDown
$numCores.Location = New-Object System.Drawing.Point(250, 28)
$numCores.Size = New-Object System.Drawing.Size(45, 24)
$numCores.Minimum = 1
$numCores.Maximum = 64
$numCores.Value = 2
$numCores.Font = New-Object System.Drawing.Font("Consolas", 9.5)
[void]$grpLimit.Controls.Add($numCores)

$lblPrio = New-Object System.Windows.Forms.Label
$lblPrio.Location = New-Object System.Drawing.Point(300, 30)
$lblPrio.Size = New-Object System.Drawing.Size(80, 24)
$lblPrio.Text = "设置优先级:"
$lblPrio.Font = New-Object System.Drawing.Font("Microsoft YaHei UI", 9)
[void]$grpLimit.Controls.Add($lblPrio)

$cmbPrio = New-Object System.Windows.Forms.ComboBox
$cmbPrio.Location = New-Object System.Drawing.Point(380, 28)
$cmbPrio.Size = New-Object System.Drawing.Size(155, 24)
$cmbPrio.DropDownStyle = "DropDownList"
$cmbPrio.Font = New-Object System.Drawing.Font("Microsoft YaHei UI", 9)
[void]$cmbPrio.Items.AddRange(@(
    "不修改(保持原状)",
    "实时/极高 (RealTime)",
    "高优先级 (High)",
    "高于标准 (AboveNormal)",
    "标准/普通 (Normal)",
    "低于标准 (BelowNormal)",
    "低/空闲 (Idle)"
))
$cmbPrio.SelectedIndex = 0
[void]$grpLimit.Controls.Add($cmbPrio)

$btnLimit = New-Object System.Windows.Forms.Button
$btnLimit.Location = New-Object System.Drawing.Point(540, 26)
$btnLimit.Size = New-Object System.Drawing.Size(135, 30)
$btnLimit.Text = "🔒 锁定限制设置"
$btnLimit.BackColor = [System.Drawing.Color]::FromArgb(41, 128, 185)
$btnLimit.ForeColor = [System.Drawing.Color]::White
$btnLimit.FlatStyle = "Flat"
$btnLimit.Font = New-Object System.Drawing.Font("Microsoft YaHei UI", 9, [System.Drawing.FontStyle]::Bold)
[void]$grpLimit.Controls.Add($btnLimit)

$chkAutoLock = New-Object System.Windows.Forms.CheckBox
$chkAutoLock.Location = New-Object System.Drawing.Point(65, 62)
$chkAutoLock.Size = New-Object System.Drawing.Size(550, 24)
$chkAutoLock.Text = "⚡ 开启后台连续智能守护 (每3秒自动巡检，后台或最小化至托盘均生效，对变动 PID 强锁)"
$chkAutoLock.Checked = $true
$chkAutoLock.Font = New-Object System.Drawing.Font("Microsoft YaHei UI", 8.5)
[void]$grpLimit.Controls.Add($chkAutoLock)

# 进程监控列表标题与按钮
$lblProcTitle = New-Object System.Windows.Forms.Label
$lblProcTitle.Location = New-Object System.Drawing.Point(10, 118)
$lblProcTitle.Size = New-Object System.Drawing.Size(380, 24)
$lblProcTitle.Text = "🔍 高消耗后台进程实时监控 (选中即可限核，实时显示当前核数):"
$lblProcTitle.Font = New-Object System.Drawing.Font("Microsoft YaHei UI", 9, [System.Drawing.FontStyle]::Bold)
[void]$tabProc.Controls.Add($lblProcTitle)

$btnRefreshProc = New-Object System.Windows.Forms.Button
$btnRefreshProc.Location = New-Object System.Drawing.Point(575, 114)
$btnRefreshProc.Size = New-Object System.Drawing.Size(120, 28)
$btnRefreshProc.Text = "🔄 刷新列表"
$btnRefreshProc.FlatStyle = "Flat"
[void]$tabProc.Controls.Add($btnRefreshProc)

$dgvProc = New-Object System.Windows.Forms.DataGridView
$dgvProc.Location = New-Object System.Drawing.Point(10, 146)
$dgvProc.Size = New-Object System.Drawing.Size(686, 350)
$dgvProc.ReadOnly = $true
$dgvProc.AllowUserToAddRows = $false
$dgvProc.SelectionMode = "FullRowSelect"
$dgvProc.AutoSizeColumnsMode = "Fill"
$dgvProc.RowHeadersVisible = $false
$dgvProc.BackgroundColor = [System.Drawing.Color]::White
$dgvProc.BorderStyle = "Fixed3D"
$dgvProc.Font = New-Object System.Drawing.Font("Consolas", 9)
[void]$tabProc.Controls.Add($dgvProc)

$dgvProc.add_CellClick({
    if ($dgvProc.SelectedRows.Count -gt 0) {
        $txtProcName.Text = $dgvProc.SelectedRows[0].Cells[0].Value
        $cellPrio = $dgvProc.SelectedRows[0].Cells[3].Value
        if ($cellPrio -match "实时") { $cmbPrio.SelectedIndex = 1 }
        elseif ($cellPrio -match "^高$") { $cmbPrio.SelectedIndex = 2 }
        elseif ($cellPrio -match "高于标准") { $cmbPrio.SelectedIndex = 3 }
        elseif ($cellPrio -match "标准") { $cmbPrio.SelectedIndex = 4 }
        elseif ($cellPrio -match "低于标准") { $cmbPrio.SelectedIndex = 5 }
        elseif ($cellPrio -match "低") { $cmbPrio.SelectedIndex = 6 }
        else { $cmbPrio.SelectedIndex = 0 }
    }
})

# 锁定按钮逻辑
$btnLimit.Add_Click({
    $pName = $txtProcName.Text.Trim()
    if ([string]::IsNullOrEmpty($pName)) {
        Write-Log "[限制] 请先在进程列表中点击选择一个进程，或手动输入进程名" "#e74c3c"
        return
    }
    $procs = Get-Process -Name $pName -ErrorAction SilentlyContinue
    if (-not $procs) {
        Write-Log "[限制] 未找到正在运行的进程: $pName" "#e74c3c"
        return
    }
    $cores = [int]$numCores.Value
    $mask = (1 -shl $cores) - 1
    
    $targetPrioClass = switch ($cmbPrio.SelectedIndex) {
        1 { [System.Diagnostics.ProcessPriorityClass]::RealTime }
        2 { [System.Diagnostics.ProcessPriorityClass]::High }
        3 { [System.Diagnostics.ProcessPriorityClass]::AboveNormal }
        4 { [System.Diagnostics.ProcessPriorityClass]::Normal }
        5 { [System.Diagnostics.ProcessPriorityClass]::BelowNormal }
        6 { [System.Diagnostics.ProcessPriorityClass]::Idle }
        default { $null }
    }
    
    $success = 0
    
    # 记录到记忆字典（改成保存对象：记录核心数与目标优先级）
    $script:lockedProcesses[$pName] = @{
        Cores = $cores
        Priority = $targetPrioClass
    }

    foreach ($p in $procs) {
        try {
            $oldPriority = Format-PriorityCN $p.PriorityClass
            if ($targetPrioClass) {
                $p.PriorityClass = $targetPrioClass
            }
            $p.ProcessorAffinity = [IntPtr]$mask
            $success++
            $newPriority = Format-PriorityCN $p.PriorityClass
            Write-Log "[限制✅] PID=$($p.Id) [$pName] 优先级: $oldPriority → $newPriority | CPU亲和性: 限定 $cores 核 (掩码=0x$('{0:X}' -f $mask))" "#27ae60"
        } catch {
            Write-Log "[限制❌] PID=$($p.Id) [$pName] 失败: $($_.Exception.Message)" "#e74c3c"
        }
    }
    Write-Log "[限制] 共处理 $($procs.Count) 个 [$pName] 进程，成功 $success 个！" "#2c3e50"
    & $refreshProcAction
})

# 刷新进程列表逻辑 (带当前核心和优先级读取与全中文反显)
$refreshProcAction = {
    $btnRefreshProc.Text = "刷新中..."
    $form.Refresh()
    $table = New-Object System.Data.DataTable
    [void]$table.Columns.Add("进程名")
    [void]$table.Columns.Add("内存(MB)")
    [void]$table.Columns.Add("累计CPU(s)")
    [void]$table.Columns.Add("优先级")
    [void]$table.Columns.Add("当前核心限制")
    [void]$table.Columns.Add("PID")

    $procs = Get-Process | Where-Object {
        $_.ProcessName -notmatch "^(svchost|System|Idle|Registry|csrss|smss|lsass|services|wininit|winlogon|fontdrvhost|dwm|conhost|WmiPrvSE|spoolsv|sihost|taskhostw|RuntimeBroker|SecurityHealthSystray|dllhost|ctfmon|ApplicationFrameHost|StartMenuExperienceHost|ShellExperienceHost)$"
    } | Sort-Object WS -Descending | Select-Object -First 25

    foreach ($p in $procs) {
        $mem = [math]::Round($p.WS / 1MB, 1)
        $cpu = if ($p.CPU) { [math]::Round($p.CPU, 1) } else { 0 }
        
        # 尝试读取或自动跟踪锁定
        if ($chkAutoLock.Checked -and $script:lockedProcesses.ContainsKey($p.ProcessName)) {
            $lockObj = $script:lockedProcesses[$p.ProcessName]
            # 兼容旧格式与新格式
            $targetCores = if ($lockObj -is [hashtable]) { $lockObj.Cores } else { [int]$lockObj }
            $targetPrio = if ($lockObj -is [hashtable]) { $lockObj.Priority } else { $null }
            $targetMask = (1 -shl $targetCores) - 1
            try {
                $needUpdate = $false
                if ($p.ProcessorAffinity -ne [IntPtr]$targetMask) {
                    $p.ProcessorAffinity = [IntPtr]$targetMask
                    $needUpdate = $true
                }
                if ($targetPrio -and $p.PriorityClass -ne $targetPrio) {
                    $p.PriorityClass = $targetPrio
                    $needUpdate = $true
                }
                if ($needUpdate) {
                    $prioStrCN = Format-PriorityCN $p.PriorityClass
                    Write-Log "[自动追踪✅] 对新衍生/变动 PID=$($p.Id) [$($p.ProcessName)] 自动重绑至 $targetCores 核 | 优先级: $prioStrCN" "#2980b9"
                }
            } catch {}
        }

        # 读取当前的优先级与分配的核心数 (Affinity)
        $prioStr = try { Format-PriorityCN $p.PriorityClass } catch { "未知/受保护" }
        $affStr = try {
            $aff = [int64]$p.ProcessorAffinity
            $count = 0
            $temp = $aff
            while ($temp -gt 0) {
                if (($temp -band 1) -eq 1) { $count++ }
                $temp = $temp -shr 1
            }
            "$count 核 (0x$('{0:X}' -f $aff))"
        } catch { "未知/系统限制" }

        [void]$table.Rows.Add($p.ProcessName, $mem, $cpu, $prioStr, $affStr, $p.Id)
    }
    $dgvProc.DataSource = $table
    
    # 高亮内存 > 500MB 行，并针对中文优先级赋予不同颜色警示
    foreach ($row in $dgvProc.Rows) {
        $memVal = 0
        if ([double]::TryParse($row.Cells[1].Value, [ref]$memVal) -and $memVal -gt 500) {
            $row.DefaultCellStyle.BackColor = [System.Drawing.Color]::FromArgb(255, 235, 235)
        }
        $pCellVal = $row.Cells[3].Value
        if ($pCellVal -match "低 \(空闲\)|低于标准") {
            $row.Cells[3].Style.ForeColor = [System.Drawing.Color]::FromArgb(39, 174, 96)
            $row.Cells[3].Style.Font = New-Object System.Drawing.Font("Consolas", 9, [System.Drawing.FontStyle]::Bold)
        }
        elseif ($pCellVal -match "实时|^高$|高于标准") {
            $row.Cells[3].Style.ForeColor = [System.Drawing.Color]::FromArgb(192, 57, 43)
            $row.Cells[3].Style.Font = New-Object System.Drawing.Font("Consolas", 9, [System.Drawing.FontStyle]::Bold)
        }
    }
    $btnRefreshProc.Text = "🔄 刷新列表"
}
$btnRefreshProc.Add_Click($refreshProcAction)

# =========================================================================
#                    TAB 2: 系统服务与定时任务精细控制
# =========================================================================

$lblSvcDesc = New-Object System.Windows.Forms.Label
$lblSvcDesc.Location = New-Object System.Drawing.Point(10, 12)
$lblSvcDesc.Size = New-Object System.Drawing.Size(686, 24)
$lblSvcDesc.Text = "💡 单项精细控制：按住 Ctrl 或 Shift 可多选，在下方按需【启用】或【禁用】所选功能："
$lblSvcDesc.Font = New-Object System.Drawing.Font("Microsoft YaHei UI", 9, [System.Drawing.FontStyle]::Bold)
[void]$tabSvc.Controls.Add($lblSvcDesc)

$dgvSvc = New-Object System.Windows.Forms.DataGridView
$dgvSvc.Location = New-Object System.Drawing.Point(10, 42)
$dgvSvc.Size = New-Object System.Drawing.Size(686, 400)
$dgvSvc.ReadOnly = $true
$dgvSvc.AllowUserToAddRows = $false
$dgvSvc.SelectionMode = "FullRowSelect"
$dgvSvc.AutoSizeColumnsMode = "Fill"
$dgvSvc.RowHeadersVisible = $false
$dgvSvc.BackgroundColor = [System.Drawing.Color]::White
$dgvSvc.BorderStyle = "Fixed3D"
$dgvSvc.Font = New-Object System.Drawing.Font("Microsoft YaHei UI", 8.5)
$dgvSvc.add_DataBindingComplete({
    if ($dgvSvc.Columns.Count -ge 4 -and $dgvSvc.Columns[0] -ne $null) {
        $dgvSvc.Columns[0].FillWeight = 15
        $dgvSvc.Columns[1].FillWeight = 25
        $dgvSvc.Columns[2].FillWeight = 40
        $dgvSvc.Columns[3].FillWeight = 20
    }
    foreach ($row in $dgvSvc.Rows) {
        if ($row.Cells.Count -ge 4 -and $row.Cells[3] -ne $null -and $row.Cells[3].Value -ne $null) {
            $st = $row.Cells[3].Value -as [string]
            if ($st -match "Disabled|Stopped|优化状态") {
                $row.Cells[3].Style.ForeColor = [System.Drawing.Color]::FromArgb(39, 174, 96)
            } elseif ($st -match "Running|Automatic|Ready|开启中") {
                $row.Cells[3].Style.ForeColor = [System.Drawing.Color]::FromArgb(192, 57, 43)
            }
        }
    }
})
[void]$tabSvc.Controls.Add($dgvSvc)

$btnRefreshSvc = New-Object System.Windows.Forms.Button
$btnRefreshSvc.Location = New-Object System.Drawing.Point(10, 456)
$btnRefreshSvc.Size = New-Object System.Drawing.Size(130, 36)
$btnRefreshSvc.Text = "🔄 刷新当前状态"
$btnRefreshSvc.FlatStyle = "Flat"
[void]$tabSvc.Controls.Add($btnRefreshSvc)

$btnDisableSelected = New-Object System.Windows.Forms.Button
$btnDisableSelected.Location = New-Object System.Drawing.Point(365, 456)
$btnDisableSelected.Size = New-Object System.Drawing.Size(160, 36)
$btnDisableSelected.Text = "🔴 禁用选中项 (优化)"
$btnDisableSelected.BackColor = [System.Drawing.Color]::FromArgb(231, 76, 60)
$btnDisableSelected.ForeColor = [System.Drawing.Color]::White
$btnDisableSelected.FlatStyle = "Flat"
$btnDisableSelected.Font = New-Object System.Drawing.Font("Microsoft YaHei UI", 9, [System.Drawing.FontStyle]::Bold)
[void]$tabSvc.Controls.Add($btnDisableSelected)

$btnEnableSelected = New-Object System.Windows.Forms.Button
$btnEnableSelected.Location = New-Object System.Drawing.Point(535, 456)
$btnEnableSelected.Size = New-Object System.Drawing.Size(160, 36)
$btnEnableSelected.Text = "🟢 启用选中项 (还原)"
$btnEnableSelected.BackColor = [System.Drawing.Color]::FromArgb(46, 204, 113)
$btnEnableSelected.ForeColor = [System.Drawing.Color]::White
$btnEnableSelected.FlatStyle = "Flat"
$btnEnableSelected.Font = New-Object System.Drawing.Font("Microsoft YaHei UI", 9, [System.Drawing.FontStyle]::Bold)
[void]$tabSvc.Controls.Add($btnEnableSelected)

# 服务项清单定义
$script:optimizationItems = @(
    @{Type="[服务]"; Name="SysMain"; Desc="SuperFetch 预加载服务 (容易导致高内存/高读写)"; DefaultStart="Automatic"},
    @{Type="[服务]"; Name="WSearch"; Desc="Windows 搜索索引服务 (极易导致后台高磁盘 IO)"; DefaultStart="Automatic"},
    @{Type="[服务]"; Name="DiagTrack"; Desc="微软遥测/用户诊断数据收集服务"; DefaultStart="Automatic"},
    @{Type="[服务]"; Name="dmwappushservice"; Desc="WAP Push 消息路由 (微软遥测辅助服务)"; DefaultStart="Manual"},
    @{Type="[服务]"; Name="MapsBroker"; Desc="下载地图管理器服务"; DefaultStart="Automatic"},
    @{Type="[服务]"; Name="XblAuthManager"; Desc="Xbox 身份验证管理器"; DefaultStart="Manual"},
    @{Type="[服务]"; Name="XblGameSave"; Desc="Xbox 游戏存档同步服务"; DefaultStart="Manual"},
    @{Type="[服务]"; Name="XboxNetApiSvc"; Desc="Xbox 网络 API 服务"; DefaultStart="Manual"},
    @{Type="[计划任务]"; Name="Microsoft Compatibility Appraiser"; Path="\Microsoft\Windows\Application Experience\"; Desc="微软应用兼容性评估扫描后台任务"},
    @{Type="[计划任务]"; Name="Consolidator"; Path="\Microsoft\Windows\Customer Experience Improvement Program\"; Desc="CEIP 体验改善数据收集计划"},
    @{Type="[计划任务]"; Name="UsbCeip"; Path="\Microsoft\Windows\Customer Experience Improvement Program\"; Desc="USB 设备 CEIP 数据收集计划"},
    @{Type="[计划任务]"; Name="Microsoft-Windows-DiskDiagnosticDataCollector"; Path="\Microsoft\Windows\DiskDiagnostic\"; Desc="磁盘诊断数据收集后台计划"},
    @{Type="[计划任务]"; Name="ScheduledDefrag"; Path="\Microsoft\Windows\Defrag\"; Desc="自动碎片整理定时扫描 (固态硬盘无需多次整理)"},
    @{Type="[计划任务]"; Name="FamilySafetyRefresh"; Path="\Microsoft\Windows\Shell\"; Desc="家庭安全监控策略刷新任务"},
    @{Type="[磁盘IO]"; Name="disable8dot3"; Desc="8.3 短文件名生成策略 (禁用可加速文件夹枚举)"; DefaultVal="2"},
    @{Type="[磁盘IO]"; Name="disablelastaccess"; Desc="文件最后访问时间戳记录 (禁用可大大减小磁盘写操作)"; DefaultVal="2"}
)

# 刷新服务/定时任务列表数据
$refreshSvcAction = {
    $btnRefreshSvc.Text = "刷新中..."
    $form.Refresh()
    $table = New-Object System.Data.DataTable
    [void]$table.Columns.Add("类型")
    [void]$table.Columns.Add("名称")
    [void]$table.Columns.Add("功能说明")
    [void]$table.Columns.Add("当前系统状态")

    foreach ($item in $script:optimizationItems) {
        $statusStr = "未知"
        if ($item.Type -eq "[服务]") {
            $s = Get-Service -Name $item.Name -ErrorAction SilentlyContinue
            if ($s) {
                $startType = $s.StartType
                $statusStr = "$($s.Status) ($startType)"
            } else {
                $statusStr = "未安装"
            }
        } elseif ($item.Type -eq "[计划任务]") {
            $t = Get-ScheduledTask -TaskPath $item.Path -TaskName $item.Name -ErrorAction SilentlyContinue
            if ($t) {
                $statusStr = "$($t.State)"
            } else {
                $statusStr = "未找到任务"
            }
        } elseif ($item.Type -eq "[磁盘IO]") {
            $res = fsutil behavior query $item.Name 2>&1
            if ($res -match " = 1") { $statusStr = "已禁用该冗余记录 (优化状态)" }
            elseif ($res -match " = 0| = 2| = 3") { $statusStr = "系统默认/开启中" }
            else { $statusStr = "$res" }
        }
        [void]$table.Rows.Add($item.Type, $item.Name, $item.Desc, $statusStr)
    }
    $dgvSvc.DataSource = $table
    
    # 调整列宽占比及行颜色（带安全检查防报错）
    if ($dgvSvc.Columns.Count -ge 4 -and $dgvSvc.Columns[0] -ne $null) {
        $dgvSvc.Columns[0].FillWeight = 15
        $dgvSvc.Columns[1].FillWeight = 25
        $dgvSvc.Columns[2].FillWeight = 40
        $dgvSvc.Columns[3].FillWeight = 20
    }

    # 对已禁用/已停用的高亮或区分颜色
    foreach ($row in $dgvSvc.Rows) {
        if ($row.Cells.Count -ge 4 -and $row.Cells[3] -ne $null -and $row.Cells[3].Value -ne $null) {
            $st = $row.Cells[3].Value -as [string]
            if ($st -match "Disabled|Stopped|优化状态") {
                $row.Cells[3].Style.ForeColor = [System.Drawing.Color]::FromArgb(39, 174, 96)
            } elseif ($st -match "Running|Automatic|Ready|开启中") {
                $row.Cells[3].Style.ForeColor = [System.Drawing.Color]::FromArgb(192, 57, 43)
            }
        }
    }
    $btnRefreshSvc.Text = "🔄 刷新当前状态"
}
$btnRefreshSvc.Add_Click($refreshSvcAction)

# 禁用选中项
$btnDisableSelected.Add_Click({
    if ($dgvSvc.SelectedRows.Count -eq 0) {
        Write-Log "[控制提示] 请先在表格中点击选择至少一个要调整的服务或任务！" "#e67e22"
        return
    }
    foreach ($row in $dgvSvc.SelectedRows) {
        $type = $row.Cells[0].Value
        $name = $row.Cells[1].Value
        $desc = $row.Cells[2].Value
        $item = $script:optimizationItems | Where-Object { $_.Name -eq $name -and $_.Type -eq $type }
        
        if ($type -eq "[服务]") {
            Stop-Service -Name $name -Force -ErrorAction SilentlyContinue
            Set-Service -Name $name -StartupType Disabled -ErrorAction SilentlyContinue
            Write-Log "[服务禁用✅] $name ($desc) 已设为 Disabled 并停止" "#e74c3c"
        } elseif ($type -eq "[计划任务]") {
            Disable-ScheduledTask -TaskPath $item.Path -TaskName $name -ErrorAction SilentlyContinue | Out-Null
            Write-Log "[任务禁用✅] $name ($desc) 已设为 Disabled" "#8e44ad"
        } elseif ($type -eq "[磁盘IO]") {
            fsutil behavior set $name 1 | Out-Null
            Write-Log "[磁盘优化✅] $name ($desc) 已配置为 1 (禁用冗余开销)" "#2980b9"
        }
    }
    & $refreshSvcAction
})

# 启用/还原选中项
$btnEnableSelected.Add_Click({
    if ($dgvSvc.SelectedRows.Count -eq 0) {
        Write-Log "[控制提示] 请先在表格中点击选择至少一个要调整的服务或任务！" "#e67e22"
        return
    }
    foreach ($row in $dgvSvc.SelectedRows) {
        $type = $row.Cells[0].Value
        $name = $row.Cells[1].Value
        $desc = $row.Cells[2].Value
        $item = $script:optimizationItems | Where-Object { $_.Name -eq $name -and $_.Type -eq $type }
        
        if ($type -eq "[服务]") {
            $defStart = if ($item.DefaultStart) { $item.DefaultStart } else { "Automatic" }
            Set-Service -Name $name -StartupType $defStart -ErrorAction SilentlyContinue
            if ($defStart -eq "Automatic") {
                Start-Service -Name $name -ErrorAction SilentlyContinue
            }
            Write-Log "[服务还原🟢] $name ($desc) 已恢复为 $defStart 启动类型" "#27ae60"
        } elseif ($type -eq "[计划任务]") {
            Enable-ScheduledTask -TaskPath $item.Path -TaskName $name -ErrorAction SilentlyContinue | Out-Null
            Write-Log "[任务启用🟢] $name ($desc) 已重新启用 (Ready)" "#27ae60"
        } elseif ($type -eq "[磁盘IO]") {
            $defVal = if ($item.DefaultVal) { $item.DefaultVal } else { "2" }
            fsutil behavior set $name $defVal | Out-Null
            Write-Log "[磁盘还原🟢] $name ($desc) 已恢复系统默认 ($defVal)" "#27ae60"
        }
    }
    & $refreshSvcAction
})

# =========================================================================
#                       TAB 3: Win11Debloat 中文前端
# =========================================================================

$lblDebloatTitle = New-Object System.Windows.Forms.Label
$lblDebloatTitle.Location = New-Object System.Drawing.Point(10, 10)
$lblDebloatTitle.Size = New-Object System.Drawing.Size(680, 42)
$lblDebloatTitle.Text = "Win11Debloat $($script:Win11DebloatVersion) 已完整内嵌，运行时不联网下载。`r`n勾选后执行；涉及系统设置与应用卸载，建议先创建还原点。"
$lblDebloatTitle.Font = New-Object System.Drawing.Font("Microsoft YaHei UI", 9, [System.Drawing.FontStyle]::Bold)
[void]$tabDebloat.Controls.Add($lblDebloatTitle)

$script:DebloatOptions = @(
    [pscustomobject]@{ Category = "应用清理"; Label = "卸载自选的预装与推广应用（点击下方按钮选择）"; Argument = "-RemoveApps"; Selected = $false },
    [pscustomobject]@{ Category = "应用清理"; Label = "卸载 Xbox 游戏类预装应用"; Argument = "-RemoveGamingApps"; Selected = $false },
    [pscustomobject]@{ Category = "隐私与推广"; Label = "关闭遥测、诊断数据、活动历史与广告跟踪"; Argument = "-DisableTelemetry"; Selected = $false },
    [pscustomobject]@{ Category = "隐私与推广"; Label = "关闭 Windows 搜索历史"; Argument = "-DisableSearchHistory"; Selected = $false },
    [pscustomobject]@{ Category = "隐私与推广"; Label = "关闭开始菜单/搜索中的 Bing 联网结果"; Argument = "-DisableBing"; Selected = $false },
    [pscustomobject]@{ Category = "隐私与推广"; Label = "关闭 Windows 提示、建议与推广内容"; Argument = "-DisableSuggestions"; Selected = $false },
    [pscustomobject]@{ Category = "隐私与推广"; Label = "关闭定位服务与应用定位权限"; Argument = "-DisableLocationServices"; Selected = $false },
    [pscustomobject]@{ Category = "隐私与推广"; Label = "关闭「查找我的设备」定位跟踪"; Argument = "-DisableFindMyDevice"; Selected = $false },
    [pscustomobject]@{ Category = "隐私与推广"; Label = "关闭 Edge 广告、建议与推广内容"; Argument = "-DisableEdgeAds"; Selected = $false },
    [pscustomobject]@{ Category = "隐私与推广"; Label = "隐藏设置主页中的 Microsoft 365 广告"; Argument = "-DisableSettings365Ads"; Selected = $false },
    [pscustomobject]@{ Category = "隐私与推广"; Label = "隐藏设置应用的主页"; Argument = "-DisableSettingsHome"; Selected = $false },
    [pscustomobject]@{ Category = "AI 功能"; Label = "禁用并移除 Microsoft Copilot"; Argument = "-DisableCopilot"; Selected = $false },
    [pscustomobject]@{ Category = "AI 功能"; Label = "禁用 Windows Recall（回顾）"; Argument = "-DisableRecall"; Selected = $false },
    [pscustomobject]@{ Category = "AI 功能"; Label = "禁用 Click to Do（单击即办）"; Argument = "-DisableClickToDo"; Selected = $false },
    [pscustomobject]@{ Category = "AI 功能"; Label = "禁止 Windows AI 服务自动启动"; Argument = "-DisableAISvcAutoStart"; Selected = $false },
    [pscustomobject]@{ Category = "AI 功能"; Label = "关闭画图、记事本与 Edge 的 AI 功能"; Arguments = @("-DisablePaintAI", "-DisableNotepadAI", "-DisableEdgeAI"); Selected = $false },
    [pscustomobject]@{ Category = "系统与更新"; Label = "关闭快速启动，确保每次完整关机"; Argument = "-DisableFastStartup"; Selected = $false },
    [pscustomobject]@{ Category = "系统与更新"; Label = "关闭 BitLocker 自动设备加密"; Argument = "-DisableBitlockerAutoEncryption"; Selected = $false },
    [pscustomobject]@{ Category = "系统与更新"; Label = "关闭存储感知自动清理"; Argument = "-DisableStorageSense"; Selected = $false },
    [pscustomobject]@{ Category = "系统与更新"; Label = "阻止 Windows 更新后自动重启"; Argument = "-PreventUpdateAutoReboot"; Selected = $false },
    [pscustomobject]@{ Category = "系统与更新"; Label = "关闭传递优化（局域网/互联网更新共享）"; Argument = "-DisableDeliveryOptimization"; Selected = $false },
    [pscustomobject]@{ Category = "交互与资源管理器"; Label = "关闭鼠标加速（提高指针精确度）"; Argument = "-DisableMouseAcceleration"; Selected = $false },
    [pscustomobject]@{ Category = "交互与资源管理器"; Label = "关闭粘滞键快捷键弹窗"; Argument = "-DisableStickyKeys"; Selected = $false },
    [pscustomobject]@{ Category = "交互与资源管理器"; Label = "恢复 Windows 10 经典右键菜单"; Argument = "-RevertContextMenu"; Selected = $false },
    [pscustomobject]@{ Category = "交互与资源管理器"; Label = "显示已知文件类型的扩展名"; Argument = "-ShowKnownFileExt"; Selected = $false },
    [pscustomobject]@{ Category = "交互与资源管理器"; Label = "显示资源管理器中的隐藏文件夹"; Argument = "-ShowHiddenFolders"; Selected = $false },
    [pscustomobject]@{ Category = "交互与资源管理器"; Label = "任务栏图标左对齐"; Argument = "-TaskbarAlignLeft"; Selected = $false },
    [pscustomobject]@{ Category = "交互与资源管理器"; Label = "隐藏任务栏搜索入口"; Argument = "-HideSearchTb"; Selected = $false },
    [pscustomobject]@{ Category = "交互与资源管理器"; Label = "隐藏任务视图按钮"; Argument = "-HideTaskview"; Selected = $false },
    [pscustomobject]@{ Category = "交互与资源管理器"; Label = "隐藏开始菜单推荐区域"; Argument = "-DisableStartRecommended"; Selected = $false },
    [pscustomobject]@{ Category = "交互与资源管理器"; Label = "禁用 Windows 小组件"; Argument = "-DisableWidgets"; Selected = $false }
)

$lblDebloatCategory = New-Object System.Windows.Forms.Label
$lblDebloatCategory.Location = New-Object System.Drawing.Point(10, 61)
$lblDebloatCategory.Size = New-Object System.Drawing.Size(66, 26)
$lblDebloatCategory.Text = "功能分类:"
[void]$tabDebloat.Controls.Add($lblDebloatCategory)

$cmbDebloatCategory = New-Object System.Windows.Forms.ComboBox
$cmbDebloatCategory.Location = New-Object System.Drawing.Point(78, 58)
$cmbDebloatCategory.Size = New-Object System.Drawing.Size(165, 26)
$cmbDebloatCategory.DropDownStyle = "DropDownList"
[void]$cmbDebloatCategory.Items.AddRange(@("全部", "应用清理", "隐私与推广", "AI 功能", "系统与更新", "交互与资源管理器"))
$cmbDebloatCategory.SelectedIndex = 0
[void]$tabDebloat.Controls.Add($cmbDebloatCategory)

$btnDebloatSelectCategory = New-Object System.Windows.Forms.Button
$btnDebloatSelectCategory.Location = New-Object System.Drawing.Point(252, 56)
$btnDebloatSelectCategory.Size = New-Object System.Drawing.Size(142, 29)
$btnDebloatSelectCategory.Text = "全选当前分类"
$btnDebloatSelectCategory.FlatStyle = "Flat"
[void]$tabDebloat.Controls.Add($btnDebloatSelectCategory)

$btnDebloatSelectAll = New-Object System.Windows.Forms.Button
$btnDebloatSelectAll.Location = New-Object System.Drawing.Point(402, 56)
$btnDebloatSelectAll.Size = New-Object System.Drawing.Size(132, 29)
$btnDebloatSelectAll.Text = "全选全部"
$btnDebloatSelectAll.FlatStyle = "Flat"
[void]$tabDebloat.Controls.Add($btnDebloatSelectAll)

$btnDebloatClear = New-Object System.Windows.Forms.Button
$btnDebloatClear.Location = New-Object System.Drawing.Point(542, 56)
$btnDebloatClear.Size = New-Object System.Drawing.Size(154, 29)
$btnDebloatClear.Text = "清空全部"
$btnDebloatClear.FlatStyle = "Flat"
[void]$tabDebloat.Controls.Add($btnDebloatClear)

$clbDebloat = New-Object System.Windows.Forms.CheckedListBox
$clbDebloat.Location = New-Object System.Drawing.Point(10, 92)
$clbDebloat.Size = New-Object System.Drawing.Size(686, 300)
$clbDebloat.CheckOnClick = $true
$clbDebloat.Font = New-Object System.Drawing.Font("Microsoft YaHei UI", 9)
[void]$tabDebloat.Controls.Add($clbDebloat)

$script:VisibleDebloatOptionIndices = @()
$refreshDebloatOptions = {
    $clbDebloat.Items.Clear()
    $script:VisibleDebloatOptionIndices = @()
    $category = [string]$cmbDebloatCategory.SelectedItem
    for ($optionIndex = 0; $optionIndex -lt $script:DebloatOptions.Count; $optionIndex++) {
        $option = $script:DebloatOptions[$optionIndex]
        if ($category -eq "全部" -or $option.Category -eq $category) {
            $script:VisibleDebloatOptionIndices += $optionIndex
            [void]$clbDebloat.Items.Add("[$($option.Category)] $($option.Label)", [bool]$option.Selected)
        }
    }
}

$clbDebloat.Add_ItemCheck({
    param($sender, $e)
    if ($e.Index -lt $script:VisibleDebloatOptionIndices.Count) {
        $optionIndex = $script:VisibleDebloatOptionIndices[$e.Index]
        $script:DebloatOptions[$optionIndex].Selected = ($e.NewValue -eq [System.Windows.Forms.CheckState]::Checked)
    }
})
$cmbDebloatCategory.Add_SelectedIndexChanged({ & $refreshDebloatOptions })
& $refreshDebloatOptions

$lblDebloatProgress = New-Object System.Windows.Forms.Label
$lblDebloatProgress.Location = New-Object System.Drawing.Point(10, 397)
$lblDebloatProgress.Size = New-Object System.Drawing.Size(686, 18)
$lblDebloatProgress.Text = "等待执行；卸载应用时会显示当前应用与总体进度。"
[void]$tabDebloat.Controls.Add($lblDebloatProgress)

$progressDebloat = New-Object System.Windows.Forms.ProgressBar
$progressDebloat.Location = New-Object System.Drawing.Point(10, 416)
$progressDebloat.Size = New-Object System.Drawing.Size(686, 16)
$progressDebloat.Minimum = 0
$progressDebloat.Maximum = 100
$progressDebloat.Value = 0
[void]$tabDebloat.Controls.Add($progressDebloat)

$btnDebloatApply = New-Object System.Windows.Forms.Button
$btnDebloatApply.Location = New-Object System.Drawing.Point(10, 443)
$btnDebloatApply.Size = New-Object System.Drawing.Size(225, 38)
$btnDebloatApply.Text = "▶ 执行勾选项目"
$btnDebloatApply.BackColor = [System.Drawing.Color]::FromArgb(41, 128, 185)
$btnDebloatApply.ForeColor = [System.Drawing.Color]::White
$btnDebloatApply.FlatStyle = "Flat"
$btnDebloatApply.Font = New-Object System.Drawing.Font("Microsoft YaHei UI", 9, [System.Drawing.FontStyle]::Bold)
[void]$tabDebloat.Controls.Add($btnDebloatApply)

$btnDebloatRecommended = New-Object System.Windows.Forms.Button
$btnDebloatRecommended.Location = New-Object System.Drawing.Point(245, 443)
$btnDebloatRecommended.Size = New-Object System.Drawing.Size(225, 38)
$btnDebloatRecommended.Text = "✨ 执行轻量推荐方案"
$btnDebloatRecommended.FlatStyle = "Flat"
[void]$tabDebloat.Controls.Add($btnDebloatRecommended)

$btnDebloatAppList = New-Object System.Windows.Forms.Button
$btnDebloatAppList.Location = New-Object System.Drawing.Point(480, 443)
$btnDebloatAppList.Size = New-Object System.Drawing.Size(216, 38)
$btnDebloatAppList.Text = "📋 选择要卸载的应用"
$btnDebloatAppList.FlatStyle = "Flat"
[void]$tabDebloat.Controls.Add($btnDebloatAppList)

$btnDebloatApply.Add_Click({
    $selectedOptions = @($script:DebloatOptions | Where-Object Selected)
    if ($selectedOptions.Count -eq 0) {
        Write-Log "[系统精简] 请至少勾选一个项目。" "#e67e22"
        return
    }
    if (($selectedOptions.Argument -contains "-RemoveApps") -and $script:SelectedDebloatAppIds.Count -eq 0) {
        Write-Log "[系统精简] 已勾选应用卸载，但尚未选择应用。请先点击「选择要卸载的应用」。" "#e67e22"
        return
    }
    $confirm = [System.Windows.Forms.MessageBox]::Show(
        "即将修改系统设置。若勾选了应用卸载，相关预装应用会从当前系统移除。`n`n是否继续？",
        "确认执行系统精简",
        [System.Windows.Forms.MessageBoxButtons]::YesNo,
        [System.Windows.Forms.MessageBoxIcon]::Warning
    )
    if ($confirm -ne [System.Windows.Forms.DialogResult]::Yes) { return }

    $arguments = @()
    foreach ($option in $selectedOptions) {
        if ($option.Argument) { $arguments += $option.Argument }
        if ($option.Arguments) { $arguments += $option.Arguments }
    }
    Start-Win11Debloat -Arguments $arguments
})

$btnDebloatRecommended.Add_Click({
    $confirm = [System.Windows.Forms.MessageBox]::Show(
        "轻量推荐方案会关闭常见遥测与推广内容，并应用安全的界面清理设置。`n`n是否继续？",
        "确认执行轻量推荐方案",
        [System.Windows.Forms.MessageBoxButtons]::YesNo,
        [System.Windows.Forms.MessageBoxIcon]::Question
    )
    if ($confirm -eq [System.Windows.Forms.DialogResult]::Yes) {
        Start-Win11Debloat -Arguments @("-RunDefaultsLite")
    }
})

$btnDebloatAppList.Add_Click({
    try {
        $debloatScript = Resolve-Win11DebloatScript
        $appsJson = Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path (Split-Path -Parent $debloatScript) "Config\Apps.json") | ConvertFrom-Json
        $catalog = @($appsJson.Apps)
        $gamingPresetIds = @((@($appsJson.Presets) | Where-Object Name -eq "Xbox gaming apps" | Select-Object -First 1).AppIds)
        $oemPresetIds = @((@($appsJson.Presets) | Where-Object Name -eq "OEM software (Dell, HP, Lenovo, LG)" | Select-Object -First 1).AppIds)
        if ($script:SelectedDebloatAppIds.Count -eq 0) {
            $script:SelectedDebloatAppIds = @($catalog | Where-Object SelectedByDefault | ForEach-Object { @($_.AppId) })
        }
        $selectedSet = New-Object System.Collections.Generic.HashSet[string]
        foreach ($appId in $script:SelectedDebloatAppIds) { [void]$selectedSet.Add([string]$appId) }

        $listForm = New-Object System.Windows.Forms.Form
        $listForm.Text = "选择要卸载的 Windows 应用"
        $listForm.Size = New-Object System.Drawing.Size(940, 680)
        $listForm.StartPosition = "CenterParent"
        $listForm.Font = New-Object System.Drawing.Font("Microsoft YaHei UI", 9)
        $listForm.MinimizeBox = $false

        $listInfo = New-Object System.Windows.Forms.Label
        $listInfo.Dock = "Top"
        $listInfo.Height = 48
        $listInfo.Padding = New-Object System.Windows.Forms.Padding(8)
        $listInfo.Text = "逐项选择需要卸载的应用。蓝色默认清理项已预选；标记为「谨慎保留」的系统/常用组件默认不选。实际执行时只处理本机存在的应用。"
        [void]$listForm.Controls.Add($listInfo)

        $appFilterPanel = New-Object System.Windows.Forms.FlowLayoutPanel
        $appFilterPanel.Dock = "Top"
        $appFilterPanel.Height = 42
        $appFilterPanel.Padding = New-Object System.Windows.Forms.Padding(6, 5, 6, 3)
        $appFilterPanel.WrapContents = $false
        [void]$listForm.Controls.Add($appFilterPanel)

        $lblAppCategory = New-Object System.Windows.Forms.Label
        $lblAppCategory.Size = New-Object System.Drawing.Size(68, 28)
        $lblAppCategory.Text = "上游筛选:"
        $lblAppCategory.TextAlign = "MiddleLeft"
        [void]$appFilterPanel.Controls.Add($lblAppCategory)

        $cmbAppCategory = New-Object System.Windows.Forms.ComboBox
        $cmbAppCategory.Size = New-Object System.Drawing.Size(150, 28)
        $cmbAppCategory.DropDownStyle = "DropDownList"
        [void]$cmbAppCategory.Items.AddRange(@("全部", "上游默认清理", "推荐安全清理", "可选应用", "谨慎保留", "Xbox 游戏预设", "OEM 软件预设"))
        $cmbAppCategory.SelectedIndex = 0
        [void]$appFilterPanel.Controls.Add($cmbAppCategory)

        $btnAppSelectNonSystem = New-Object System.Windows.Forms.Button
        $btnAppSelectNonSystem.Size = New-Object System.Drawing.Size(205, 29)
        $btnAppSelectNonSystem.Text = "选择除谨慎保留外全部应用"
        [void]$appFilterPanel.Controls.Add($btnAppSelectNonSystem)

        $btnAppSelectCategory = New-Object System.Windows.Forms.Button
        $btnAppSelectCategory.Size = New-Object System.Drawing.Size(145, 29)
        $btnAppSelectCategory.Text = "全选当前分类"
        [void]$appFilterPanel.Controls.Add($btnAppSelectCategory)

        $listButtons = New-Object System.Windows.Forms.FlowLayoutPanel
        $listButtons.Dock = "Bottom"
        $listButtons.Height = 48
        $listButtons.FlowDirection = "RightToLeft"
        $listButtons.Padding = New-Object System.Windows.Forms.Padding(6)
        [void]$listForm.Controls.Add($listButtons)

        $btnAppConfirm = New-Object System.Windows.Forms.Button
        $btnAppConfirm.Size = New-Object System.Drawing.Size(120, 32)
        $btnAppConfirm.Text = "确定选择"
        $btnAppConfirm.DialogResult = [System.Windows.Forms.DialogResult]::OK
        [void]$listButtons.Controls.Add($btnAppConfirm)

        $btnAppCancel = New-Object System.Windows.Forms.Button
        $btnAppCancel.Size = New-Object System.Drawing.Size(100, 32)
        $btnAppCancel.Text = "取消"
        $btnAppCancel.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
        [void]$listButtons.Controls.Add($btnAppCancel)

        $btnAppClear = New-Object System.Windows.Forms.Button
        $btnAppClear.Size = New-Object System.Drawing.Size(100, 32)
        $btnAppClear.Text = "全部取消"
        [void]$listButtons.Controls.Add($btnAppClear)

        $btnAppDefaults = New-Object System.Windows.Forms.Button
        $btnAppDefaults.Size = New-Object System.Drawing.Size(130, 32)
        $btnAppDefaults.Text = "恢复默认选择"
        [void]$listButtons.Controls.Add($btnAppDefaults)

        $appGrid = New-Object System.Windows.Forms.DataGridView
        $appGrid.Dock = "Fill"
        $appGrid.ReadOnly = $false
        $appGrid.AllowUserToAddRows = $false
        $appGrid.RowHeadersVisible = $false
        $appGrid.SelectionMode = "FullRowSelect"
        $appGrid.AutoSizeColumnsMode = "Fill"
        $appGrid.BackgroundColor = [System.Drawing.Color]::White
        $table = New-Object System.Data.DataTable
        [void]$table.Columns.Add("选择", [bool])
        [void]$table.Columns.Add("上游建议")
        [void]$table.Columns.Add("应用名称")
        [void]$table.Columns.Add("中文说明")
        [void]$table.Columns.Add("应用标识")
        [void]$table.Columns.Add("卸载方式")
        [void]$table.Columns.Add("默认选择", [bool])
        [void]$table.Columns.Add("推荐级别")
        [void]$table.Columns.Add("Xbox预设", [bool])
        [void]$table.Columns.Add("OEM预设", [bool])
        foreach ($app in $catalog) {
            $appIds = @($app.AppId)
            $isSelected = @($appIds | Where-Object { $selectedSet.Contains([string]$_) }).Count -gt 0
            $isGamingPreset = @($appIds | Where-Object { $gamingPresetIds -contains $_ }).Count -gt 0
            $isOemPreset = @($appIds | Where-Object { $oemPresetIds -contains $_ }).Count -gt 0
            [void]$table.Rows.Add(
                $isSelected,
                (Get-AppRecommendationCN $app),
                $app.FriendlyName,
                (Get-AppDescriptionCN $app),
                ($appIds -join ", "),
                $app.RemovalMethod,
                [bool]$app.SelectedByDefault,
                [string]$app.Recommendation,
                $isGamingPreset,
                $isOemPreset
            )
        }
        $appGrid.DataSource = $table
        $appGrid.Add_DataBindingComplete({
            foreach ($column in $appGrid.Columns) { $column.ReadOnly = ($column.Name -ne "选择") }
            foreach ($metadataColumn in @("默认选择", "推荐级别", "Xbox预设", "OEM预设")) {
                if ($appGrid.Columns[$metadataColumn]) { $appGrid.Columns[$metadataColumn].Visible = $false }
            }
        })
        [void]$listForm.Controls.Add($appGrid)
        $listInfo.BringToFront()

        $btnAppClear.Add_Click({
            foreach ($row in $table.Rows) { $row["选择"] = $false }
        })
        $btnAppDefaults.Add_Click({
            for ($rowIndex = 0; $rowIndex -lt $table.Rows.Count; $rowIndex++) {
                $table.Rows[$rowIndex]["选择"] = [bool]$catalog[$rowIndex].SelectedByDefault
            }
        })
        $cmbAppCategory.Add_SelectedIndexChanged({
            $selectedCategory = [string]$cmbAppCategory.SelectedItem
            $table.DefaultView.RowFilter = switch ($selectedCategory) {
                "上游默认清理" { "[默认选择] = true" }
                "推荐安全清理" { "[推荐级别] = 'safe'" }
                "可选应用" { "[推荐级别] = 'optional'" }
                "谨慎保留" { "[推荐级别] = 'unsafe'" }
                "Xbox 游戏预设" { "[Xbox预设] = true" }
                "OEM 软件预设" { "[OEM预设] = true" }
                default { "" }
            }
        })
        $btnAppSelectNonSystem.Add_Click({
            foreach ($row in $table.Rows) { $row["选择"] = ([string]$row["推荐级别"] -ne "unsafe") }
        })
        $btnAppSelectCategory.Add_Click({
            foreach ($viewRow in $table.DefaultView) { $viewRow["选择"] = $true }
        })

        $dialogResult = $listForm.ShowDialog($form)
        if ($dialogResult -eq [System.Windows.Forms.DialogResult]::OK) {
            $appGrid.EndEdit()
            $chosenIds = New-Object System.Collections.Generic.HashSet[string]
            foreach ($row in $table.Rows) {
                if ([bool]$row["选择"]) {
                    foreach ($appId in ([string]$row["应用标识"] -split ',')) {
                        if (-not [string]::IsNullOrWhiteSpace($appId)) { [void]$chosenIds.Add($appId.Trim()) }
                    }
                }
            }
            $script:SelectedDebloatAppIds = @($chosenIds)
            $btnDebloatAppList.Text = "📋 已选择 $($script:SelectedDebloatAppIds.Count) 个应用"
            Write-Log "[应用选择] 已选择 $($script:SelectedDebloatAppIds.Count) 个应用卸载标识。" "#2980b9"
        }
        $listForm.Dispose()
    } catch {
        Write-Log "[应用清单❌] 无法读取卸载清单：$($_.Exception.Message)" "#e74c3c"
    }
})

$btnDebloatSelectCategory.Add_Click({
    foreach ($optionIndex in $script:VisibleDebloatOptionIndices) { $script:DebloatOptions[$optionIndex].Selected = $true }
    & $refreshDebloatOptions
})

$btnDebloatSelectAll.Add_Click({
    foreach ($option in $script:DebloatOptions) { $option.Selected = $true }
    & $refreshDebloatOptions
})

$btnDebloatClear.Add_Click({
    foreach ($option in $script:DebloatOptions) { $option.Selected = $false }
    & $refreshDebloatOptions
})

$script:Win11DebloatTimer = New-Object System.Windows.Forms.Timer
$script:Win11DebloatTimer.Interval = 1000
$script:Win11DebloatTimer.Add_Tick({
    if ($script:Win11DebloatLogFile -and (Test-Path -LiteralPath $script:Win11DebloatLogFile)) {
        $logLines = @(Get-Content -Encoding UTF8 -LiteralPath $script:Win11DebloatLogFile -ErrorAction SilentlyContinue)
        if ($logLines.Count -gt $script:Win11DebloatLogLineCount) {
            $newLines = @($logLines | Select-Object -Skip $script:Win11DebloatLogLineCount)
            $script:Win11DebloatLogLineCount = $logLines.Count
            foreach ($logLine in $newLines) {
                if ($logLine -match '^Removing\s+(.+)$') {
                    $appId = $matches[1].Trim()
                    $script:Win11DebloatRemovalCurrent++
                    $friendlyName = if ($script:Win11DebloatAppNames.ContainsKey($appId)) { $script:Win11DebloatAppNames[$appId] } else { $appId }
                    if ($script:Win11DebloatRemovalTotal -gt 0) {
                        $progressDebloat.Value = [Math]::Min($script:Win11DebloatRemovalCurrent, $progressDebloat.Maximum)
                        $lblDebloatProgress.Text = "卸载进度：$($script:Win11DebloatRemovalCurrent) / $($script:Win11DebloatRemovalTotal) — $friendlyName"
                        Write-Log "[卸载进度] $($script:Win11DebloatRemovalCurrent)/$($script:Win11DebloatRemovalTotal) 正在处理：$friendlyName ($appId)" "#2980b9"
                    }
                } elseif ($logLine -match '^Unable to uninstall\s+(.+)$') {
                    Write-Log "[应用卸载⚠] 未能卸载：$($matches[1])" "#e67e22"
                } elseif ($logLine -match '^>\s+(.+?)(?:\.\.\.)?$') {
                    $featureMessage = $matches[1].Trim()
                    $featureMessage = $featureMessage `
                        -replace '^Disabling\s+', '正在禁用：' `
                        -replace '^Enabling\s+', '正在启用：' `
                        -replace '^Hiding\s+', '正在隐藏：' `
                        -replace '^Showing\s+', '正在显示：' `
                        -replace '^Setting\s+', '正在设置：' `
                        -replace '^Restoring\s+', '正在恢复：' `
                        -replace '^Creating\s+', '正在创建：' `
                        -replace '^Applying\s+', '正在应用：' `
                        -replace '^Clearing\s+', '正在清理：' `
                        -replace '^Preventing\s+', '正在阻止：' `
                        -replace '^Removing\s+', '正在移除：'
                    $lblDebloatProgress.Text = $featureMessage
                    Write-Log "[功能进度] $featureMessage" "#8e44ad"
                } elseif ($logLine -match '^(Disabled|Enabled|Successfully|Failed|Imported|Applied|Removed)\b') {
                    Write-Log "[功能结果] $logLine" "#7f8c8d"
                }
            }
        }
    }

    if ($script:Win11DebloatProcess -and $script:Win11DebloatProcess.HasExited) {
        $exitCode = $script:Win11DebloatProcess.ExitCode
        $progressDebloat.Style = [System.Windows.Forms.ProgressBarStyle]::Continuous
        $progressDebloat.Minimum = 0
        $progressDebloat.Maximum = 100
        $progressDebloat.Value = if ($exitCode -eq 0) { 100 } else { 0 }
        if ($exitCode -eq 0) {
            $lblDebloatProgress.Text = "执行完成。"
            Write-Log "[系统精简✅] Win11Debloat 已执行完成。部分界面设置可能需要重启资源管理器或注销后生效。" "#27ae60"
        } else {
            $lblDebloatProgress.Text = "执行失败，退出代码：$exitCode"
            Write-Log "[系统精简❌] Win11Debloat 执行失败，退出代码：$exitCode。" "#e74c3c"
        }
        $script:Win11DebloatProcess.Dispose()
        $script:Win11DebloatProcess = $null
        $script:Win11DebloatTimer.Stop()
    }
})

# =========================================================================
#                       下方共用日志与控制台区域
# =========================================================================

$logPanel = New-Object System.Windows.Forms.Panel
$logPanel.Dock = "Bottom"
$logPanel.Height = 230
[void]$mainContainer.Controls.Add($logPanel)

$lblLogTitle = New-Object System.Windows.Forms.Label
$lblLogTitle.Location = New-Object System.Drawing.Point(5, 5)
$lblLogTitle.Size = New-Object System.Drawing.Size(200, 24)
$lblLogTitle.Text = "📋 实时控制日志与状态反馈:"
$lblLogTitle.Font = New-Object System.Drawing.Font("Microsoft YaHei UI", 9, [System.Drawing.FontStyle]::Bold)
[void]$logPanel.Controls.Add($lblLogTitle)

$btnClearLog = New-Object System.Windows.Forms.Button
$btnClearLog.Location = New-Object System.Drawing.Point(575, 2)
$btnClearLog.Size = New-Object System.Drawing.Size(120, 26)
$btnClearLog.Text = "🗑 清空日志"
$btnClearLog.FlatStyle = "Flat"
$btnClearLog.Add_Click({ $txtLog.Clear() })
[void]$logPanel.Controls.Add($btnClearLog)

$txtLog = New-Object System.Windows.Forms.RichTextBox
$txtLog.Location = New-Object System.Drawing.Point(5, 32)
$txtLog.Size = New-Object System.Drawing.Size(696, 190)
$txtLog.ReadOnly = $true
$txtLog.BackColor = [System.Drawing.Color]::White
$txtLog.ForeColor = [System.Drawing.Color]::Black
$txtLog.Font = New-Object System.Drawing.Font("Consolas", 8.5)
$txtLog.ScrollBars = "Vertical"
[void]$logPanel.Controls.Add($txtLog)

# ===== 窗体初次加载事件 =====
$form.add_Load({
    & $refreshProcAction
    & $refreshSvcAction
    Write-Log "高阶性能优化器精细控制版已启动，以管理员权限运行 ✅" "#27ae60"
    Write-Log "提示：在标签页之间切换，可分别进行【进程绑核监控】与【系统服务单项开关控制】" "#2980b9"
    Write-Log "⚡ 后台智能连续守护已启动：每 3 秒自动巡检，无论是窗口展示还是点击 X 最小化至托盘后台，均实时自动重绑 PID 亲和性与优先级！" "#e67e22"
})

$bgDaemonTimer = New-Object System.Windows.Forms.Timer
$bgDaemonTimer.Interval = 3000
$bgDaemonTimer.add_Tick({
    Invoke-BackgroundAutoLock
})
$bgDaemonTimer.Start()

[void][System.Windows.Forms.Application]::Run($form)
$bgDaemonTimer.Stop()
$bgDaemonTimer.Dispose()
$script:Win11DebloatTimer.Stop()
$script:Win11DebloatTimer.Dispose()
$notifyIcon.Dispose()
