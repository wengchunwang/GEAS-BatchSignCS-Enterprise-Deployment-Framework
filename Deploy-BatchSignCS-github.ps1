<#
===============================================================================
 GEAS - BatchSignCS Enterprise Deployment Framework
 Version : 2026.05.13 Enterprise Stable
 Purpose :
    - GPO Startup 自動部署 / 移除 三代簽章元件
    - 自動安裝 VC++ x64 / x86 Runtime
    - 支援 NAS / NETLOGON 備援
    - 防止重複執行
    - 集中式日誌
    - Registry 安裝旗標
    - 白名單控制
    - 企業級穩定版

 Recommended GPO:
    Computer Configuration
      └ Policies
         └ Windows Settings
            └ Scripts (Startup)

 Required GPO:
    Always wait for the network at computer startup and logon = Enabled

===============================================================================
#>

[CmdletBinding()]
param(
    [ValidateSet("Install","Uninstall","DryRun")]
    [string]$Mode = "Install",
    [string]$GPOName = "GEAS",
    [string]$LogRoot = "\\NAS\LogFiles"
)

#==============================================================================
# 基本設定
#==============================================================================
$IsDryRun = ($Mode -eq "DryRun")
#$ErrorActionPreference = "SilentlyContinue"
$ErrorActionPreference = "Continue"
$ScriptVersion = "2026.05.13（Enterprise Stable v1.0）"
$Computer      = $env:COMPUTERNAME
$TimeStamp     = Get-Date -Format "yyyyMMdd"
$StartTime     = Get-Date

$KeepDays      = 30

$TempDir = "D:\Temp"

if (-not (Test-Path "D:\")) {
    $TempDir = "$env:SystemRoot\Temp"
}

$LocalLogFile = Join-Path $TempDir "GEAS_$TimeStamp.log"

$LogDir  = Join-Path $LogRoot "GEAS"
$LogFile = Join-Path $LogDir "$Computer`_$TimeStamp.log"

$RegistryRoot = "HKLM:\SOFTWARE\Company\GEAS"
$RegistryName = "BatchSignCS"

$RequiredVersion = "3.146.0"

$BatchSignProductCode = "{80070900-FB4D-44B3-A898-AA984722FB63}"

#==============================================================================
# 安裝來源
#==============================================================================

$VcX64Sources = @(
    "\\FileServer\Software\vc_redist.x64.exe",
    "\\ad.corp.example.com\netlogon\vc_redist.x64.exe"
)

$VcX86Sources = @(
    "\\FileServer\Software\vc_redist.x86.exe",
    "\\ad.corp.example.com\netlogon\vc_redist.x86.exe"
)

$BatchSignSources = @(
    "\\FileServer\Software\BatchSignCS.msi",
    "\\ad.corp.example.com\netlogon\BatchSignCS.msi"
)

#==============================================================================
# 安裝路徑
#==============================================================================

$BatchSignPath = "C:\Program Files (x86)\WellChoose\BatchSignCS"

$BatchSignExe1 = Join-Path $BatchSignPath "BatchSignCS.exe"
$BatchSignExe2 = Join-Path $BatchSignPath "BatchSignCSLauncher.exe"

#==============================================================================
# 白名單
#==============================================================================

$AllowedComputers = @(
    "PC001",
    "PC002",
	"PC003",
	"PC004"
)

#==============================================================================
# Mutex 防止重複執行
#==============================================================================

$MutexName = "Global\GEAS_BatchSignCS_Deploy"

try {
    $Mutex = New-Object System.Threading.Mutex($false, $MutexName)

    if (-not $Mutex.WaitOne(0, $false)) {
        exit 0
    }
}
catch {
    exit 0
}

#==============================================================================
# 白名單模式控制
#==============================================================================

if ($AllowedComputers -contains $Computer) {
    $EnableNASLog = $true
}
else {
    $EnableNASLog = $false
    $Mode = "Uninstall"
}

#==============================================================================
# 共用函式
#==============================================================================

function Ensure-Folder {
    param([string]$Path)

    if (-not (Test-Path $Path)) {
        New-Item -ItemType Directory -Path $Path -Force | Out-Null
    }
}

function Write-Log {
    param([string]$Msg)

    try {
        $time = Get-Date -Format "yyyy/MM/dd HH:mm:ss"

        $line = "[{0}] {1}" -f $time, $Msg

        #--------------------------------------------------------------------------
        # Local Log（永遠寫）
        #--------------------------------------------------------------------------

        Ensure-Folder $TempDir

        Add-Content `
            -Path $LocalLogFile `
            -Value $line `
            -Encoding UTF8

        #--------------------------------------------------------------------------
        # NAS Log（白名單才寫）
        #--------------------------------------------------------------------------

        if ($EnableNASLog) {
            Ensure-Folder $LogDir

            Add-Content `
                -Path $LogFile `
                -Value $line `
                -Encoding UTF8
        }
    }
    catch {
    }
}

