function ConvertTo-Win11DebloatChineseText {
    param([AllowNull()][string]$Text, [switch]$FallbackDescription, [string]$FallbackName)
    if ([string]::IsNullOrWhiteSpace($Text)) { return $Text }

    $exact = @{
        'Privacy & Suggested Content'='隐私与推荐内容'; 'System'='系统'; 'Start Menu & Search'='开始菜单与搜索'; 'AI'='人工智能'
        'Windows Update'='Windows 更新'; 'Taskbar'='任务栏'; 'Appearance'='外观'; 'File Explorer'='文件资源管理器'
        'Gaming'='游戏'; 'Multi-tasking'='多任务处理'; 'Optional Windows Features'='Windows 可选功能'; 'Other'='其他'
        'Xbox gaming apps'='Xbox 游戏应用'; 'OEM software (Dell, HP, Lenovo, LG)'='OEM 厂商软件（Dell、HP、Lenovo、LG）'
    }
    if ($exact.ContainsKey($Text)) { return $exact[$Text] }

    $translated = $Text
    $rules = [ordered]@{
        'Forcefully uninstall Microsoft Edge\. NOT RECOMMENDED!'='强制卸载 Microsoft Edge（不推荐）'
        'Disable telemetry, tracking & targeted ads'='禁用遥测、跟踪和定向广告'; 'Enable telemetry, tracking & targeted ads'='启用遥测、跟踪和定向广告'
        'Disable tips, tricks & suggested content throughout Windows'='禁用 Windows 中的提示、技巧和推荐内容'
        'Enable tips, tricks & suggested content throughout Windows'='启用 Windows 中的提示、技巧和推荐内容'
        'Create a system restore point'='创建系统还原点'; 'Remove the Xbox App and Xbox Gamebar'='卸载 Xbox 应用和 Xbox Game Bar'
        'Remove HP OEM applications'='卸载 HP OEM 应用'; 'Windows Subsystem for Linux'='适用于 Linux 的 Windows 子系统'
        'File Explorer'='文件资源管理器'; 'Windows Explorer'='Windows 资源管理器'; 'start menu'='开始菜单'
        'taskbar'='任务栏'; 'lock screen'='锁屏'; 'context menu'='右键菜单'; 'navigation pane'='导航窗格'
        'search box'='搜索框'; 'search icon'='搜索图标'; 'drive letters'='驱动器号'; 'drive label'='驱动器标签'
        'Disable '='禁用'; 'Enable '='启用'; 'Hide '='隐藏'; 'Show '='显示'; 'Remove '='移除'; 'Add '='添加'
        'Prevent '='阻止'; 'Allow '='允许'; 'Use '='使用'; 'Open '='打开'; 'Change '='更改'; 'Replace '='替换'
        'Disabling '='正在禁用'; 'Enabling '='正在启用'; 'Removing '='正在移除'; 'Creating '='正在创建'
        'Hiding '='正在隐藏'; 'Showing '='正在显示'; 'Setting '='正在设置'; 'Adding '='正在添加'
        'automatic'='自动'; 'notifications'='通知'; 'suggestions'='推荐'; 'location services'='定位服务'; 'location tracking'='位置跟踪'
        'desktop'='桌面'; 'apps'='应用'; 'features'='功能'; 'recommended'='推荐'
        'Default'='默认'; 'Always'='始终'; 'Never'='从不'; 'This PC'='此电脑'; 'Downloads'='下载'; 'Home'='主页'; 'All Apps'='所有应用'
    }
    foreach ($entry in $rules.GetEnumerator()) { $translated = $translated -replace $entry.Key, $entry.Value }
    if ($FallbackDescription -and $translated -eq $Text) {
        if ([string]::IsNullOrWhiteSpace($FallbackName)) { return 'Windows 应用或组件' }
        return "$FallbackName 对应的 Windows 应用或组件"
    }
    return $translated
}

