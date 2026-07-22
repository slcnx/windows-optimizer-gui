Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

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

function Write-Log {
    param([string]$msg, [string]$color = "#000000")
    $ts = Get-Date -Format "HH:mm:ss"
    $line = "[$ts] $msg"
    Add-Content -Path $logFile -Value $line -Encoding UTF8
    if ($txtLog -and $txtLog.IsHandleCreated) {
        $txtLog.Invoke([Action]{
            $txtLog.SelectionStart = $txtLog.TextLength
            $txtLog.SelectionLength = 0
            $txtLog.SelectionColor = [System.Drawing.ColorTranslator]::FromHtml($color)
            $txtLog.AppendText("$line`r`n")
            $txtLog.ScrollToCaret()
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

$form.add_FormClosing({
    param($sender, $e)
    if (-not $script:isExplicitExit -and $e.CloseReason -eq [System.Windows.Forms.CloseReason]::UserClosing) {
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

[void]$form.ShowDialog()
$bgDaemonTimer.Stop()
$bgDaemonTimer.Dispose()
$notifyIcon.Dispose()