function Clean-Logs {
    param(
        [string]$TargetDir,
        [int]$Days,
        [string]$Filter = "*.log"
    )

    if (-not (Test-Path $TargetDir)) {
        return
    }

    try {
        Get-ChildItem `
            -Path $TargetDir `
            -Filter $Filter `
            -File |
        Where-Object {
            $_.LastWriteTime -lt (Get-Date).AddDays(-$Days)
        } |
        Remove-Item -Force
    }
    catch {
        Write-Log "清理舊檔失敗：$($_.Exception.Message)"
    }
}

function Copy-From-Sources {
    param(
        [string[]]$Sources,
        [string]$Destination
    )

	if ($IsDryRun) {
		Write-Log "[DryRun] 模擬複製：$Sources → $Destination"
		return $true
		}

    foreach ($src in $Sources) {
        try {
            if (-not (Test-Path $src)) {
                Write-Log "來源不存在：$src"
                continue
            }

            #--------------------------------------------------------------------------
            # HASH 比對
            #--------------------------------------------------------------------------

            if (Test-Path $Destination) {
                try {
                    $srcHash  = (Get-FileHash $src -Algorithm SHA256).Hash
                    $destHash = (Get-FileHash $Destination -Algorithm SHA256).Hash

                    if ($srcHash -eq $destHash) {
                        Write-Log "本機檔案已存在且 HASH 一致，略過複製：$Destination"

                        return $true
                    }
                    else {
                        Write-Log "HASH 不同，重新覆蓋：$Destination"
                    }
                }
                catch {
                    Write-Log "HASH 比對失敗，改用覆蓋模式"
                }
            }

            Copy-Item `
                -Path $src `
                -Destination $Destination `
                -Force

            Write-Log "成功複製：$src"

            return $true
        }
        catch {
            Write-Log "複製失敗：$src，錯誤：$($_.Exception.Message)"
        }
    }

    Write-Log "所有來源皆無法使用：$Destination"

    return $false
}