function Initialize-Win11DebloatChineseLocalization {
    param(
        [Parameter(Mandatory)][string]$SchemasPath,
        [Parameter(Mandatory)][string]$ConfigPath
    )
    $localizedRoot = Join-Path $env:LOCALAPPDATA "WindowsOptimizerGUI\Win11DebloatLocalization\$($script:Version)"
    $localizedSchemas = Join-Path $localizedRoot 'Schemas'
    New-Item -ItemType Directory -Path $localizedSchemas -Force | Out-Null
    $xamlMap = [ordered]@{
        'Win11Debloat Application Selection'='Win11Debloat 应用选择'; 'Application Removal'='应用卸载'; 'System Tweaks'='系统调整'
        'Deployment Settings'='应用设置'; 'Select the apps you want to remove'='选择要卸载的应用'
        'Select what changes you want to make, you can hover over settings for more information'='选择要应用的系统调整；将鼠标悬停在选项上可查看详细说明'
        'Configure how the selected changes will be applied to your system'='配置所选更改如何应用到系统'
        'Check apps that you wish to remove, uncheck apps that you wish to keep'='勾选要卸载的应用，取消勾选要保留的应用'
        'Check/Uncheck all'='全选/取消全选'; 'Only show installed apps'='仅显示已安装应用'; 'Loading apps...'='正在加载应用…'
        'Search apps...'='搜索应用…'; 'Search tweaks...'='搜索系统调整…'; 'Name'='名称'; 'Description'='说明'; 'Legend:'='标记：'
        'Recommended'='推荐'; 'Optional'='可选'; 'Not Recommended'='不推荐'; 'Quick Select'='快速选择'; 'Clear Selection'='清空选择'
        'Default settings'='默认推荐设置'; 'Previously selected settings'='上次选择的设置'; 'Privacy &amp; suggested content'='隐私与推荐内容'
        'AI features'='AI 功能'; 'Detect applied tweaks'='检测已应用的调整'; 'Changes will be applied to'='更改将应用到'
        'The currently logged-in user profile.'='当前登录的用户配置文件。'; 'Apps will be removed for'='应用卸载范围'
        'All users'='所有用户'; 'Current user only'='仅当前用户'; 'Target user only'='仅指定用户'; 'Options'='选项'
        'Create a system restore point (Recommended)'='创建系统还原点（推荐）'
        'Restart the Windows Explorer process to apply all changes immediately'='重启 Windows 资源管理器以立即应用所有更改'
        'Review selected changes'='查看所选更改'; 'Apply Changes'='应用更改'; 'Back'='上一步'; 'Next'='下一步'; 'App Removal'='应用卸载'
        'Confirm'='确认'; 'Cancel'='取消'; 'Close'='关闭'; 'Applying Changes'='正在应用更改'; 'Preparing...'='正在准备…'
        'Changes Applied'='更改已应用'; 'Support the creator'='支持原作者'; 'About Win11Debloat'='关于 Win11Debloat'
        'Version:'='版本：'; 'Author:'='作者：'; 'Project:'='项目：'; 'Restore Backup'='恢复备份'
        'Restore Registry Backup'='恢复注册表备份'; 'Restore Start Menu Backup'='恢复开始菜单备份'
        'Choose what changes you want to restore.'='选择要恢复的更改。'; 'View the selected changes here'='在此查看所选更改'
    }
    Get-ChildItem -LiteralPath $SchemasPath -Filter '*.xaml' -File | ForEach-Object {
        $content = Get-Content -LiteralPath $_.FullName -Raw -Encoding UTF8
        foreach ($entry in $xamlMap.GetEnumerator()) {
            $content = $content.Replace(('="{0}"' -f $entry.Key), ('="{0}"' -f $entry.Value))
        }
        [System.IO.File]::WriteAllText((Join-Path $localizedSchemas $_.Name), $content, (New-Object System.Text.UTF8Encoding($true)))
    }

    $features = Get-Content -LiteralPath (Join-Path $ConfigPath 'Features.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    foreach ($category in $features.Categories) { $category.Name = ConvertTo-Win11DebloatChineseText $category.Name }
    foreach ($group in $features.UiGroups) {
        $group.Label = ConvertTo-Win11DebloatChineseText $group.Label
        $group.ToolTip = ConvertTo-Win11DebloatChineseText $group.ToolTip
        $group.Category = ConvertTo-Win11DebloatChineseText $group.Category
        foreach ($value in $group.Values) { $value.Label = ConvertTo-Win11DebloatChineseText $value.Label }
    }
    foreach ($feature in $features.Features) {
        $feature.Label = ConvertTo-Win11DebloatChineseText $feature.Label
        $feature.UndoLabel = ConvertTo-Win11DebloatChineseText $feature.UndoLabel
        $feature.ApplyText = ConvertTo-Win11DebloatChineseText $feature.ApplyText
        $feature.ApplyUndoText = ConvertTo-Win11DebloatChineseText $feature.ApplyUndoText
        if ($feature.PSObject.Properties['ToolTip']) { $feature.ToolTip = ConvertTo-Win11DebloatChineseText $feature.ToolTip }
        $feature.Category = ConvertTo-Win11DebloatChineseText $feature.Category
    }
    $localizedFeaturesPath = Join-Path $localizedRoot 'Features.zh-CN.json'
    [System.IO.File]::WriteAllText($localizedFeaturesPath, ($features | ConvertTo-Json -Depth 20), (New-Object System.Text.UTF8Encoding($true)))
    $script:FeaturesFilePath = $localizedFeaturesPath

    $script:AppSelectionSchema=Join-Path $localizedSchemas 'AppSelectionWindow.xaml'; $script:MainWindowSchema=Join-Path $localizedSchemas 'MainWindow.xaml'
    $script:MessageBoxSchema=Join-Path $localizedSchemas 'MessageBox.xaml'; $script:AboutWindowSchema=Join-Path $localizedSchemas 'AboutWindow.xaml'
    $script:ApplyChangesWindowSchema=Join-Path $localizedSchemas 'ApplyChangesWindow.xaml'; $script:SharedStylesSchema=Join-Path $localizedSchemas 'SharedStyles.xaml'
    $script:BubbleHintSchema=Join-Path $localizedSchemas 'BubbleHint.xaml'; $script:ImportExportConfigSchema=Join-Path $localizedSchemas 'ImportExportConfigWindow.xaml'
    $script:RestoreBackupWindowSchema=Join-Path $localizedSchemas 'RestoreBackupWindow.xaml'
}