function Invoke-Process {
    param(
        [string]$FilePath,
        [string]$Arguments,
        [int]$Retry = 2
    )

    if ($IsDryRun) {
        Write-Log "[DryRun] 模擬執行：$FilePath $Arguments"
        return 0
    }

    for ($i = 1; $i -le $Retry; $i++) {
        try {
            Write-Log "執行：$FilePath $Arguments"

            $p = Start-Process `
                -FilePath $FilePath `
                -ArgumentList $Arguments `
                -Wait `
                -PassThru `
                -WindowStyle Hidden

            Write-Log "ExitCode=$($p.ExitCode)"

            return $p.ExitCode
        }
        catch {
            Write-Log "執行失敗：$($_.Exception.Message)"

            Start-Sleep -Seconds (Get-Random -Minimum 5 -Maximum 10)
        }
    }

    return 9999
}

#==============================================================================
# Registry 旗標
#==============================================================================

function Get-InstalledFlag {
	if ($IsDryRun) {
		Write-Log "[DryRun] 略過實際檢查"
		return
	}

    try {
        if (-not (Test-Path $RegistryRoot)) {
            return $false
        }

        $v = Get-ItemProperty $RegistryRoot

        if (
            $v.$RegistryName -eq 1 -and
            $v.Version -eq $RequiredVersion
        ) {

            return $true
        }
    }
    catch {
    }

    return $false
}

function Set-InstalledFlag {
if ($IsDryRun) {
    Write-Log "[DryRun] 模擬寫入 Registry 旗標"
    return
}

    try {
        if (-not (Test-Path $RegistryRoot)) {
            New-Item `
                -Path $RegistryRoot `
                -Force | Out-Null
        }

        Set-ItemProperty `
            -Path $RegistryRoot `
            -Name $RegistryName `
            -Value 1 `
            -Type DWord

        Set-ItemProperty `
            -Path $RegistryRoot `
            -Name "Version" `
            -Value $RequiredVersion

        Set-ItemProperty `
            -Path $RegistryRoot `
            -Name "InstallDate" `
            -Value (Get-Date -Format "yyyy-MM-dd HH:mm:ss")

        Write-Log "Registry 安裝旗標已寫入"
    }
    catch {
        Write-Log "寫入 Registry 旗標失敗"
    }
}

function Remove-InstalledFlag {
if ($IsDryRun) {
    Write-Log "[DryRun] 模擬移除 Registry 旗標"
    return
}

    try {
        if (Test-Path $RegistryRoot) {
            Remove-Item `
                -Path $RegistryRoot `
                -Recurse `
                -Force

            Write-Log "Registry 安裝旗標已移除"
        }
    }
    catch {
        Write-Log "移除 Registry 旗標失敗"
    }
}

#==============================================================================
# 安裝判斷
#==============================================================================

function Is-VCRedistX64Installed {

    $keys = @(
        "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*",
        "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*"
    )

    foreach ($k in $keys) {
        try {
            $apps = Get-ItemProperty $k
            foreach ($a in $apps) {
                if (
                    $a.DisplayName -match "Visual C\+\+" -and
                    $a.DisplayName -match "2015" -and
                    $a.DisplayName -match "2022" -and
                    $a.DisplayName -match "x64"
                ) {
                    return $true
                }
            }
        }
        catch {
        }
    }

    return $false
}

function Is-VCRedistX86Installed {
    $keys = @(
        "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*",
        "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*"
    )

    foreach ($k in $keys) {
        try {
            $apps = Get-ItemProperty $k

            foreach ($a in $apps) {
                if (
                    $a.DisplayName -match "Visual C\+\+" -and
                    $a.DisplayName -match "2015" -and
                    $a.DisplayName -match "2022" -and
                    $a.DisplayName -match "x86"
                ) {
                    return $true
                }
            }
        }
        catch {
        }
    }

    return $false
}

function Is-BatchSignInstalled {
    if (
        (Test-Path $BatchSignExe1) -and
        (Test-Path $BatchSignExe2)
    ) {

        return $true
    }

    return $false
}

#==============================================================================
# 移除功能
#==============================================================================

function Uninstall-BatchSignCS {
    Write-Log "開始移除 BatchSignCS"

    $processes = @(
        "BatchSignCS",
        "BatchSignCSLauncher"
    )

    foreach ($p in $processes) {
        try {
            Get-Process $p -ErrorAction SilentlyContinue |
                Stop-Process -Force

            Write-Log "已關閉程序：$p"
        }
        catch {
        }
    }

    Start-Sleep -Seconds (Get-Random -Minimum 5 -Maximum 10)

    $msiLog = Join-Path $TempDir "BatchSignCS_Uninstall.log"

    #--------------------------------------------------------------------------
    # passive 才能正常移除
    #--------------------------------------------------------------------------

    $args = "/x $BatchSignProductCode /passive /norestart /L*v `"$msiLog`""

    $exit = Invoke-Process `
        -FilePath "msiexec.exe" `
        -Arguments $args `
        -Retry 2

    Write-Log "Uninstall ExitCode=$exit"

    Start-Sleep -Seconds (Get-Random -Minimum 5 -Maximum 10)

    if (-not (Is-BatchSignInstalled)) {
        Write-Log "BatchSignCS 移除成功"

        Remove-InstalledFlag

        try {
            if (Test-Path $BatchSignPath) {

                Remove-Item `
                    -Path $BatchSignPath `
                    -Recurse `
                    -Force

                Write-Log "已清理殘留目錄"
            }
        }
        catch {
        }

        return $true
    }

    Write-Log "BatchSignCS 移除失敗"

    return $false
}

#==============================================================================
# 初始化
#==============================================================================

Ensure-Folder $LogDir
Ensure-Folder $TempDir

Clean-Logs -TargetDir $LogDir -Days $KeepDays -Filter "*.log"
Clean-Logs -TargetDir $TempDir -Days $KeepDays -Filter "*.log"
Clean-Logs -TargetDir $TempDir -Days 0 -Filter "BatchSignCS*.log"


$files = Get-ChildItem `
    -Path $TempDir `
    -File `
    -ErrorAction SilentlyContinue

$count = $files.Count

$sizeMB = [math]::Round(
    ($files | Measure-Object Length -Sum).Sum / 1MB,
    2
)

#==============================================================================
# 啟動資訊
#==============================================================================
if ($IsDryRun) {
    Write-Log "＊＊＊ DRY RUN 模式（不會實際變更系統）＊＊＊"
}
Write-Log "=========================================================="
Write-Log "GEAS Startup Script 開始"
Write-Log "Version      : $ScriptVersion"
Write-Log "Mode         : $Mode"
Write-Log "GPO          : $GPOName"
Write-Log "Computer     : $Computer"
Write-Log "User         : SYSTEM"
Write-Log "OS           : $((Get-CimInstance Win32_OperatingSystem).Caption)"
Write-Log "TempDir      : $TempDir"
Write-Log "Temp Files   : $count"
Write-Log "Temp Size    : $sizeMB MB"

try {
    $ip = (
        Get-CimInstance Win32_NetworkAdapterConfiguration |
        Where-Object {
            $_.IPAddress -ne $null
        } |
        ForEach-Object {
            $_.IPAddress
        } |
        Where-Object {
            $_ -match '^\d{1,3}(\.\d{1,3}){3}$' -and
            $_ -notmatch '^169\.254\.'
        } |
        Select-Object -First 1
    )

    Write-Log "IP Address   : $ip"
}
catch {
}

#==============================================================================
# Uninstall Mode
#==============================================================================

if ($Mode -eq "Uninstall") {
    Write-Log "進入移除模式"
    if (-not (Get-InstalledFlag)) {
        Write-Log "未發現安裝旗標，略過卸載"
        exit 0
    }
    if (Is-BatchSignInstalled) {
        Uninstall-BatchSignCS
    }
    else {
        Write-Log "BatchSignCS 未安裝，清除旗標"
        Remove-InstalledFlag
    }
    Write-Log "GEAS Uninstall 完成"
    exit 0
}

#==============================================================================
# 電腦白名單
#==============================================================================

if (-not $Computer.StartsWith("PC")) {
    Write-Log "非 PC 電腦，結束"

    exit 0
}

#==============================================================================
# 版本檢查（升級控制）
#==============================================================================

try {
    if (Test-Path $RegistryRoot) {
        $v = Get-ItemProperty $RegistryRoot
        if ($v.Version -ne $RequiredVersion) {
            Write-Log "偵測版本不一致：目前=$($v.Version)，需求=$RequiredVersion"
            Write-Log "觸發升級流程（Uninstall）"
            #$Mode = "Uninstall"
			Uninstall-BatchSignCS
        }
    }
}
catch {}

#==============================================================================
# 已安裝旗標
#==============================================================================

if (Get-InstalledFlag) {
    Write-Log "Registry 旗標已存在，略過"

    exit 0
}

#==============================================================================
# 安裝 VC++ x64
#==============================================================================

if (Is-VCRedistX64Installed) {
    Write-Log "VC++ x64 已安裝"
}
else {
    $vcX64Local = Join-Path $TempDir "vc_redist.x64.exe"
    if (Copy-From-Sources $VcX64Sources $vcX64Local) {
        Write-Log "開始安裝 VC++ x64"
        $exit = Invoke-Process -FilePath $vcX64Local -Arguments "/quiet /norestart"
        switch ($exit) {
            0     { Write-Log "VC++ x64 安裝成功" }
            1638  { Write-Log "VC++ x64 已存在（1638）" }
            3010  { Write-Log "VC++ x64 安裝完成，需要重新開機（3010）" }

            default {
                Write-Log "VC++ x64 安裝失敗：$exit"
            }
        }
    }
    else {
        Write-Log "VC++ x64 安裝檔無法取得"
    }
}

#==============================================================================
# 安裝 VC++ x86
#==============================================================================

if (Is-VCRedistX86Installed) {
    Write-Log "VC++ x86 已安裝"
}
else {
    $vcX86Local = Join-Path $TempDir "vc_redist.x86.exe"
    if (Copy-From-Sources $VcX86Sources $vcX86Local) {
        Write-Log "開始安裝 VC++ x86"
        $exit = Invoke-Process `
            -FilePath $vcX86Local `
            -Arguments "/quiet /norestart"

        switch ($exit) {
            0     { Write-Log "VC++ x86 安裝成功" }
            1638  { Write-Log "VC++ x86 已存在（1638）" }
            3010  { Write-Log "VC++ x86 安裝完成，需要重新開機（3010）" }

            default {
                Write-Log "VC++ x86 安裝失敗：$exit"
            }
        }
    }
    else {
        Write-Log "VC++ x86 安裝檔無法取得"
    }
}

#==============================================================================
# 安裝 BatchSignCS
#==============================================================================

if (Is-BatchSignInstalled) {
    Write-Log "BatchSignCS 已安裝"

    Set-InstalledFlag
}
else {
    $msiLocal = Join-Path $TempDir "BatchSignCS.msi"
    $msiLog   = Join-Path $TempDir "BatchSignCS_MSI.log"

    if (Copy-From-Sources $BatchSignSources $msiLocal) {
        Write-Log "開始安裝 BatchSignCS"

        $args = "/i `"$msiLocal`" /qb /norestart /L*v `"$msiLog`""

        $exit = Invoke-Process `
            -FilePath "msiexec.exe" `
            -Arguments $args `
            -Retry 3

        Start-Sleep -Seconds (Get-Random -Minimum 5 -Maximum 10)

        if (Is-BatchSignInstalled) {
            Write-Log "BatchSignCS 安裝成功"

            Set-InstalledFlag
        }
        else {
            Write-Log "BatchSignCS 安裝失敗"

            Write-Log "MSI Log：$msiLog"
        }
    }
    else {
        Write-Log "BatchSignCS 安裝檔無法取得"
    }
}

#==============================================================================
# 完成
#==============================================================================

$duration = New-TimeSpan `
    -Start $StartTime `
    -End (Get-Date)

Write-Log "執行時間：$($duration.TotalSeconds) 秒"

Write-Log "GEAS Startup Script 完成"

Write-Log "=========================================================="

#==============================================================================
# Mutex Release
#==============================================================================

try {
    $Mutex.ReleaseMutex() | Out-Null
    $Mutex.Dispose()
}
catch {
}

exit 0