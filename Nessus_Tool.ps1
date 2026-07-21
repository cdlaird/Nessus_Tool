#Requires -Version 5.1
<#
.SYNOPSIS
    Nessus Tool — WinForms operator console for IP staging, AV updates,
    Nessus Agent install/link, cleanup, system audit, and IP restore.

.NOTES
    Run elevated (Administrator) for network / service / install actions.
    Settings persist in Tool_Config.json next to this script.
    IP baselines persist in IP_Baselines.json (never silently overwritten).
#>

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$Script:ToolVersion = "2.2.0"

# Default DIR
$Global:AVDir    = Split-Path -Parent $PSCommandPath
$Global:AgentDir = Split-Path -Parent $PSCommandPath

# Remote RHEL scanner target (overridden by Tool_Config.json when present)
$Global:RHELTargetHost = "192.168.50.7"
$Global:SshUser        = "root"
$Global:SshOpts        = "-o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new"
$Global:AgentLinkPort  = 8834
$Global:NessusCliPath  = "C:\Program Files\Tenable\Nessus Agent\nessuscli.exe"

# Global Tracking Object for Assignments
$Global:NetworkTracker = @{
    ComputerName      = $env:COMPUTERNAME
    OriginalInterface = "None"
    OriginalIP        = "Not Detected"
    OriginalMask      = "Not Detected"
    OriginalGateway   = "Not Detected"
    OriginalDNS       = "Not Detected"
    OriginalDHCP      = $false
    AssignedTempIP    = "None"
}

# -----------------------------------------------------------------------------
# PERSISTENT CONFIG + IP BASELINE STORE
# -----------------------------------------------------------------------------

$Global:ConfigPath        = Join-Path $Global:AgentDir "Tool_Config.json"
$Global:BaselineStorePath = Join-Path $Global:AgentDir "IP_Baselines.json"

function Get-DefaultConfig {
    return [ordered]@{
        RHELTargetHost = $Global:RHELTargetHost
        SshUser        = $Global:SshUser
        SshOpts        = $Global:SshOpts
        AgentLinkPort  = $Global:AgentLinkPort
        AVDir          = $Global:AVDir
        AgentDir       = $Global:AgentDir
        NessusCliPath  = $Global:NessusCliPath
        LastGroups     = ""
    }
}

function Import-ToolConfig {
    if (-not (Test-Path $Global:ConfigPath)) {
        $cfg = Get-DefaultConfig
        Save-ToolConfig $cfg | Out-Null
        return $cfg
    }
    try {
        $raw = Get-Content -Path $Global:ConfigPath -Raw -ErrorAction Stop
        if ([string]::IsNullOrWhiteSpace($raw)) { return Get-DefaultConfig }
        $data = $raw | ConvertFrom-Json -ErrorAction Stop
        $cfg = Get-DefaultConfig
        foreach ($prop in $data.PSObject.Properties.Name) {
            if ($cfg.Contains($prop)) { $cfg[$prop] = $data.$prop }
        }
        return $cfg
    } catch {
        Write-Host "[!] Config unreadable; using defaults. $_"
        return Get-DefaultConfig
    }
}

function Save-ToolConfig($Config) {
    try {
        [pscustomobject]$Config | ConvertTo-Json -Depth 5 |
            Set-Content -Path $Global:ConfigPath -Encoding UTF8
        return $true
    } catch {
        if (Get-Command Write-Log -ErrorAction SilentlyContinue) {
            Write-Log "[!] Failed saving Tool_Config.json: $_"
        }
        return $false
    }
}

function Apply-ToolConfig($Config) {
    if ($Config.RHELTargetHost) { $Global:RHELTargetHost = [string]$Config.RHELTargetHost }
    if ($Config.SshUser)        { $Global:SshUser        = [string]$Config.SshUser }
    if ($Config.SshOpts)        { $Global:SshOpts        = [string]$Config.SshOpts }
    if ($Config.AgentLinkPort)  { $Global:AgentLinkPort  = [int]$Config.AgentLinkPort }
    if ($Config.AVDir -and (Test-Path $Config.AVDir))       { $Global:AVDir    = [string]$Config.AVDir }
    if ($Config.AgentDir -and (Test-Path $Config.AgentDir)) { $Global:AgentDir = [string]$Config.AgentDir }
    if ($Config.NessusCliPath)  { $Global:NessusCliPath  = [string]$Config.NessusCliPath }
}

$Global:ToolConfig = Import-ToolConfig
Apply-ToolConfig $Global:ToolConfig

function Get-BaselineStore {
    if (-not (Test-Path $Global:BaselineStorePath)) { return @() }
    try {
        $raw = Get-Content -Path $Global:BaselineStorePath -Raw -ErrorAction Stop
        if ([string]::IsNullOrWhiteSpace($raw)) { return @() }
        $data = $raw | ConvertFrom-Json -ErrorAction Stop
        if ($null -eq $data) { return @() }
        if ($data -isnot [System.Array]) { return @($data) }
        return $data
    } catch {
        Write-Log "[!] WARNING: Baseline store file is unreadable/corrupt. Treating as empty. Error: $_"
        return @()
    }
}

function Save-BaselineStore($StoreArray) {
    try {
        @($StoreArray) | ConvertTo-Json -Depth 5 | Set-Content -Path $Global:BaselineStorePath -Encoding UTF8
        return $true
    } catch {
        Write-Log "[!] CRITICAL: Failed writing baseline store to disk: $_"
        return $false
    }
}

function Get-BaselineFor($ComputerName, $InterfaceAlias) {
    $store = Get-BaselineStore
    return $store | Where-Object { $_.ComputerName -eq $ComputerName -and $_.InterfaceAlias -eq $InterfaceAlias } | Select-Object -First 1
}

function Set-BaselineFor($Record) {
    $store = @(Get-BaselineStore | Where-Object { -not ($_.ComputerName -eq $Record.ComputerName -and $_.InterfaceAlias -eq $Record.InterfaceAlias) })
    $store += $Record
    return Save-BaselineStore $store
}

function Remove-BaselineFor($ComputerName, $InterfaceAlias) {
    $store = @(Get-BaselineStore | Where-Object { -not ($_.ComputerName -eq $ComputerName -and $_.InterfaceAlias -eq $InterfaceAlias) })
    return Save-BaselineStore $store
}

# -----------------------------------------------------------------------------
# ADMIN / ENVIRONMENT HELPERS
# -----------------------------------------------------------------------------

function Test-IsAdministrator {
    try {
        $id = [Security.Principal.WindowsIdentity]::GetCurrent()
        $principal = New-Object Security.Principal.WindowsPrincipal($id)
        return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    } catch { return $false }
}

$Global:IsAdmin = Test-IsAdministrator

function Confirm-DestructiveAction {
    param(
        [string]$Title,
        [string]$Message
    )
    $result = [System.Windows.Forms.MessageBox]::Show(
        $Message,
        $Title,
        [System.Windows.Forms.MessageBoxButtons]::YesNo,
        [System.Windows.Forms.MessageBoxIcon]::Warning
    )
    return ($result -eq [System.Windows.Forms.DialogResult]::Yes)
}

function Find-NessusAgentMsi {
    param([string]$SearchDir = $Global:AgentDir)
    if (-not (Test-Path $SearchDir)) { return $null }
    $msi = Get-ChildItem -Path $SearchDir -Filter "NessusAgent*.msi" -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending |
        Select-Object -First 1
    return $msi
}

function Get-LiveIPv4OnAdapter {
    param([string]$InterfaceAlias)
    try {
        $ipConf = Get-NetIPConfiguration -ErrorAction SilentlyContinue | Where-Object InterfaceAlias -eq $InterfaceAlias
        if (-not $ipConf) { return $null }
        return ($ipConf.IPv4Address | Select-Object -First 1).IPAddress
    } catch { return $null }
}

function Test-ValidIPv4 ($ipAddress) {
    $pattern = "^([1-9]|[1-9][0-9]|1[0-9][0-9]|2[0-4][0-9]|25[0-5])(\.([0-9]|[1-9][0-9]|1[0-9][0-9]|2[0-4][0-9]|25[0-5])){3}$"
    return $ipAddress -match $pattern
}

# Checks whether a candidate IPv4 appears free to claim on the local LAN.
# - OWNED_LOCALLY: already assigned to this machine (optionally the selected adapter)
# - IN_USE: ICMP reply and/or ARP entry with a MAC from another host
# - LIKELY_FREE: no ping reply and no ARP MAC (ICMP-blocked hosts can still false-negative)
# - INVALID / ERROR: bad input or probe failure
function Test-IpAddressAvailability {
    param(
        [Parameter(Mandatory = $true)][string]$IpAddress,
        [string]$SelectedInterface = $null
    )

    $result = [PSCustomObject]@{
        Status      = "ERROR"
        Available   = $false
        Detail      = ""
        MacAddress  = ""
        Responded   = $false
        OwnedLocally = $false
    }

    if (-not (Test-ValidIPv4 $IpAddress)) {
        $result.Status = "INVALID"
        $result.Detail = "Not a valid IPv4 address."
        return $result
    }

    try {
        # Is this IP already bound on this PC?
        $localMatches = @()
        try {
            $localMatches = @(Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
                Where-Object { $_.IPAddress -eq $IpAddress })
        } catch { $localMatches = @() }

        if ($localMatches.Count -gt 0) {
            $ifNames = ($localMatches | ForEach-Object { $_.InterfaceAlias } | Select-Object -Unique) -join ", "
            $result.OwnedLocally = $true
            $result.MacAddress = ""
            if ($SelectedInterface -and ($localMatches.InterfaceAlias -contains $SelectedInterface)) {
                $result.Status = "OWNED_LOCALLY"
                $result.Available = $true
                $result.Detail = "Already assigned to selected adapter '$SelectedInterface' on this PC."
            } else {
                $result.Status = "OWNED_LOCALLY"
                $result.Available = $false
                $result.Detail = "Already assigned to this PC on: $ifNames"
            }
            return $result
        }

        # Probe: ICMP ping (best-effort). Then inspect ARP for a MAC neighbor.
        $pingOk = $false
        try {
            $pingOk = Test-Connection -ComputerName $IpAddress -Count 2 -Quiet -ErrorAction SilentlyContinue
        } catch { $pingOk = $false }
        $result.Responded = [bool]$pingOk

        # Give ARP a moment to populate after ping attempts
        Start-Sleep -Milliseconds 300
        [System.Windows.Forms.Application]::DoEvents()

        $mac = ""
        try {
            $arpLine = & arp.exe -a $IpAddress 2>$null | Where-Object { $_ -match [regex]::Escape($IpAddress) } | Select-Object -First 1
            if ($arpLine -match "([0-9a-fA-F]{2}(-[0-9a-fA-F]{2}){5})") {
                $mac = $Matches[1]
            } elseif ($arpLine -match "([0-9a-fA-F]{2}(:[0-9a-fA-F]{2}){5})") {
                $mac = $Matches[1]
            }
        } catch { $mac = "" }
        $result.MacAddress = $mac

        if ($pingOk) {
            $result.Status = "IN_USE"
            $result.Available = $false
            $result.Detail = if ($mac) {
                "Host responded to ping. ARP MAC: $mac — IP appears taken."
            } else {
                "Host responded to ping — IP appears taken."
            }
            return $result
        }

        if ($mac -and $mac -notmatch "^(00-00-00-00-00-00|ff-ff-ff-ff-ff-ff)$") {
            $result.Status = "IN_USE"
            $result.Available = $false
            $result.Detail = "No ping reply, but ARP shows neighbor MAC $mac — IP likely in use (ICMP may be blocked)."
            return $result
        }

        $result.Status = "LIKELY_FREE"
        $result.Available = $true
        $result.Detail = "No ping reply and no ARP neighbor found. IP looks free to use (hosts that block ICMP can still be present)."
        return $result
    } catch {
        $result.Status = "ERROR"
        $result.Detail = "Availability check failed: $_"
        return $result
    }
}

function Show-IpAvailabilityResult {
    param($ProbeResult, [string]$IpAddress)

    switch ($ProbeResult.Status) {
        "LIKELY_FREE" {
            $lblIpAvailVal.Text = "LIKELY FREE — $IpAddress"
            $lblIpAvailVal.ForeColor = [System.Drawing.Color]::DarkGreen
        }
        "OWNED_LOCALLY" {
            if ($ProbeResult.Available) {
                $lblIpAvailVal.Text = "OK (already on this adapter) — $IpAddress"
                $lblIpAvailVal.ForeColor = [System.Drawing.Color]::DarkGreen
            } else {
                $lblIpAvailVal.Text = "IN USE on this PC — $IpAddress"
                $lblIpAvailVal.ForeColor = [System.Drawing.Color]::DarkRed
            }
        }
        "IN_USE" {
            $lblIpAvailVal.Text = "IN USE — $IpAddress"
            $lblIpAvailVal.ForeColor = [System.Drawing.Color]::DarkRed
        }
        "INVALID" {
            $lblIpAvailVal.Text = "INVALID IP"
            $lblIpAvailVal.ForeColor = [System.Drawing.Color]::DarkRed
        }
        default {
            $lblIpAvailVal.Text = "CHECK FAILED"
            $lblIpAvailVal.ForeColor = [System.Drawing.Color]::DarkOrange
        }
    }

    Write-Log "[ IP CHECK ] $IpAddress → $($ProbeResult.Status): $($ProbeResult.Detail)"
}

function Invoke-SshRemote {
    param([string]$RemoteCommand)
    $optParts = $Global:SshOpts.Split(' ', [System.StringSplitOptions]::RemoveEmptyEntries)
    $args = @()
    $args += $optParts
    $args += @("-l", $Global:SshUser, $Global:RHELTargetHost, $RemoteCommand)
    try {
        $output = & ssh @args 2>&1 | Out-String
        return $output.Trim()
    } catch {
        return "SSH_ERROR: $_"
    }
}

function Test-TcpPortOpen {
    param(
        [string]$ComputerName,
        [int]$Port,
        [int]$TimeoutMs = 3000
    )
    try {
        $client = New-Object System.Net.Sockets.TcpClient
        $iar = $client.BeginConnect($ComputerName, $Port, $null, $null)
        $wait = $iar.AsyncWaitHandle.WaitOne($TimeoutMs, $false)
        if (-not $wait) {
            $client.Close()
            return $false
        }
        $client.EndConnect($iar)
        $client.Close()
        return $true
    } catch {
        return $false
    }
}

# Main Window
$Form = New-Object System.Windows.Forms.Form
$Form.Text = "Nessus Tool v$Script:ToolVersion"
$Form.ClientSize = New-Object System.Drawing.Size(1400, 920)
$Form.AutoScaleMode = 'None'
$Form.StartPosition = "CenterScreen"
$Form.FormBorderStyle = 'Sizable'
$Form.MinimumSize = New-Object System.Drawing.Size(1200, 700)
$Form.AutoScroll = $true

$FontBold = New-Object System.Drawing.Font("Segoe UI", 10, [System.Drawing.FontStyle]::Bold)
$FontRegular = New-Object System.Drawing.Font("Segoe UI", 10, [System.Drawing.FontStyle]::Regular)

# Log Window
$txtLog = New-Object System.Windows.Forms.TextBox
$txtLog.Location = New-Object System.Drawing.Point(950, 20)
$txtLog.Size = New-Object System.Drawing.Size(400, 760)
$txtLog.Multiline = $true
$txtLog.ScrollBars = "Vertical"
$txtLog.Font = New-Object System.Drawing.Font("Consolas", 10)
$txtLog.ReadOnly = $true
$txtLog.BackColor = [System.Drawing.Color]::White
$Form.Controls.Add($txtLog)

function Write-Log($msg) {
    $stamp = (Get-Date).ToString("HH:mm:ss")
    $txtLog.AppendText("[$stamp] $msg`r`n")
    [System.Windows.Forms.Application]::DoEvents()
}

# Log toolbar
$btnClearLog = New-Object System.Windows.Forms.Button
$btnClearLog.Text = "Clear Log"
$btnClearLog.Location = New-Object System.Drawing.Point(950, 790)
$btnClearLog.Size = New-Object System.Drawing.Size(95, 28)
$btnClearLog.Add_Click({ $txtLog.Clear() })
$Form.Controls.Add($btnClearLog)

$btnCopyLog = New-Object System.Windows.Forms.Button
$btnCopyLog.Text = "Copy Log"
$btnCopyLog.Location = New-Object System.Drawing.Point(1055, 790)
$btnCopyLog.Size = New-Object System.Drawing.Size(95, 28)
$btnCopyLog.Add_Click({
    if ([string]::IsNullOrWhiteSpace($txtLog.Text)) { return }
    [System.Windows.Forms.Clipboard]::SetText($txtLog.Text)
    Write-Log "[+] Log copied to clipboard."
})
$Form.Controls.Add($btnCopyLog)

$btnSaveLog = New-Object System.Windows.Forms.Button
$btnSaveLog.Text = "Save Log..."
$btnSaveLog.Location = New-Object System.Drawing.Point(1160, 790)
$btnSaveLog.Size = New-Object System.Drawing.Size(95, 28)
$btnSaveLog.Add_Click({
    $dlg = New-Object System.Windows.Forms.SaveFileDialog
    $dlg.Filter = "Log files (*.log)|*.log|Text files (*.txt)|*.txt|All files (*.*)|*.*"
    $dlg.FileName = "NessusTool_{0:yyyyMMdd_HHmmss}.log" -f (Get-Date)
    if ($dlg.ShowDialog() -eq "OK") {
        try {
            Set-Content -Path $dlg.FileName -Value $txtLog.Text -Encoding UTF8
            Write-Log "[+] Log saved to: $($dlg.FileName)"
        } catch {
            Write-Log "[!] Failed to save log: $_"
        }
    }
})
$Form.Controls.Add($btnSaveLog)

$btnOpenFolder = New-Object System.Windows.Forms.Button
$btnOpenFolder.Text = "Open Folder"
$btnOpenFolder.Location = New-Object System.Drawing.Point(1265, 790)
$btnOpenFolder.Size = New-Object System.Drawing.Size(85, 28)
$btnOpenFolder.Add_Click({
    Start-Process explorer.exe $Global:AgentDir
})
$Form.Controls.Add($btnOpenFolder)

# Progress Bar
$ProgressBar = New-Object System.Windows.Forms.ProgressBar
$ProgressBar.Location = New-Object System.Drawing.Point(950, 830)
$ProgressBar.Size = New-Object System.Drawing.Size(400, 20)
$ProgressBar.Style = "Continuous"
$ProgressBar.Value = 0
$Form.Controls.Add($ProgressBar)

function Set-Progress($value) {
    if ($value -lt 0) { $value = 0 }
    if ($value -gt 100) { $value = 100 }
    $ProgressBar.Value = $value
    $ProgressBar.Refresh()
}

# Status strip
$lblStatusStrip = New-Object System.Windows.Forms.Label
$lblStatusStrip.Location = New-Object System.Drawing.Point(20, 880)
$lblStatusStrip.Size = New-Object System.Drawing.Size(1330, 25)
$lblStatusStrip.Font = New-Object System.Drawing.Font("Segoe UI", 9)
$Form.Controls.Add($lblStatusStrip)

function Update-StatusStrip {
    $adminText = if ($Global:IsAdmin) { "ADMIN" } else { "NOT ELEVATED" }
    $adminColor = if ($Global:IsAdmin) { [System.Drawing.Color]::DarkGreen } else { [System.Drawing.Color]::DarkRed }
    $lblStatusStrip.ForeColor = $adminColor
    $lblStatusStrip.Text = "v$Script:ToolVersion  |  $adminText  |  Host: $($Global:NetworkTracker.ComputerName)  |  Scanner: $($Global:RHELTargetHost):$($Global:AgentLinkPort)  |  SSH: $($Global:SshUser)@$($Global:RHELTargetHost)"
}
Update-StatusStrip

# -----------------------------------------------------------------------------
# SHARED HELPERS
# -----------------------------------------------------------------------------

function New-Label($Parent, $Text, $X, $Y) {
    $lbl = New-Object System.Windows.Forms.Label
    $lbl.Text = $Text
    $lbl.Location = New-Object System.Drawing.Point($X, $Y)
    $lbl.AutoSize = $true
    $lbl.Font = $FontBold
    $Parent.Controls.Add($lbl)
    return $lbl
}

function Start-ProcessResponsive {
    param(
        [string]$FilePath,
        [string]$ArgumentList,
        [switch]$NoNewWindow,
        [string]$RedirectStandardOutput,
        [string]$RedirectStandardError
    )
    $params = @{
        FilePath = $FilePath
        PassThru = $true
    }
    if ($ArgumentList) { $params.ArgumentList = $ArgumentList }
    if ($NoNewWindow) { $params.NoNewWindow = $true }
    if ($RedirectStandardOutput) { $params.RedirectStandardOutput = $RedirectStandardOutput }
    if ($RedirectStandardError)  { $params.RedirectStandardError  = $RedirectStandardError }

    $proc = Start-Process @params
    while (-not $proc.HasExited) {
        [System.Windows.Forms.Application]::DoEvents()
        Start-Sleep -Milliseconds 100
    }
    return $proc
}

function Wait-Responsive([int]$Seconds) {
    $target = (Get-Date).AddSeconds($Seconds)
    while ((Get-Date) -lt $target) {
        [System.Windows.Forms.Application]::DoEvents()
        Start-Sleep -Milliseconds 100
    }
}

function Write-DeploymentHistory {
    param(
        [string]$SelectedAdapter,
        [string]$OriginalIP,
        [string]$OriginalMask,
        [string]$AssignedTempIP
    )
    try {
        $CsvPath = Join-Path $Global:AgentDir "Nessus_Deployment_History.csv"
        $LogRecord = [PSCustomObject]@{
            Timestamp       = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
            ComputerName    = $Global:NetworkTracker.ComputerName
            SelectedAdapter = $SelectedAdapter
            OriginalIP      = $OriginalIP
            OriginalMask    = $OriginalMask
            AssignedTempIP  = $AssignedTempIP
        }
        $LogRecord | Export-Csv -Path $CsvPath -NoTypeInformation -Append
        Write-Log "[+] History archived to: $CsvPath"
    } catch {
        Write-Log "[!] Failed saving history row to CSV file: $_"
    }
}

function Assert-AdminOrWarn {
    param([string]$ActionName)
    if ($Global:IsAdmin) { return $true }
    Write-Log "[!] '$ActionName' usually requires Administrator privileges. Current session is NOT elevated."
    $go = [System.Windows.Forms.MessageBox]::Show(
        "This action ($ActionName) typically requires Administrator rights, and this session is not elevated.`n`nContinue anyway?",
        "Elevation Warning",
        [System.Windows.Forms.MessageBoxButtons]::YesNo,
        [System.Windows.Forms.MessageBoxIcon]::Warning
    )
    return ($go -eq [System.Windows.Forms.DialogResult]::Yes)
}

# Tab System
$Tabs = New-Object System.Windows.Forms.TabControl
$Tabs.Size = New-Object System.Drawing.Size(900, 850)
$Tabs.Location = New-Object System.Drawing.Point(20, 20)

$TabPreflight = New-Object System.Windows.Forms.TabPage
$TabPreflight.Text = "Preflight"

$TabIP = New-Object System.Windows.Forms.TabPage
$TabIP.Text = "Assign IP"

$TabAV = New-Object System.Windows.Forms.TabPage
$TabAV.Text = "AV Update"

$TabAgent = New-Object System.Windows.Forms.TabPage
$TabAgent.Text = "Agent Install + Link"

$TabCleanup = New-Object System.Windows.Forms.TabPage
$TabCleanup.Text = "Deep Cleanup"

$TabAudit = New-Object System.Windows.Forms.TabPage
$TabAudit.Text = "System Audit"

$TabRestore = New-Object System.Windows.Forms.TabPage
$TabRestore.Text = "Restore IP"

$TabSettings = New-Object System.Windows.Forms.TabPage
$TabSettings.Text = "Settings"

$Tabs.TabPages.Add($TabPreflight)
$Tabs.TabPages.Add($TabIP)
$Tabs.TabPages.Add($TabAV)
$Tabs.TabPages.Add($TabAgent)
$Tabs.TabPages.Add($TabCleanup)
$Tabs.TabPages.Add($TabAudit)
$Tabs.TabPages.Add($TabRestore)
$Tabs.TabPages.Add($TabSettings)

$Form.Controls.Add($Tabs)

# -----------------------------------------------------------------------------
# TAB 0 — PREFLIGHT / QUICK HEALTH
# -----------------------------------------------------------------------------

New-Label $TabPreflight "Deployment Preflight Checks" 20 20

$txtPreflight = New-Object System.Windows.Forms.TextBox
$txtPreflight.Location = New-Object System.Drawing.Point(20, 55)
$txtPreflight.Size = New-Object System.Drawing.Size(830, 420)
$txtPreflight.Multiline = $true
$txtPreflight.ScrollBars = "Vertical"
$txtPreflight.Font = New-Object System.Drawing.Font("Consolas", 10)
$txtPreflight.ReadOnly = $true
$TabPreflight.Controls.Add($txtPreflight)

function Write-Preflight($msg) {
    $txtPreflight.AppendText("$msg`r`n")
    [System.Windows.Forms.Application]::DoEvents()
}

function Invoke-PreflightChecks {
    $txtPreflight.Clear()
    Set-Progress 5
    Write-Preflight "=== Nessus Tool Preflight — $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') ==="
    Write-Preflight ""

    # Elevation
    if ($Global:IsAdmin) {
        Write-Preflight "[PASS] Running as Administrator"
    } else {
        Write-Preflight "[FAIL] Not elevated — IP changes, installs, and cleanup may fail"
    }
    Set-Progress 15

    # Host
    Write-Preflight "[INFO] Computer: $($env:COMPUTERNAME)  |  User: $($env:USERNAME)"
    Write-Preflight "[INFO] Tool folder: $Global:AgentDir"
    Write-Preflight "[INFO] Scanner target: $($Global:RHELTargetHost):$($Global:AgentLinkPort)"

    # AV package
    $avPath = Join-Path $Global:AVDir "mpam-fe.exe"
    if (Test-Path $avPath) {
        $avInfo = Get-Item $avPath
        Write-Preflight "[PASS] AV package found: $($avInfo.FullName) ($([math]::Round($avInfo.Length/1MB,1)) MB, $($avInfo.LastWriteTime))"
    } else {
        Write-Preflight "[WARN] mpam-fe.exe not found in: $Global:AVDir"
    }
    Set-Progress 30

    # Agent MSI
    $msi = Find-NessusAgentMsi
    if ($msi) {
        Write-Preflight "[PASS] Nessus Agent MSI: $($msi.Name) ($([math]::Round($msi.Length/1MB,1)) MB)"
    } else {
        Write-Preflight "[WARN] No NessusAgent*.msi found in: $Global:AgentDir"
    }
    Set-Progress 45

    # Agent install / service
    if (Test-Path $Global:NessusCliPath) {
        Write-Preflight "[PASS] nessuscli.exe present"
        $svc = Get-Service -Name "Tenable Nessus Agent" -ErrorAction SilentlyContinue
        if ($svc) {
            Write-Preflight "[INFO] Agent service status: $($svc.Status)"
        } else {
            Write-Preflight "[WARN] Tenable Nessus Agent service not found"
        }
    } else {
        Write-Preflight "[INFO] Nessus Agent not installed (nessuscli.exe missing)"
    }
    Set-Progress 55

    # Baselines
    $baselines = @(Get-BaselineStore)
    Write-Preflight "[INFO] Saved IP restore points on disk: $($baselines.Count)"

    # Ping scanner
    Write-Preflight ""
    Write-Preflight "--- Connectivity ---"
    try {
        $ping = Test-Connection -ComputerName $Global:RHELTargetHost -Count 2 -Quiet -ErrorAction SilentlyContinue
        if ($ping) {
            Write-Preflight "[PASS] ICMP ping to $($Global:RHELTargetHost) succeeded"
        } else {
            Write-Preflight "[WARN] ICMP ping to $($Global:RHELTargetHost) failed (may be filtered)"
        }
    } catch {
        Write-Preflight "[WARN] Ping check error: $_"
    }
    Set-Progress 70

    # TCP port to scanner
    if (Test-TcpPortOpen -ComputerName $Global:RHELTargetHost -Port $Global:AgentLinkPort) {
        Write-Preflight "[PASS] TCP $($Global:AgentLinkPort) open on $($Global:RHELTargetHost)"
    } else {
        Write-Preflight "[WARN] TCP $($Global:AgentLinkPort) not reachable on $($Global:RHELTargetHost)"
    }
    Set-Progress 80

    # SSH
    $sshCmd = Get-Command ssh -ErrorAction SilentlyContinue
    if ($sshCmd) {
        Write-Preflight "[PASS] OpenSSH client available: $($sshCmd.Source)"
        $sshProbe = Invoke-SshRemote "echo OK"
        if ($sshProbe -match "OK") {
            Write-Preflight "[PASS] SSH login to $($Global:SshUser)@$($Global:RHELTargetHost) works"
            $nessusd = Invoke-SshRemote "systemctl is-active nessusd 2>/dev/null || echo unknown"
            Write-Preflight "[INFO] Remote nessusd: $nessusd"
        } else {
            Write-Preflight "[WARN] SSH probe failed: $sshProbe"
        }
    } else {
        Write-Preflight "[WARN] ssh.exe not found on PATH"
    }
    Set-Progress 90

    # Disk space
    try {
        $drive = (Get-Item $Global:AgentDir).PSDrive.Name
        $free = (Get-PSDrive $drive).Free
        Write-Preflight "[INFO] Free space on ${drive}: $([math]::Round($free/1GB, 2)) GB"
    } catch {}

    Write-Preflight ""
    Write-Preflight "=== Preflight complete ==="
    Set-Progress 100
    Write-Log "[+] Preflight checks finished."
}

$btnRunPreflight = New-Object System.Windows.Forms.Button
$btnRunPreflight.Text = "Run All Preflight Checks"
$btnRunPreflight.Location = New-Object System.Drawing.Point(20, 490)
$btnRunPreflight.Size = New-Object System.Drawing.Size(400, 45)
$btnRunPreflight.BackColor = [System.Drawing.Color]::DarkSlateGray
$btnRunPreflight.ForeColor = [System.Drawing.Color]::White
$btnRunPreflight.Font = $FontBold
$btnRunPreflight.Add_Click({ Invoke-PreflightChecks })
$TabPreflight.Controls.Add($btnRunPreflight)

$btnQuickPing = New-Object System.Windows.Forms.Button
$btnQuickPing.Text = "Ping Scanner Only"
$btnQuickPing.Location = New-Object System.Drawing.Point(440, 490)
$btnQuickPing.Size = New-Object System.Drawing.Size(200, 45)
$btnQuickPing.Font = $FontBold
$btnQuickPing.Add_Click({
    Write-Log "[*] Pinging $($Global:RHELTargetHost)..."
    $ok = Test-Connection -ComputerName $Global:RHELTargetHost -Count 2 -Quiet -ErrorAction SilentlyContinue
    if ($ok) { Write-Log "[+] Ping OK" } else { Write-Log "[!] Ping failed" }
})
$TabPreflight.Controls.Add($btnQuickPing)

$btnQuickTcp = New-Object System.Windows.Forms.Button
$btnQuickTcp.Text = "Test Agent Port"
$btnQuickTcp.Location = New-Object System.Drawing.Point(660, 490)
$btnQuickTcp.Size = New-Object System.Drawing.Size(190, 45)
$btnQuickTcp.Font = $FontBold
$btnQuickTcp.Add_Click({
    Write-Log "[*] Testing TCP $($Global:AgentLinkPort) on $($Global:RHELTargetHost)..."
    if (Test-TcpPortOpen -ComputerName $Global:RHELTargetHost -Port $Global:AgentLinkPort) {
        Write-Log "[+] Port open"
    } else {
        Write-Log "[!] Port closed / unreachable"
    }
})
$TabPreflight.Controls.Add($btnQuickTcp)

New-Label $TabPreflight "Recommended deploy order: Preflight → Assign IP → AV Update → Install + Link → (later) Restore IP + Cleanup" 20 555

# -----------------------------------------------------------------------------
# TAB 1 — IP ADDRESS ASSIGNMENT
# -----------------------------------------------------------------------------

New-Label $TabIP "Network Interface Quick Configuration" 20 20

$grpSystemMeta = New-Object System.Windows.Forms.GroupBox
$grpSystemMeta.Text = " Host Tracking Information "
$grpSystemMeta.Location = New-Object System.Drawing.Point(20, 50)
$grpSystemMeta.Size = New-Object System.Drawing.Size(830, 115)
$grpSystemMeta.Font = $FontBold
$TabIP.Controls.Add($grpSystemMeta)

$lblCompTag = New-Object System.Windows.Forms.Label
$lblCompTag.Text = "Computer Name:"
$lblCompTag.Location = New-Object System.Drawing.Point(20, 25)
$lblCompTag.AutoSize = $true
$grpSystemMeta.Controls.Add($lblCompTag)

$lblCompVal = New-Object System.Windows.Forms.Label
$lblCompVal.Text = $Global:NetworkTracker.ComputerName
$lblCompVal.Location = New-Object System.Drawing.Point(145, 25)
$lblCompVal.AutoSize = $true
$lblCompVal.Font = $FontRegular
$grpSystemMeta.Controls.Add($lblCompVal)

$lblOrigIpTag = New-Object System.Windows.Forms.Label
$lblOrigIpTag.Text = "Detected Original IP:"
$lblOrigIpTag.Location = New-Object System.Drawing.Point(400, 25)
$lblOrigIpTag.AutoSize = $true
$grpSystemMeta.Controls.Add($lblOrigIpTag)

$lblOrigIpVal = New-Object System.Windows.Forms.Label
$lblOrigIpVal.Text = "Select interface..."
$lblOrigIpVal.Location = New-Object System.Drawing.Point(560, 25)
$lblOrigIpVal.AutoSize = $true
$lblOrigIpVal.Font = $FontRegular
$lblOrigIpVal.ForeColor = [System.Drawing.Color]::Blue
$grpSystemMeta.Controls.Add($lblOrigIpVal)

$lblOrigMaskTag = New-Object System.Windows.Forms.Label
$lblOrigMaskTag.Text = "Original Subnet Mask:"
$lblOrigMaskTag.Location = New-Object System.Drawing.Point(400, 55)
$lblOrigMaskTag.AutoSize = $true
$grpSystemMeta.Controls.Add($lblOrigMaskTag)

$lblOrigMaskVal = New-Object System.Windows.Forms.Label
$lblOrigMaskVal.Text = "Select interface..."
$lblOrigMaskVal.Location = New-Object System.Drawing.Point(560, 55)
$lblOrigMaskVal.AutoSize = $true
$lblOrigMaskVal.Font = $FontRegular
$lblOrigMaskVal.ForeColor = [System.Drawing.Color]::Blue
$grpSystemMeta.Controls.Add($lblOrigMaskVal)

$lblBaselineTag = New-Object System.Windows.Forms.Label
$lblBaselineTag.Text = "Baseline Status:"
$lblBaselineTag.Location = New-Object System.Drawing.Point(20, 85)
$lblBaselineTag.AutoSize = $true
$grpSystemMeta.Controls.Add($lblBaselineTag)

$lblBaselineVal = New-Object System.Windows.Forms.Label
$lblBaselineVal.Text = "No interface selected"
$lblBaselineVal.Location = New-Object System.Drawing.Point(145, 85)
$lblBaselineVal.AutoSize = $true
$lblBaselineVal.Font = $FontRegular
$lblBaselineVal.ForeColor = [System.Drawing.Color]::Gray
$grpSystemMeta.Controls.Add($lblBaselineVal)

New-Label $TabIP "1. Select Interface:" 20 175

$lbInterfaces = New-Object System.Windows.Forms.ListBox
$lbInterfaces.Location = New-Object System.Drawing.Point(20, 200)
$lbInterfaces.Size = New-Object System.Drawing.Size(350, 150)
$TabIP.Controls.Add($lbInterfaces)

$btnRefreshIfaces = New-Object System.Windows.Forms.Button
$btnRefreshIfaces.Text = "Refresh Interfaces"
$btnRefreshIfaces.Location = New-Object System.Drawing.Point(20, 355)
$btnRefreshIfaces.Size = New-Object System.Drawing.Size(170, 30)
$TabIP.Controls.Add($btnRefreshIfaces)

$btnRecaptureBaseline = New-Object System.Windows.Forms.Button
$btnRecaptureBaseline.Text = "Recapture Baseline"
$btnRecaptureBaseline.Location = New-Object System.Drawing.Point(200, 355)
$btnRecaptureBaseline.Size = New-Object System.Drawing.Size(170, 30)
$btnRecaptureBaseline.BackColor = [System.Drawing.Color]::Goldenrod
$btnRecaptureBaseline.Font = New-Object System.Drawing.Font("Segoe UI", 8, [System.Drawing.FontStyle]::Bold)
$TabIP.Controls.Add($btnRecaptureBaseline)

$grpIPMode = New-Object System.Windows.Forms.GroupBox
$grpIPMode.Text = " 2. Assignment Profile "
$grpIPMode.Location = New-Object System.Drawing.Point(390, 185)
$grpIPMode.Size = New-Object System.Drawing.Size(460, 200)
$grpIPMode.Font = $FontBold
$TabIP.Controls.Add($grpIPMode)

$radDHCP = New-Object System.Windows.Forms.RadioButton
$radDHCP.Text = "Set Automated DHCP"
$radDHCP.Location = New-Object System.Drawing.Point(20, 30)
$radDHCP.Size = New-Object System.Drawing.Size(250, 25)
$radDHCP.Checked = $true
$radDHCP.Font = $FontRegular
$grpIPMode.Controls.Add($radDHCP)

$radAPIPA = New-Object System.Windows.Forms.RadioButton
$radAPIPA.Text = "Set Link-Local APIPA (169.254.x.x)"
$radAPIPA.Location = New-Object System.Drawing.Point(20, 65)
$radAPIPA.Size = New-Object System.Drawing.Size(300, 25)
$radAPIPA.Font = $FontRegular
$grpIPMode.Controls.Add($radAPIPA)

$radCustom = New-Object System.Windows.Forms.RadioButton
$radCustom.Text = "Set Custom Manual Static IP"
$radCustom.Location = New-Object System.Drawing.Point(20, 100)
$radCustom.Size = New-Object System.Drawing.Size(250, 25)
$radCustom.Font = $FontRegular
$grpIPMode.Controls.Add($radCustom)

$chkVerifyAfter = New-Object System.Windows.Forms.CheckBox
$chkVerifyAfter.Text = "Verify live IP after apply (recommended)"
$chkVerifyAfter.Location = New-Object System.Drawing.Point(20, 130)
$chkVerifyAfter.Size = New-Object System.Drawing.Size(400, 22)
$chkVerifyAfter.Checked = $true
$chkVerifyAfter.Font = $FontRegular
$grpIPMode.Controls.Add($chkVerifyAfter)

$chkCheckIpFree = New-Object System.Windows.Forms.CheckBox
$chkCheckIpFree.Text = "Check IP is free before apply (recommended)"
$chkCheckIpFree.Location = New-Object System.Drawing.Point(20, 152)
$chkCheckIpFree.Size = New-Object System.Drawing.Size(400, 22)
$chkCheckIpFree.Checked = $true
$chkCheckIpFree.Font = $FontRegular
$grpIPMode.Controls.Add($chkCheckIpFree)

$lblLiveIpHint = New-Object System.Windows.Forms.Label
$lblLiveIpHint.Text = "Live IP after change: (not yet applied)"
$lblLiveIpHint.Location = New-Object System.Drawing.Point(20, 175)
$lblLiveIpHint.Size = New-Object System.Drawing.Size(420, 18)
$lblLiveIpHint.Font = $FontRegular
$lblLiveIpHint.ForeColor = [System.Drawing.Color]::DimGray
$grpIPMode.Controls.Add($lblLiveIpHint)

function Get-LiveAdapterSettings($InterfaceAlias) {
    try {
        $ipConf = Get-NetIPConfiguration | Where-Object InterfaceAlias -eq $InterfaceAlias
        if ($null -eq $ipConf) { return $null }

        $currentIP = ($ipConf.IPv4Address | Select-Object -First 1).IPAddress
        if ($null -eq $currentIP) { $currentIP = "No active IPv4 Address Link" }

        $adapterWmi = Get-CimInstance Win32_NetworkAdapterConfiguration | Where-Object { $_.InterfaceIndex -eq $ipConf.InterfaceIndex }
        $currentMask = if ($adapterWmi -and $adapterWmi.IPSubnet) { $adapterWmi.IPSubnet[0] } else { "255.255.255.0" }
        $currentGW   = if ($ipConf.IPv4DefaultGateway) { $ipConf.IPv4DefaultGateway.NextHop } else { "" }
        $currentDNS  = if ($ipConf.DNSServer) { ($ipConf.DNSServer.ServerAddresses | Select-Object -First 1) } else { "" }
        $isDhcpEnabled = if ($adapterWmi) { [bool]$adapterWmi.DHCPEnabled } else { $false }

        return [PSCustomObject]@{
            ComputerName    = $Global:NetworkTracker.ComputerName
            InterfaceAlias  = $InterfaceAlias
            OriginalIP      = $currentIP
            OriginalMask    = $currentMask
            OriginalGateway = $currentGW
            OriginalDNS     = $currentDNS
            OriginalDHCP    = $isDhcpEnabled
            CapturedAt      = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
        }
    } catch {
        Write-Log "[!] Error querying adapter '$InterfaceAlias': $_"
        return $null
    }
}

function Set-ActiveBaseline($Record) {
    $Global:NetworkTracker.OriginalInterface = $Record.InterfaceAlias
    $Global:NetworkTracker.OriginalIP      = $Record.OriginalIP
    $Global:NetworkTracker.OriginalMask    = $Record.OriginalMask
    $Global:NetworkTracker.OriginalGateway = $Record.OriginalGateway
    $Global:NetworkTracker.OriginalDNS     = $Record.OriginalDNS
    $Global:NetworkTracker.OriginalDHCP    = $Record.OriginalDHCP

    $lblOrigIpVal.Text   = $Record.OriginalIP
    $lblOrigMaskVal.Text = $Record.OriginalMask
    $lblBaselineVal.Text = "LOCKED — saved to disk on $($Record.CapturedAt)"
    $lblBaselineVal.ForeColor = [System.Drawing.Color]::Green
}

function Populate-InterfaceList {
    $prev = $lbInterfaces.SelectedItem
    $lbInterfaces.Items.Clear()
    try {
        $NetInterfaces = (Get-NetIPInterface -AddressFamily IPv4).InterfaceAlias | Sort-Object -Property Length
        foreach ($Name in $NetInterfaces) {
            if ($Name -notmatch "Local|Loopback|Bluetooth|Tunneling|Virtual|Pseudo") {
                [void]$lbInterfaces.Items.Add($Name)
            }
        }
        if ($prev -and $lbInterfaces.Items.Contains($prev)) {
            $lbInterfaces.SelectedItem = $prev
        }
        Write-Log "[*] Interface list refreshed ($($lbInterfaces.Items.Count) adapters)."
    } catch {
        Write-Log "[!] Could not query local network interfaces."
    }
}

$lbInterfaces.Add_SelectedIndexChanged({
    $SelectedInterface = $lbInterfaces.SelectedItem
    if ($null -eq $SelectedInterface) { return }

    $existing = Get-BaselineFor -ComputerName $Global:NetworkTracker.ComputerName -InterfaceAlias $SelectedInterface

    if ($null -ne $existing) {
        Set-ActiveBaseline $existing
        Write-Log "[*] Selected adapter '$SelectedInterface'. Loaded EXISTING locked baseline from disk (captured $($existing.CapturedAt)) — not overwritten."
        return
    }

    $captured = Get-LiveAdapterSettings -InterfaceAlias $SelectedInterface
    if ($null -eq $captured) {
        $lblOrigIpVal.Text = "Error Detecting"
        $lblOrigMaskVal.Text = "Error Detecting"
        $lblBaselineVal.Text = "NOT CAPTURED — query failed"
        $lblBaselineVal.ForeColor = [System.Drawing.Color]::Red
        Write-Log "[!] Could not capture a baseline for '$SelectedInterface'. Applying changes to this adapter is blocked until this succeeds."
        return
    }

    $saved = Set-BaselineFor $captured
    if ($saved) {
        Set-ActiveBaseline $captured
        Write-Log "[*] Selected adapter '$SelectedInterface'. NEW baseline captured and saved to disk: IP $($captured.OriginalIP) | Mask $($captured.OriginalMask) | DHCP $($captured.OriginalDHCP)"
    } else {
        $lblBaselineVal.Text = "NOT CAPTURED — failed to save to disk"
        $lblBaselineVal.ForeColor = [System.Drawing.Color]::Red
        Write-Log "[!] Captured adapter settings but FAILED to save baseline file. Applying changes to this adapter is blocked until this succeeds."
    }
})

$btnRefreshIfaces.Add_Click({ Populate-InterfaceList })

$btnRecaptureBaseline.Add_Click({
    $SelectedInterface = $lbInterfaces.SelectedItem
    if ($null -eq $SelectedInterface) {
        [System.Windows.Forms.MessageBox]::Show("Select an interface first.", "Nothing Selected", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning)
        return
    }

    $confirm = [System.Windows.Forms.MessageBox]::Show(
        "This will overwrite the SAVED restore point for '$SelectedInterface' with its CURRENT live settings.`n`nOnly do this if the adapter's current settings are what you actually want to be able to restore back to later.`n`nContinue?",
        "Confirm Baseline Overwrite",
        [System.Windows.Forms.MessageBoxButtons]::YesNo,
        [System.Windows.Forms.MessageBoxIcon]::Warning
    )
    if ($confirm -ne [System.Windows.Forms.DialogResult]::Yes) { return }

    $captured = Get-LiveAdapterSettings -InterfaceAlias $SelectedInterface
    if ($null -eq $captured) {
        Write-Log "[!] Recapture failed: could not query live settings for '$SelectedInterface'."
        [System.Windows.Forms.MessageBox]::Show("Could not read the adapter's current settings. Baseline was NOT changed.", "Recapture Failed", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error)
        return
    }

    if (Set-BaselineFor $captured) {
        Set-ActiveBaseline $captured
        Write-Log "[*] Baseline for '$SelectedInterface' RECAPTURED and overwritten: IP $($captured.OriginalIP) | Mask $($captured.OriginalMask)"
    } else {
        [System.Windows.Forms.MessageBox]::Show("Failed to save the new baseline to disk. The old baseline (if any) is still intact.", "Recapture Failed", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error)
    }
})

Populate-InterfaceList

$grpStaticFields = New-Object System.Windows.Forms.GroupBox
$grpStaticFields.Text = " 3. Custom Static Configuration Settings (Manual Mode Only) "
$grpStaticFields.Location = New-Object System.Drawing.Point(20, 395)
$grpStaticFields.Size = New-Object System.Drawing.Size(830, 230)
$grpStaticFields.Font = $FontBold
$grpStaticFields.Enabled = $false
$TabIP.Controls.Add($grpStaticFields)

$radCustom.Add_CheckedChanged({
    $grpStaticFields.Enabled = $radCustom.Checked
})

$lblStaticIP = New-Object System.Windows.Forms.Label
$lblStaticIP.Text = "Target IP Address:"
$lblStaticIP.Location = New-Object System.Drawing.Point(20, 40)
$lblStaticIP.Font = $FontBold
$lblStaticIP.AutoSize = $true
$grpStaticFields.Controls.Add($lblStaticIP)

$txtStaticIP = New-Object System.Windows.Forms.TextBox
$txtStaticIP.Location = New-Object System.Drawing.Point(180, 35)
$txtStaticIP.Size = New-Object System.Drawing.Size(200, 25)
$grpStaticFields.Controls.Add($txtStaticIP)

$lblSubnet = New-Object System.Windows.Forms.Label
$lblSubnet.Text = "Subnet Mask:"
$lblSubnet.Location = New-Object System.Drawing.Point(420, 40)
$lblSubnet.Font = $FontBold
$lblSubnet.AutoSize = $true
$grpStaticFields.Controls.Add($lblSubnet)

$cmbSubnet = New-Object System.Windows.Forms.ComboBox
$cmbSubnet.Location = New-Object System.Drawing.Point(580, 35)
$cmbSubnet.Size = New-Object System.Drawing.Size(200, 25)
$cmbSubnet.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDownList
[void]$cmbSubnet.Items.AddRange(@("255.255.255.0", "255.255.0.0", "255.0.0.0", "255.255.255.128", "255.255.255.192"))
$cmbSubnet.SelectedIndex = 0
$grpStaticFields.Controls.Add($cmbSubnet)

$lblGateway = New-Object System.Windows.Forms.Label
$lblGateway.Text = "Default Gateway:"
$lblGateway.Location = New-Object System.Drawing.Point(20, 95)
$lblGateway.Font = $FontBold
$lblGateway.AutoSize = $true
$grpStaticFields.Controls.Add($lblGateway)

$txtGateway = New-Object System.Windows.Forms.TextBox
$txtGateway.Location = New-Object System.Drawing.Point(180, 90)
$txtGateway.Size = New-Object System.Drawing.Size(200, 25)
$grpStaticFields.Controls.Add($txtGateway)

$lblDNS = New-Object System.Windows.Forms.Label
$lblDNS.Text = "Primary DNS Server:"
$lblDNS.Location = New-Object System.Drawing.Point(420, 95)
$lblDNS.Font = $FontBold
$lblDNS.AutoSize = $true
$grpStaticFields.Controls.Add($lblDNS)

$txtDNS = New-Object System.Windows.Forms.TextBox
$txtDNS.Location = New-Object System.Drawing.Point(580, 90)
$txtDNS.Size = New-Object System.Drawing.Size(200, 25)
$grpStaticFields.Controls.Add($txtDNS)

$txtGateway.Add_Leave({
    if ($radCustom.Checked -and [string]::IsNullOrWhiteSpace($txtDNS.Text)) {
        $txtDNS.Text = $txtGateway.Text
    }
})

$btnCheckIpFree = New-Object System.Windows.Forms.Button
$btnCheckIpFree.Text = "Check if Target IP is Free"
$btnCheckIpFree.Location = New-Object System.Drawing.Point(20, 140)
$btnCheckIpFree.Size = New-Object System.Drawing.Size(250, 35)
$btnCheckIpFree.BackColor = [System.Drawing.Color]::Teal
$btnCheckIpFree.ForeColor = [System.Drawing.Color]::White
$btnCheckIpFree.Font = $FontBold
$btnCheckIpFree.Add_Click({
    $candidate = $txtStaticIP.Text.Trim()
    if ([string]::IsNullOrWhiteSpace($candidate)) {
        [System.Windows.Forms.MessageBox]::Show("Enter a Target IP Address first.", "Nothing to Check", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning)
        return
    }
    Set-Progress 20
    Write-Log "[*] Checking whether $candidate is free on the LAN..."
    $probe = Test-IpAddressAvailability -IpAddress $candidate -SelectedInterface $lbInterfaces.SelectedItem
    Show-IpAvailabilityResult -ProbeResult $probe -IpAddress $candidate
    Set-Progress 100

    if ($probe.Status -eq "IN_USE" -or ($probe.Status -eq "OWNED_LOCALLY" -and -not $probe.Available)) {
        [System.Windows.Forms.MessageBox]::Show(
            "IP $candidate does NOT look free.`n`n$($probe.Detail)",
            "IP In Use",
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Warning
        )
    } elseif ($probe.Status -eq "LIKELY_FREE" -or ($probe.Status -eq "OWNED_LOCALLY" -and $probe.Available)) {
        [System.Windows.Forms.MessageBox]::Show(
            "IP $candidate looks available.`n`n$($probe.Detail)",
            "IP Likely Free",
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Information
        )
    } else {
        [System.Windows.Forms.MessageBox]::Show(
            "Could not determine availability for $candidate.`n`n$($probe.Detail)",
            "IP Check Incomplete",
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Warning
        )
    }
})
$grpStaticFields.Controls.Add($btnCheckIpFree)

$lblIpAvailTag = New-Object System.Windows.Forms.Label
$lblIpAvailTag.Text = "Availability:"
$lblIpAvailTag.Location = New-Object System.Drawing.Point(290, 148)
$lblIpAvailTag.Font = $FontBold
$lblIpAvailTag.AutoSize = $true
$grpStaticFields.Controls.Add($lblIpAvailTag)

$lblIpAvailVal = New-Object System.Windows.Forms.Label
$lblIpAvailVal.Text = "Not checked yet"
$lblIpAvailVal.Location = New-Object System.Drawing.Point(400, 148)
$lblIpAvailVal.Size = New-Object System.Drawing.Size(400, 25)
$lblIpAvailVal.Font = $FontRegular
$lblIpAvailVal.ForeColor = [System.Drawing.Color]::DimGray
$grpStaticFields.Controls.Add($lblIpAvailVal)

$lblIpAvailHint = New-Object System.Windows.Forms.Label
$lblIpAvailHint.Text = "Probes with ping + ARP. A reply/MAC means taken. No reply usually means free (ICMP-blocked hosts can hide)."
$lblIpAvailHint.Location = New-Object System.Drawing.Point(20, 185)
$lblIpAvailHint.Size = New-Object System.Drawing.Size(790, 30)
$lblIpAvailHint.Font = New-Object System.Drawing.Font("Segoe UI", 8)
$lblIpAvailHint.ForeColor = [System.Drawing.Color]::DimGray
$grpStaticFields.Controls.Add($lblIpAvailHint)

$btnApplyIPChange = New-Object System.Windows.Forms.Button
$btnApplyIPChange.Text = "Apply Network Profile Layout Changes"
$btnApplyIPChange.Location = New-Object System.Drawing.Point(20, 640)
$btnApplyIPChange.Size = New-Object System.Drawing.Size(830, 45)
$btnApplyIPChange.BackColor = [System.Drawing.Color]::DarkSlateBlue
$btnApplyIPChange.ForeColor = [System.Drawing.Color]::White
$btnApplyIPChange.Font = $FontBold
$btnApplyIPChange.Add_Click({
    $SelectedInterface = $lbInterfaces.SelectedItem

    if ($null -eq $SelectedInterface) {
        Write-Log "[!] IP Action Aborted: No target network interface selected."
        [System.Windows.Forms.MessageBox]::Show("Please select a target network interface before continuing.", "Validation Alert", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning)
        return
    }

    if (-not (Assert-AdminOrWarn "Apply IP Change")) { return }

    $baselineCheck = Get-BaselineFor -ComputerName $Global:NetworkTracker.ComputerName -InterfaceAlias $SelectedInterface
    if ($null -eq $baselineCheck) {
        Write-Log "[!] IP Action Aborted: No saved baseline exists for '$SelectedInterface'. Re-select the adapter in the list to capture one first."
        [System.Windows.Forms.MessageBox]::Show("No safe restore point has been saved for this adapter yet. Re-select it in the interface list first so a baseline can be captured, then try again.", "Baseline Required", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error)
        return
    }

    # Pre-flight: is the target static/APIPA address free on the wire?
    if ($chkCheckIpFree.Checked -and ($radCustom.Checked -or $radAPIPA.Checked)) {
        $candidateIp = if ($radCustom.Checked) { $txtStaticIP.Text.Trim() } else { "169.254.0.10" }
        if ($radCustom.Checked -and -not (Test-ValidIPv4 $candidateIp)) {
            Write-Log "[!] IP Action Aborted: Target IP is not a valid IPv4 address."
            [System.Windows.Forms.MessageBox]::Show("Enter a valid Target IP Address before applying.", "Validation Warning", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error)
            return
        }

        Write-Log "[*] Checking LAN availability for $candidateIp before apply..."
        Set-Progress 10
        $probe = Test-IpAddressAvailability -IpAddress $candidateIp -SelectedInterface $SelectedInterface
        if ($radCustom.Checked) { Show-IpAvailabilityResult -ProbeResult $probe -IpAddress $candidateIp }

        if ($probe.Status -eq "IN_USE" -or ($probe.Status -eq "OWNED_LOCALLY" -and -not $probe.Available)) {
            $conflict = [System.Windows.Forms.MessageBox]::Show(
                "WARNING: $candidateIp does not look free.`n`n$($probe.Detail)`n`nApplying it anyway can cause an IP conflict.`n`nApply anyway?",
                "IP Appears In Use",
                [System.Windows.Forms.MessageBoxButtons]::YesNo,
                [System.Windows.Forms.MessageBoxIcon]::Warning
            )
            if ($conflict -ne [System.Windows.Forms.DialogResult]::Yes) {
                Write-Log "[*] IP Action cancelled — target address appears in use."
                Set-Progress 0
                return
            }
            Write-Log "[!] Operator overrode availability warning for $candidateIp."
        } elseif ($probe.Status -eq "LIKELY_FREE" -or ($probe.Status -eq "OWNED_LOCALLY" -and $probe.Available)) {
            Write-Log "[+] Availability check passed for $candidateIp ($($probe.Status))."
        } else {
            $unknown = [System.Windows.Forms.MessageBox]::Show(
                "Could not fully confirm whether $candidateIp is free.`n`n$($probe.Detail)`n`nContinue applying anyway?",
                "IP Check Incomplete",
                [System.Windows.Forms.MessageBoxButtons]::YesNo,
                [System.Windows.Forms.MessageBoxIcon]::Question
            )
            if ($unknown -ne [System.Windows.Forms.DialogResult]::Yes) {
                Write-Log "[*] IP Action cancelled — availability check incomplete."
                Set-Progress 0
                return
            }
        }
    }

    $confirm = [System.Windows.Forms.MessageBox]::Show(
        "About to change IP settings on adapter '$SelectedInterface'.`n`nA saved restore point exists (captured $($baselineCheck.CapturedAt)): $($baselineCheck.OriginalIP) / $($baselineCheck.OriginalMask).`n`nContinue applying the change?",
        "Confirm IP Change",
        [System.Windows.Forms.MessageBoxButtons]::YesNo,
        [System.Windows.Forms.MessageBoxIcon]::Question
    )
    if ($confirm -ne [System.Windows.Forms.DialogResult]::Yes) {
        Write-Log "[*] IP Action cancelled by user at confirmation prompt."
        return
    }

    Set-Progress 15
    Write-Log "[*] Tracking profile assignment data for machine: $($Global:NetworkTracker.ComputerName)"
    Write-Log "[*] Preserving current recorded source IP: $($Global:NetworkTracker.OriginalIP) | Mask: $($Global:NetworkTracker.OriginalMask)"

    try {
        $InterfaceIndex = (Get-NetIPConfiguration | Where-Object InterfaceAlias -eq $SelectedInterface).InterfaceIndex

        if ($radDHCP.Checked) {
            $Global:NetworkTracker.AssignedTempIP = "DHCP Assigned"
            Set-Progress 40
            Write-Log "[*] Switching adapter configurations over to Automated DHCP..."
            netsh.exe interface ipv4 set address name=$SelectedInterface source=dhcp
            netsh.exe interface ipv4 set dnsservers name=$SelectedInterface source=dhcp

            Set-Progress 80
            Wait-Responsive 3

            $newIP = (Get-NetIPConfiguration | Where-Object InterfaceIndex -eq $InterfaceIndex).IPv4Address.IPAddress
            Write-Log "[ SUCCESS ] Automated DHCP conversion applied. Current Dynamic IP: $newIP"
            Set-Progress 100
        }
        elseif ($radAPIPA.Checked) {
            $apipaIP   = "169.254.0.10"
            $apipaMask = "255.255.255.0"
            $apipaGW   = "169.254.0.1"
            $Global:NetworkTracker.AssignedTempIP = $apipaIP

            Set-Progress 40
            Write-Log "[*] Setting emergency local APIPA static assignments..."
            netsh.exe interface ipv4 set address name=$SelectedInterface source=static addr=$apipaIP mask=$apipaMask gateway=$apipaGW gwmetric=1
            netsh.exe interface ipv4 set dns name=$SelectedInterface source=static addr=$apipaGW

            Set-Progress 80
            Wait-Responsive 3

            Write-Log "[ SUCCESS ] APIPA Profile established. Local IP configured to: $apipaIP"
            Set-Progress 100
        }
        elseif ($radCustom.Checked) {
            $targetIP = $txtStaticIP.Text.Trim()
            $targetSM = $cmbSubnet.SelectedItem
            $targetGW = $txtGateway.Text.Trim()
            $targetDNS = $txtDNS.Text.Trim()

            if ([string]::IsNullOrEmpty($targetIP) -or [string]::IsNullOrEmpty($targetGW) -or [string]::IsNullOrEmpty($targetDNS)) {
                Write-Log "[!] Manual Assignment Error: Empty values inside critical parameters."
                [System.Windows.Forms.MessageBox]::Show("Blank configurations detected. Please complete all custom manual text fields.", "Validation Warning", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error)
                Set-Progress 0
                return
            }

            if (-not (Test-ValidIPv4 $targetIP) -or -not (Test-ValidIPv4 $targetGW) -or -not (Test-ValidIPv4 $targetDNS)) {
                Write-Log "[!] Manual Assignment Error: Formatting mismatch on input target addresses."
                [System.Windows.Forms.MessageBox]::Show("Invalid IPv4 address configurations. Double check your settings and retry.", "Validation Warning", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error)
                Set-Progress 0
                return
            }

            $Global:NetworkTracker.AssignedTempIP = $targetIP
            Set-Progress 50
            Write-Log "[*] Programming Static Route: IP: $targetIP | Mask: $targetSM | GW: $targetGW"
            netsh.exe interface ipv4 set address name=$SelectedInterface source=static addr=$targetIP mask=$targetSM gateway=$targetGW gwmetric=1
            netsh.exe interface ipv4 set dns name=$SelectedInterface source=static addr=$targetDNS

            Set-Progress 80
            Wait-Responsive 3

            Write-Log "[ SUCCESS ] Manual static interface updates processed. Target Route Live on: $targetIP"
            Set-Progress 100
        }

        if ($chkVerifyAfter.Checked) {
            $live = Get-LiveIPv4OnAdapter -InterfaceAlias $SelectedInterface
            if ($live) {
                $lblLiveIpHint.Text = "Live IP after change: $live"
                $lblLiveIpHint.ForeColor = [System.Drawing.Color]::DarkGreen
                Write-Log "[ VERIFY ] Live IPv4 on '$SelectedInterface': $live"
            } else {
                $lblLiveIpHint.Text = "Live IP after change: (could not read)"
                $lblLiveIpHint.ForeColor = [System.Drawing.Color]::DarkOrange
                Write-Log "[!] Could not verify live IP after apply."
            }
        }

        Write-Log "[ DATA PRESERVED ] Tracker State -> Host: $($Global:NetworkTracker.ComputerName) | Baseline IP: $($Global:NetworkTracker.OriginalIP) | Mask: $($Global:NetworkTracker.OriginalMask) | Active Temp IP: $($Global:NetworkTracker.AssignedTempIP)"

        Write-DeploymentHistory -SelectedAdapter $SelectedInterface `
            -OriginalIP $Global:NetworkTracker.OriginalIP `
            -OriginalMask $Global:NetworkTracker.OriginalMask `
            -AssignedTempIP $Global:NetworkTracker.AssignedTempIP
    }
    catch {
        Write-Log "[!] Critical tracking failure modifying IP credentials: $_"
        Set-Progress 0
    }
})
$TabIP.Controls.Add($btnApplyIPChange)

# -----------------------------------------------------------------------------
# TAB 2 — AV UPDATE
# -----------------------------------------------------------------------------

New-Label $TabAV "AV Update (mpam-fe.exe)" 20 20

$txtAVDir = New-Object System.Windows.Forms.TextBox
$txtAVDir.Location = New-Object System.Drawing.Point(20, 50)
$txtAVDir.Size = New-Object System.Drawing.Size(300, 25)
$txtAVDir.Text = $Global:AVDir
$TabAV.Controls.Add($txtAVDir)

$btnAVBrowse = New-Object System.Windows.Forms.Button
$btnAVBrowse.Text = "Browse..."
$btnAVBrowse.Location = New-Object System.Drawing.Point(330, 50)
$btnAVBrowse.Size = New-Object System.Drawing.Size(80, 25)
$btnAVBrowse.Add_Click({
    $dialog = New-Object System.Windows.Forms.FolderBrowserDialog
    if ($dialog.ShowDialog() -eq "OK") {
        $Global:AVDir = $dialog.SelectedPath
        $txtAVDir.Text = $Global:AVDir
        $Global:ToolConfig.AVDir = $Global:AVDir
        Save-ToolConfig $Global:ToolConfig | Out-Null
    }
})
$TabAV.Controls.Add($btnAVBrowse)

$grpAVStatus = New-Object System.Windows.Forms.GroupBox
$grpAVStatus.Text = " Current System AV Status "
$grpAVStatus.Location = New-Object System.Drawing.Point(20, 150)
$grpAVStatus.Size = New-Object System.Drawing.Size(390, 180)
$grpAVStatus.Font = $FontBold
$TabAV.Controls.Add($grpAVStatus)

$lblAVNameTag = New-Object System.Windows.Forms.Label
$lblAVNameTag.Text = "Active AntiVirus:"
$lblAVNameTag.Location = New-Object System.Drawing.Point(15, 30)
$lblAVNameTag.AutoSize = $true
$grpAVStatus.Controls.Add($lblAVNameTag)

$lblAVNameVal = New-Object System.Windows.Forms.Label
$lblAVNameVal.Text = "Detecting..."
$lblAVNameVal.Location = New-Object System.Drawing.Point(160, 30)
$lblAVNameVal.AutoSize = $true
$lblAVNameVal.Font = $FontRegular
$grpAVStatus.Controls.Add($lblAVNameVal)

$lblAVVerTag = New-Object System.Windows.Forms.Label
$lblAVVerTag.Text = "Product Version:"
$lblAVVerTag.Location = New-Object System.Drawing.Point(15, 65)
$lblAVVerTag.AutoSize = $true
$grpAVStatus.Controls.Add($lblAVVerTag)

$lblAVVerVal = New-Object System.Windows.Forms.Label
$lblAVVerVal.Text = "Detecting..."
$lblAVVerVal.Location = New-Object System.Drawing.Point(160, 65)
$lblAVVerVal.AutoSize = $true
$lblAVVerVal.Font = $FontRegular
$grpAVStatus.Controls.Add($lblAVVerVal)

$lblAVDateTag = New-Object System.Windows.Forms.Label
$lblAVDateTag.Text = "Last Update Date:"
$lblAVDateTag.Location = New-Object System.Drawing.Point(15, 100)
$lblAVDateTag.AutoSize = $true
$grpAVStatus.Controls.Add($lblAVDateTag)

$lblAVDateVal = New-Object System.Windows.Forms.Label
$lblAVDateVal.Text = "Detecting..."
$lblAVDateVal.Location = New-Object System.Drawing.Point(160, 100)
$lblAVDateVal.AutoSize = $true
$lblAVDateVal.Font = $FontRegular
$grpAVStatus.Controls.Add($lblAVDateVal)

$lblAVSigTag = New-Object System.Windows.Forms.Label
$lblAVSigTag.Text = "Signature Age:"
$lblAVSigTag.Location = New-Object System.Drawing.Point(15, 135)
$lblAVSigTag.AutoSize = $true
$grpAVStatus.Controls.Add($lblAVSigTag)

$lblAVSigVal = New-Object System.Windows.Forms.Label
$lblAVSigVal.Text = "Detecting..."
$lblAVSigVal.Location = New-Object System.Drawing.Point(160, 135)
$lblAVSigVal.AutoSize = $true
$lblAVSigVal.Font = $FontRegular
$grpAVStatus.Controls.Add($lblAVSigVal)

function Refresh-AVStatus {
    try {
        $mpStatus = Get-MpComputerStatus -ErrorAction SilentlyContinue
        if ($mpStatus) {
            $lblAVNameVal.Text  = "Windows Defender"
            $lblAVVerVal.Text   = $mpStatus.AMProductVersion
            $lblAVDateVal.Text  = if ($mpStatus.AntivirusSignatureLastUpdated) { $mpStatus.AntivirusSignatureLastUpdated.ToString() } else { "Unknown" }
            if ($mpStatus.AntivirusSignatureLastUpdated) {
                $age = (Get-Date) - $mpStatus.AntivirusSignatureLastUpdated
                $lblAVSigVal.Text = "{0}d {1}h old" -f [int]$age.TotalDays, $age.Hours
                if ($age.TotalDays -gt 7) {
                    $lblAVSigVal.ForeColor = [System.Drawing.Color]::DarkRed
                } elseif ($age.TotalDays -gt 2) {
                    $lblAVSigVal.ForeColor = [System.Drawing.Color]::DarkOrange
                } else {
                    $lblAVSigVal.ForeColor = [System.Drawing.Color]::DarkGreen
                }
            } else {
                $lblAVSigVal.Text = "Unknown"
            }
        } else {
            $wmiAV = Get-CimInstance -Namespace "root\SecurityCenter2" -ClassName "AntiVirusProduct" -ErrorAction SilentlyContinue
            if ($wmiAV) {
                $lblAVNameVal.Text = ($wmiAV | Select-Object -First 1).displayName
                $lblAVVerVal.Text  = "Managed by third-party"
                $lblAVDateVal.Text = "External provider tracking"
                $lblAVSigVal.Text  = "N/A"
            } else {
                $lblAVNameVal.Text = "No Active AV Registered"
                $lblAVVerVal.Text  = "N/A"
                $lblAVDateVal.Text = "N/A"
                $lblAVSigVal.Text  = "N/A"
            }
        }
    } catch {
        $lblAVNameVal.Text = "Error query"
        $lblAVVerVal.Text  = "Error query"
        $lblAVDateVal.Text = "Error query"
        $lblAVSigVal.Text  = "Error query"
    }
}

$btnRefreshAV = New-Object System.Windows.Forms.Button
$btnRefreshAV.Text = "Refresh AV Status"
$btnRefreshAV.Location = New-Object System.Drawing.Point(430, 150)
$btnRefreshAV.Size = New-Object System.Drawing.Size(200, 35)
$btnRefreshAV.Add_Click({
    Refresh-AVStatus
    Write-Log "[*] AV status refreshed."
})
$TabAV.Controls.Add($btnRefreshAV)

$btnRunAV = New-Object System.Windows.Forms.Button
$btnRunAV.Text = "Run AV Update"
$btnRunAV.Location = New-Object System.Drawing.Point(20, 90)
$btnRunAV.Size = New-Object System.Drawing.Size(390, 40)
$btnRunAV.BackColor = [System.Drawing.Color]::DarkGreen
$btnRunAV.ForeColor = [System.Drawing.Color]::White
$btnRunAV.Font = $FontBold
$btnRunAV.Add_Click({
    if (-not (Assert-AdminOrWarn "AV Update")) { return }
    Set-Progress 10
    Write-Log "[*] Starting AV Update..."

    $Global:AVDir = $txtAVDir.Text.Trim()
    $AVPath = Join-Path $Global:AVDir "mpam-fe.exe"

    if (Test-Path $AVPath) {
        Set-Progress 40
        Write-Log "[+] Running mpam-fe.exe..."
        Start-ProcessResponsive -FilePath $AVPath -ArgumentList "-q" -NoNewWindow
        Set-Progress 70
        Refresh-AVStatus
        Write-Log "[+] AV Updated. Current Timestamp: $($lblAVDateVal.Text)"
        Set-Progress 100
    } else {
        Write-Log "[!] ERROR: mpam-fe.exe not found at $AVPath"
        Set-Progress 0
    }
})
$TabAV.Controls.Add($btnRunAV)

# -----------------------------------------------------------------------------
# TAB 3 — AGENT INSTALL + LINK
# -----------------------------------------------------------------------------

New-Label $TabAgent "Nessus Agent Install + Link" 20 20

$txtAgentDir = New-Object System.Windows.Forms.TextBox
$txtAgentDir.Location = New-Object System.Drawing.Point(20, 50)
$txtAgentDir.Size = New-Object System.Drawing.Size(300, 25)
$txtAgentDir.Text = $Global:AgentDir
$TabAgent.Controls.Add($txtAgentDir)

$btnAgentBrowse = New-Object System.Windows.Forms.Button
$btnAgentBrowse.Text = "Browse..."
$btnAgentBrowse.Location = New-Object System.Drawing.Point(330, 50)
$btnAgentBrowse.Size = New-Object System.Drawing.Size(80, 25)
$btnAgentBrowse.Add_Click({
    $dialog = New-Object System.Windows.Forms.FolderBrowserDialog
    if ($dialog.ShowDialog() -eq "OK") {
        $Global:AgentDir = $dialog.SelectedPath
        $txtAgentDir.Text = $Global:AgentDir
        $Global:ToolConfig.AgentDir = $Global:AgentDir
        Save-ToolConfig $Global:ToolConfig | Out-Null
    }
})
$TabAgent.Controls.Add($btnAgentBrowse)

$lblMsiDetected = New-Object System.Windows.Forms.Label
$lblMsiDetected.Text = "MSI: (not scanned yet)"
$lblMsiDetected.Location = New-Object System.Drawing.Point(420, 55)
$lblMsiDetected.Size = New-Object System.Drawing.Size(450, 20)
$lblMsiDetected.Font = $FontRegular
$lblMsiDetected.ForeColor = [System.Drawing.Color]::DimGray
$TabAgent.Controls.Add($lblMsiDetected)

function Update-MsiLabel {
    $msi = Find-NessusAgentMsi -SearchDir $Global:AgentDir
    if ($msi) {
        $lblMsiDetected.Text = "MSI: $($msi.Name)"
        $lblMsiDetected.ForeColor = [System.Drawing.Color]::DarkGreen
    } else {
        $lblMsiDetected.Text = "MSI: none found in folder"
        $lblMsiDetected.ForeColor = [System.Drawing.Color]::DarkRed
    }
}

$btnDetectFiles = New-Object System.Windows.Forms.Button
$btnDetectFiles.Text = "Auto-Detect Installer Files"
$btnDetectFiles.Location = New-Object System.Drawing.Point(20, 85)
$btnDetectFiles.Size = New-Object System.Drawing.Size(390, 30)
$btnDetectFiles.BackColor = [System.Drawing.Color]::Green
$btnDetectFiles.ForeColor = [System.Drawing.Color]::White
$btnDetectFiles.Font = $FontBold
$btnDetectFiles.Add_Click({
    Write-Log "[*] Scanning folder for installer files..."
    Set-Progress 20
    $Global:AgentDir = $txtAgentDir.Text.Trim()
    $Global:AVDir = $txtAVDir.Text.Trim()

    $msi = Find-NessusAgentMsi
    $av = Get-ChildItem $Global:AVDir -Filter "mpam-fe.exe" -ErrorAction SilentlyContinue

    if ($msi) { Write-Log "[+] Found agent installer: $($msi.Name)" } else { Write-Log "[!] No NessusAgent MSI found." }
    if ($av) { Write-Log "[+] Found AV update: $($av.Name)" } else { Write-Log "[!] No mpam-fe.exe found." }
    Update-MsiLabel
    Set-Progress 100
})
$TabAgent.Controls.Add($btnDetectFiles)

New-Label $TabAgent "Scanner IP:" 20 125
$txtScannerIP = New-Object System.Windows.Forms.TextBox
$txtScannerIP.Location = New-Object System.Drawing.Point(20, 150)
$txtScannerIP.Size = New-Object System.Drawing.Size(280, 25)
$txtScannerIP.Text = $Global:RHELTargetHost
$TabAgent.Controls.Add($txtScannerIP)

New-Label $TabAgent "Port:" 310 125
$txtLinkPort = New-Object System.Windows.Forms.TextBox
$txtLinkPort.Location = New-Object System.Drawing.Point(310, 150)
$txtLinkPort.Size = New-Object System.Drawing.Size(100, 25)
$txtLinkPort.Text = "$($Global:AgentLinkPort)"
$TabAgent.Controls.Add($txtLinkPort)

New-Label $TabAgent "Linking Key:" 20 185
$txtKey = New-Object System.Windows.Forms.TextBox
$txtKey.Location = New-Object System.Drawing.Point(20, 210)
$txtKey.Size = New-Object System.Drawing.Size(390, 25)
$txtKey.UseSystemPasswordChar = $true
if (-not [string]::IsNullOrWhiteSpace($env:NESSUS_LINK_KEY)) {
    $txtKey.Text = $env:NESSUS_LINK_KEY
}
$TabAgent.Controls.Add($txtKey)

New-Label $TabAgent "Groups (Optional - Comma separated):" 20 245
$txtGroups = New-Object System.Windows.Forms.TextBox
$txtGroups.Location = New-Object System.Drawing.Point(20, 270)
$txtGroups.Size = New-Object System.Drawing.Size(390, 25)
if ($Global:ToolConfig.LastGroups) { $txtGroups.Text = [string]$Global:ToolConfig.LastGroups }
$TabAgent.Controls.Add($txtGroups)

function Sync-ScannerFromUi {
    $Global:RHELTargetHost = $txtScannerIP.Text.Trim()
    $portParsed = 0
    if ([int]::TryParse($txtLinkPort.Text.Trim(), [ref]$portParsed) -and $portParsed -gt 0) {
        $Global:AgentLinkPort = $portParsed
    }
    $Global:ToolConfig.RHELTargetHost = $Global:RHELTargetHost
    $Global:ToolConfig.AgentLinkPort  = $Global:AgentLinkPort
    $Global:ToolConfig.LastGroups     = $txtGroups.Text.Trim()
    Save-ToolConfig $Global:ToolConfig | Out-Null
    Update-StatusStrip
}

$btnInstallAgent = New-Object System.Windows.Forms.Button
$btnInstallAgent.Text = "Install Nessus Agent"
$btnInstallAgent.Location = New-Object System.Drawing.Point(20, 310)
$btnInstallAgent.Size = New-Object System.Drawing.Size(390, 35)
$btnInstallAgent.BackColor = [System.Drawing.Color]::SteelBlue
$btnInstallAgent.ForeColor = [System.Drawing.Color]::White
$btnInstallAgent.Font = $FontBold
$btnInstallAgent.Add_Click({
    if (-not (Assert-AdminOrWarn "Install Nessus Agent")) { return }
    Set-Progress 10
    Write-Log "[*] Installing Nessus Agent..."
    $Global:AgentDir = $txtAgentDir.Text.Trim()
    $msi = Find-NessusAgentMsi
    if ($msi) {
        Write-Log "[+] Using MSI: $($msi.FullName)"
        Set-Progress 40
        $proc = Start-ProcessResponsive -FilePath "msiexec.exe" -ArgumentList "/i `"$($msi.FullName)`" /qn /norestart"
        Set-Progress 80
        if ($proc.ExitCode -eq 0 -or $null -eq $proc.ExitCode) {
            Write-Log "[+] Agent Installed (exit $($proc.ExitCode))."
        } else {
            Write-Log "[!] msiexec exited with code $($proc.ExitCode). Check if agent is already installed."
        }
        Set-Progress 100
    } else {
        Write-Log "[!] ERROR: No NessusAgent*.msi found in $Global:AgentDir"
        Set-Progress 0
    }
})
$TabAgent.Controls.Add($btnInstallAgent)

$btnLinkAgent = New-Object System.Windows.Forms.Button
$btnLinkAgent.Text = "Link Agent"
$btnLinkAgent.Location = New-Object System.Drawing.Point(20, 355)
$btnLinkAgent.Size = New-Object System.Drawing.Size(390, 35)
$btnLinkAgent.BackColor = [System.Drawing.Color]::DarkOrange
$btnLinkAgent.ForeColor = [System.Drawing.Color]::White
$btnLinkAgent.Font = $FontBold
$btnLinkAgent.Add_Click({
    if ([string]::IsNullOrWhiteSpace($txtKey.Text)) {
        Write-Log "[!] Link Aborted: No linking key provided."
        [System.Windows.Forms.MessageBox]::Show("Please enter a linking key before linking the agent.", "Validation Alert", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning)
        return
    }

    Sync-ScannerFromUi
    if (-not (Assert-AdminOrWarn "Link Agent")) { return }

    Set-Progress 10
    Write-Log "[*] Linking Agent..."

    $NessusCli = $Global:NessusCliPath
    if (Test-Path $NessusCli) {
        Set-Progress 40
        $cmd = "agent link --key=$($txtKey.Text) --host=$($txtScannerIP.Text.Trim()) --port=$($Global:AgentLinkPort)"

        if (-not [string]::IsNullOrWhiteSpace($txtGroups.Text)) {
            $cmd += " --groups=`"$($txtGroups.Text.Trim())`""
        }

        Write-Log "[+] Running: nessuscli.exe agent link --key=**** --host=$($txtScannerIP.Text.Trim()) --port=$($Global:AgentLinkPort)"
        Start-ProcessResponsive -FilePath $NessusCli -ArgumentList $cmd -NoNewWindow

        Set-Progress 70
        Wait-Responsive 2
        $svc = Get-Service -Name "Tenable Nessus Agent" -ErrorAction SilentlyContinue
        if ($svc -and $svc.Status -ne "Running") {
            Start-Service -Name "Tenable Nessus Agent" -ErrorAction SilentlyContinue
        }

        Set-Progress 100
        Write-Log "[+] Agent link command completed. Use Check Agent Status to confirm."
    } else {
        Write-Log "[!] ERROR: nessuscli.exe not found at $NessusCli"
        Set-Progress 0
    }
})
$TabAgent.Controls.Add($btnLinkAgent)

$btnCheckAgent = New-Object System.Windows.Forms.Button
$btnCheckAgent.Text = "Check Agent Status"
$btnCheckAgent.Location = New-Object System.Drawing.Point(20, 400)
$btnCheckAgent.Size = New-Object System.Drawing.Size(390, 35)
$btnCheckAgent.BackColor = [System.Drawing.Color]::SlateGray
$btnCheckAgent.ForeColor = [System.Drawing.Color]::White
$btnCheckAgent.Font = $FontBold
$btnCheckAgent.Add_Click({
    Write-Log "========================================"
    Write-Log "          NESSUS AGENT STATUS           "
    Write-Log "========================================"
    $NessusCli = $Global:NessusCliPath
    if (Test-Path $NessusCli) {
        $tmpFile = Join-Path $env:TEMP "nessus_status.tmp"
        Start-ProcessResponsive -FilePath $NessusCli -ArgumentList "agent status" -NoNewWindow -RedirectStandardOutput $tmpFile
        $statusText = Get-Content $tmpFile -ErrorAction SilentlyContinue
        foreach ($line in $statusText) {
            if ($line -match "Running:\s*(.*)") { Write-Log "  Status:      $($Matches[1].Trim())" }
            elseif ($line -match "Linked to:\s*(.*)") { Write-Log "  Linked To:   $($Matches[1].Trim())" }
            elseif ($line -match "Link status:\s*(.*)") { Write-Log "  Link State:  $($Matches[1].Trim())" }
            elseif ($line -match "Last successful connection\s*:\s*(.*)") { Write-Log "  Last Conn:   $($Matches[1].Trim())" }
            elseif ($line -match "Last synchronized\s*:\s*(.*)") { Write-Log "  Last Sync:   $($Matches[1].Trim())" }
            else { Write-Log "  $line" }
        }
        Remove-Item $tmpFile -ErrorAction SilentlyContinue
    } else {
        Write-Log "  [!] ERROR: Nessus Agent is not installed."
    }
    Write-Log "========================================"
})
$TabAgent.Controls.Add($btnCheckAgent)

# One-click deploy suite
$btnDeploySuite = New-Object System.Windows.Forms.Button
$btnDeploySuite.Text = "One-Click: AV Update + Install + Link"
$btnDeploySuite.Location = New-Object System.Drawing.Point(430, 310)
$btnDeploySuite.Size = New-Object System.Drawing.Size(420, 80)
$btnDeploySuite.BackColor = [System.Drawing.Color]::MidnightBlue
$btnDeploySuite.ForeColor = [System.Drawing.Color]::White
$btnDeploySuite.Font = $FontBold
$btnDeploySuite.Add_Click({
    if ([string]::IsNullOrWhiteSpace($txtKey.Text)) {
        [System.Windows.Forms.MessageBox]::Show("Enter a linking key first.", "Validation", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning)
        return
    }
    if (-not (Assert-AdminOrWarn "One-Click Deploy")) { return }
    if (-not (Confirm-DestructiveAction "Confirm One-Click Deploy" "This will:`n1) Run mpam-fe.exe AV update`n2) Install the newest NessusAgent*.msi`n3) Link the agent to $($txtScannerIP.Text.Trim()):$($txtLinkPort.Text)`n`nContinue?")) {
        return
    }

    Sync-ScannerFromUi
    Set-Progress 5
    Write-Log "[*] === ONE-CLICK DEPLOY START ==="

    # AV
    $AVPath = Join-Path $txtAVDir.Text.Trim() "mpam-fe.exe"
    if (Test-Path $AVPath) {
        Write-Log "[*] Step 1/3: AV update..."
        Start-ProcessResponsive -FilePath $AVPath -ArgumentList "-q" -NoNewWindow
        Refresh-AVStatus
        Write-Log "[+] AV update done."
    } else {
        Write-Log "[!] Step 1/3 skipped — mpam-fe.exe missing."
    }
    Set-Progress 30

    # Install
    $msi = Find-NessusAgentMsi -SearchDir $txtAgentDir.Text.Trim()
    if (-not $msi) {
        Write-Log "[!] Step 2/3 FAILED — no MSI found. Aborting."
        Set-Progress 0
        return
    }
    Write-Log "[*] Step 2/3: Installing $($msi.Name)..."
    Start-ProcessResponsive -FilePath "msiexec.exe" -ArgumentList "/i `"$($msi.FullName)`" /qn /norestart"
    Wait-Responsive 3
    Set-Progress 65

    # Link
    if (-not (Test-Path $Global:NessusCliPath)) {
        Write-Log "[!] Step 3/3 FAILED — nessuscli.exe not found after install."
        Set-Progress 0
        return
    }
    Write-Log "[*] Step 3/3: Linking agent..."
    $cmd = "agent link --key=$($txtKey.Text) --host=$($txtScannerIP.Text.Trim()) --port=$($Global:AgentLinkPort)"
    if (-not [string]::IsNullOrWhiteSpace($txtGroups.Text)) {
        $cmd += " --groups=`"$($txtGroups.Text.Trim())`""
    }
    Start-ProcessResponsive -FilePath $Global:NessusCliPath -ArgumentList $cmd -NoNewWindow
    Wait-Responsive 2
    $svc = Get-Service -Name "Tenable Nessus Agent" -ErrorAction SilentlyContinue
    if ($svc -and $svc.Status -ne "Running") {
        Start-Service -Name "Tenable Nessus Agent" -ErrorAction SilentlyContinue
    }

    Set-Progress 100
    Write-Log "[+] === ONE-CLICK DEPLOY COMPLETE — verify with Check Agent Status ==="
})
$TabAgent.Controls.Add($btnDeploySuite)

# Sync Time
$lblManualTime = New-Object System.Windows.Forms.Label
$lblManualTime.Text = "Enter Manual Date & Time (YYYY-MM-DD HH:MM):"
$lblManualTime.Location = New-Object System.Drawing.Point(20, 445)
$lblManualTime.Size = New-Object System.Drawing.Size(390, 20)
$lblManualTime.Font = $FontBold
$TabAgent.Controls.Add($lblManualTime)

$txtManualTime = New-Object System.Windows.Forms.TextBox
$txtManualTime.Location = New-Object System.Drawing.Point(20, 470)
$txtManualTime.Size = New-Object System.Drawing.Size(390, 25)
$txtManualTime.Text = (Get-Date -Format "yyyy-MM-dd HH:mm")
$TabAgent.Controls.Add($txtManualTime)

$btnSyncTime = New-Object System.Windows.Forms.Button
$btnSyncTime.Text = "Change Target Computer Time"
$btnSyncTime.Location = New-Object System.Drawing.Point(20, 505)
$btnSyncTime.Size = New-Object System.Drawing.Size(390, 35)
$btnSyncTime.BackColor = [System.Drawing.Color]::SteelBlue
$btnSyncTime.ForeColor = [System.Drawing.Color]::White
$btnSyncTime.Font = $FontBold
$btnSyncTime.Add_Click({
    if (-not (Assert-AdminOrWarn "Change System Time")) { return }
    if (-not (Confirm-DestructiveAction "Confirm Clock Change" "This changes the LOCAL system clock to:`n$($txtManualTime.Text)`n`nContinue?")) { return }
    try {
        $ParsedTime = [System.DateTime]::Parse($txtManualTime.Text)
        Write-Log "[*] Manually changing system clock to: $($ParsedTime.ToString('yyyy-MM-dd HH:mm'))..."
        Set-Date -Date $ParsedTime | Out-Null
        Write-Log "[+] System time successfully changed."
    }
    catch {
        Write-Log "[!] Error parsing date/time. Make sure it matches: YYYY-MM-DD HH:MM"
    }
})
$TabAgent.Controls.Add($btnSyncTime)

$btnAutoFix = New-Object System.Windows.Forms.Button
$btnAutoFix.Text = "Auto-Fix Agent Problems (Remote)"
$btnAutoFix.Location = New-Object System.Drawing.Point(20, 555)
$btnAutoFix.Size = New-Object System.Drawing.Size(390, 30)
$btnAutoFix.BackColor = [System.Drawing.Color]::DarkRed
$btnAutoFix.ForeColor = [System.Drawing.Color]::White
$btnAutoFix.Font = $FontBold
$btnAutoFix.Add_Click({
    Sync-ScannerFromUi
    Set-Progress 20
    Write-Log "[*] Executing Remote Agent Diagnostic Auto-Fix on $($Global:RHELTargetHost)..."
    $result = Invoke-SshRemote "sudo systemctl restart nessusd"
    Write-Log "[*] Remote response: $result"
    Set-Progress 100
    Write-Log "[+] Remote Linux services recycle attempted."
})
$TabAgent.Controls.Add($btnAutoFix)

$btnServiceCheck = New-Object System.Windows.Forms.Button
$btnServiceCheck.Text = "Check Agent Service Health (Remote)"
$btnServiceCheck.Location = New-Object System.Drawing.Point(20, 595)
$btnServiceCheck.Size = New-Object System.Drawing.Size(390, 30)
$btnServiceCheck.BackColor = [System.Drawing.Color]::DarkBlue
$btnServiceCheck.ForeColor = [System.Drawing.Color]::White
$btnServiceCheck.Font = $FontBold
$btnServiceCheck.Add_Click({
    Sync-ScannerFromUi
    Set-Progress 20
    Write-Log "[*] Checking remote Tenable services on $($Global:RHELTargetHost)..."

    $Status = Invoke-SshRemote "sudo systemctl is-active nessusd"
    Write-Log "Remote Service: nessusd — Status: $Status"

    if ($Status -ne "active") {
        Write-Log "[*] Starting nessusd on remote target..."
        Invoke-SshRemote "sudo systemctl start nessusd" | Out-Null
        Set-Progress 100
        Write-Log "[+] Start command issued."
    } else {
        Set-Progress 100
        Write-Log "[+] Service health check complete. Component is already running."
    }
})
$TabAgent.Controls.Add($btnServiceCheck)

# -----------------------------------------------------------------------------
# TAB 4 — DEEP CLEANUP
# -----------------------------------------------------------------------------

New-Label $TabCleanup "Deep Cleanup — Component Stripper" 20 20

$btnUnlink = New-Object System.Windows.Forms.Button
$btnUnlink.Text = "Unlink Agent"
$btnUnlink.Location = New-Object System.Drawing.Point(20, 60)
$btnUnlink.Size = New-Object System.Drawing.Size(390, 40)
$btnUnlink.BackColor = [System.Drawing.Color]::DarkOrange
$btnUnlink.ForeColor = [System.Drawing.Color]::White
$btnUnlink.Font = $FontBold
$btnUnlink.Add_Click({
    if (-not (Confirm-DestructiveAction "Confirm Unlink" "Unlink this host from the Nessus manager?")) { return }
    Set-Progress 20
    Write-Log "[*] Unlinking agent..."
    $NessusCli = $Global:NessusCliPath
    if (Test-Path $NessusCli) {
        Start-ProcessResponsive -FilePath $NessusCli -ArgumentList "agent unlink"
        Set-Progress 80
        Write-Log "[+] Agent unlinked."
        Set-Progress 100
    } else {
        Write-Log "[!] nessuscli.exe not found."
        Set-Progress 0
    }
})
$TabCleanup.Controls.Add($btnUnlink)

$btnStopServices = New-Object System.Windows.Forms.Button
$btnStopServices.Text = "Stop Tenable Services"
$btnStopServices.Location = New-Object System.Drawing.Point(20, 110)
$btnStopServices.Size = New-Object System.Drawing.Size(390, 40)
$btnStopServices.BackColor = [System.Drawing.Color]::SteelBlue
$btnStopServices.ForeColor = [System.Drawing.Color]::White
$btnStopServices.Font = $FontBold
$btnStopServices.Add_Click({
    if (-not (Assert-AdminOrWarn "Stop Tenable Services")) { return }
    if (-not (Confirm-DestructiveAction "Confirm Stop Services" "Force-stop all Nessus/Tenable services on this host?")) { return }
    Set-Progress 20
    Write-Log "[*] Stopping Tenable services..."
    Get-Service | Where-Object {
        $_.Name -like "*nessus*" -or $_.Name -like "*tenable*"
    } | ForEach-Object {
        Stop-Service $_.Name -Force -ErrorAction SilentlyContinue
        Write-Log "[+] Stopped: $($_.Name)"
    }
    Set-Progress 100
    Write-Log "[+] Services stopped."
})
$TabCleanup.Controls.Add($btnStopServices)

$btnUninstallAgent = New-Object System.Windows.Forms.Button
$btnUninstallAgent.Text = "Uninstall Nessus Agent (MSI)"
$btnUninstallAgent.Location = New-Object System.Drawing.Point(430, 60)
$btnUninstallAgent.Size = New-Object System.Drawing.Size(390, 40)
$btnUninstallAgent.BackColor = [System.Drawing.Color]::Maroon
$btnUninstallAgent.ForeColor = [System.Drawing.Color]::White
$btnUninstallAgent.Font = $FontBold
$btnUninstallAgent.Add_Click({
    if (-not (Assert-AdminOrWarn "Uninstall Nessus Agent")) { return }
    if (-not (Confirm-DestructiveAction "Confirm Uninstall" "Uninstall the Nessus Agent MSI product from this machine?")) { return }
    Set-Progress 20
    Write-Log "[*] Searching for Nessus Agent product GUID..."
    $apps = Get-ItemProperty -Path @(
        "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*",
        "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*"
    ) -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName -like "*Nessus Agent*" }
    if (-not $apps) {
        Write-Log "[!] No Nessus Agent uninstall entry found."
        Set-Progress 0
        return
    }
    foreach ($app in $apps) {
        Write-Log "[*] Uninstalling: $($app.DisplayName) ($($app.PSChildName))"
        Start-ProcessResponsive -FilePath "msiexec.exe" -ArgumentList "/x `"$($app.PSChildName)`" /qn /norestart"
    }
    Set-Progress 100
    Write-Log "[+] Uninstall command(s) completed."
})
$TabCleanup.Controls.Add($btnUninstallAgent)

$btnDeleteDirs = New-Object System.Windows.Forms.Button
$btnDeleteDirs.Text = "Delete Tenable Directories"
$btnDeleteDirs.Location = New-Object System.Drawing.Point(20, 160)
$btnDeleteDirs.Size = New-Object System.Drawing.Size(390, 40)
$btnDeleteDirs.BackColor = [System.Drawing.Color]::DarkRed
$btnDeleteDirs.ForeColor = [System.Drawing.Color]::White
$btnDeleteDirs.Font = $FontBold
$btnDeleteDirs.Add_Click({
    if (-not (Assert-AdminOrWarn "Delete Tenable Directories")) { return }
    if (-not (Confirm-DestructiveAction "Confirm Directory Delete" "Permanently delete:`nC:\Program Files\Tenable`nC:\ProgramData\Tenable`n`nThis cannot be undone.")) { return }
    Set-Progress 20
    Write-Log "[*] Deleting directories..."
    $paths = @(
        "C:\Program Files\Tenable",
        "C:\ProgramData\Tenable"
    )
    foreach ($p in $paths) {
        if (Test-Path $p) {
            Remove-Item $p -Recurse -Force -ErrorAction SilentlyContinue
            Write-Log "[+] Removed: $p"
        } else {
            Write-Log "[*] Not present: $p"
        }
    }
    Set-Progress 100
    Write-Log "[+] Directory cleanup complete."
})
$TabCleanup.Controls.Add($btnDeleteDirs)

$btnRegCleanup = New-Object System.Windows.Forms.Button
$btnRegCleanup.Text = "Remove Tenable Registry Keys"
$btnRegCleanup.Location = New-Object System.Drawing.Point(20, 210)
$btnRegCleanup.Size = New-Object System.Drawing.Size(390, 40)
$btnRegCleanup.BackColor = [System.Drawing.Color]::Purple
$btnRegCleanup.ForeColor = [System.Drawing.Color]::White
$btnRegCleanup.Font = $FontBold
$btnRegCleanup.Add_Click({
    if (-not (Assert-AdminOrWarn "Remove Tenable Registry")) { return }
    if (-not (Confirm-DestructiveAction "Confirm Registry Cleanup" "Delete HKLM Tenable registry trees?")) { return }
    Set-Progress 20
    Write-Log "[*] Cleaning registry..."
    $regPaths = @(
        "HKLM:\Software\Tenable",
        "HKLM:\Software\WOW6432Node\Tenable"
    )
    foreach ($rp in $regPaths) {
        if (Test-Path $rp) {
            Remove-Item $rp -Recurse -Force -ErrorAction SilentlyContinue
            Write-Log "[+] Removed: $rp"
        }
    }
    Set-Progress 100
    Write-Log "[+] Registry cleanup complete."
})
$TabCleanup.Controls.Add($btnRegCleanup)

$btnFullCleanup = New-Object System.Windows.Forms.Button
$btnFullCleanup.Text = "Full Cleanup Wizard (Unlink → Stop → Uninstall → Dirs → Reg)"
$btnFullCleanup.Location = New-Object System.Drawing.Point(430, 110)
$btnFullCleanup.Size = New-Object System.Drawing.Size(390, 90)
$btnFullCleanup.BackColor = [System.Drawing.Color]::Black
$btnFullCleanup.ForeColor = [System.Drawing.Color]::White
$btnFullCleanup.Font = $FontBold
$btnFullCleanup.Add_Click({
    if (-not (Assert-AdminOrWarn "Full Cleanup Wizard")) { return }
    if (-not (Confirm-DestructiveAction "FULL CLEANUP" "This will UNLINK, STOP, UNINSTALL, delete directories, and purge Tenable registry keys.`n`nContinue to the final confirmation?")) { return }
    $final = [System.Windows.Forms.MessageBox]::Show(
        "FINAL WARNING: This permanently removes the Nessus Agent and related files/registry from this machine.`n`nClick Yes only if you are sure.",
        "Final Confirmation — Full Cleanup",
        [System.Windows.Forms.MessageBoxButtons]::YesNo,
        [System.Windows.Forms.MessageBoxIcon]::Stop
    )
    if ($final -ne [System.Windows.Forms.DialogResult]::Yes) {
        Write-Log "[*] Full cleanup cancelled at final confirmation."
        return
    }

    Set-Progress 10
    Write-Log "[*] === FULL CLEANUP START ==="

    if (Test-Path $Global:NessusCliPath) {
        Write-Log "[*] Unlinking..."
        Start-ProcessResponsive -FilePath $Global:NessusCliPath -ArgumentList "agent unlink"
    }
    Set-Progress 25

    Get-Service | Where-Object { $_.Name -like "*nessus*" -or $_.Name -like "*tenable*" } | ForEach-Object {
        Stop-Service $_.Name -Force -ErrorAction SilentlyContinue
    }
    Set-Progress 40

    $apps = Get-ItemProperty -Path @(
        "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*",
        "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*"
    ) -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName -like "*Nessus Agent*" }
    foreach ($app in $apps) {
        Start-ProcessResponsive -FilePath "msiexec.exe" -ArgumentList "/x `"$($app.PSChildName)`" /qn /norestart"
    }
    Set-Progress 60

    foreach ($p in @("C:\Program Files\Tenable", "C:\ProgramData\Tenable")) {
        if (Test-Path $p) { Remove-Item $p -Recurse -Force -ErrorAction SilentlyContinue }
    }
    Set-Progress 80

    foreach ($rp in @("HKLM:\Software\Tenable", "HKLM:\Software\WOW6432Node\Tenable")) {
        if (Test-Path $rp) { Remove-Item $rp -Recurse -Force -ErrorAction SilentlyContinue }
    }

    Set-Progress 100
    Write-Log "[+] === FULL CLEANUP COMPLETE ==="
})
$TabCleanup.Controls.Add($btnFullCleanup)

New-Label $TabCleanup "Forced Target Removal Tools" 20 270

$btnPurgeMcAfee = New-Object System.Windows.Forms.Button
$btnPurgeMcAfee.Text = "Uninstall MCAFEE (Files and Registry)"
$btnPurgeMcAfee.Location = New-Object System.Drawing.Point(20, 300)
$btnPurgeMcAfee.Size = New-Object System.Drawing.Size(390, 45)
$btnPurgeMcAfee.BackColor = [System.Drawing.Color]::Crimson
$btnPurgeMcAfee.ForeColor = [System.Drawing.Color]::White
$btnPurgeMcAfee.Font = $FontBold
$btnPurgeMcAfee.Add_Click({
    if (-not (Assert-AdminOrWarn "McAfee Purge")) { return }
    if (-not (Confirm-DestructiveAction "Confirm McAfee Purge" "This aggressively kills processes, services, uninstallers, folders, and registry for McAfee.`n`nContinue?")) { return }
    Set-Progress 10
    Write-Log "[!!!] Starting Complete McAfee Uninstall Engine..."

    Write-Log "[*] Terminating active McAfee processes..."
    $mcafeeProcs = Get-Process | Where-Object { $_.Name -like "*mcafee*" -or $_.Name -like "*mcshield*" -or $_.Name -like "*mfe*" }
    foreach ($proc in $mcafeeProcs) {
        try {
            Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
            Write-Log "[+] Killed process: $($proc.Name)"
        } catch {}
    }
    Set-Progress 25

    Write-Log "[*] Stripping and deleting service objects..."
    $mcafeeSvcs = Get-Service | Where-Object { $_.Name -like "*mcafee*" -or $_.Name -like "*mfe*" -or $_.Name -like "*mcshield*" }
    foreach ($svc in $mcafeeSvcs) {
        try {
            Stop-Service -Name $svc.Name -Force -ErrorAction SilentlyContinue
            sc.exe delete $svc.Name | Out-Null
            Write-Log "[+] Erased System Service: $($svc.Name)"
        } catch {}
    }
    Set-Progress 45

    Write-Log "[*] Triggering programmatic uninstallation strings..."
    $regUninstallPaths = @(
        "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*",
        "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*"
    )
    $apps = Get-ItemProperty -Path $regUninstallPaths -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName -like "*McAfee*" }
    foreach ($app in $apps) {
        if ($app.UninstallString) {
            Write-Log "[*] Processing formal uninstaller for: $($app.DisplayName)"
            if ($app.UninstallString -match "msiexec") {
                $guid = ($app.PSChildName)
                Start-ProcessResponsive -FilePath "msiexec.exe" -ArgumentList "/x $guid /qn /norestart"
            } else {
                try {
                    $cleanCmd = $app.UninstallString -replace "/quiet", "" -replace "/qn", ""
                    Start-ProcessResponsive -FilePath "cmd.exe" -ArgumentList "/c $cleanCmd /quiet /qn /forceuninstall /silent"
                } catch {}
            }
        }
    }
    Set-Progress 65

    Write-Log "[*] Destroying localized file directories..."
    $targetDirs = @(
        "C:\Program Files\McAfee",
        "C:\Program Files\Common Files\McAfee",
        "C:\Program Files (x86)\McAfee",
        "C:\Program Files (x86)\Common Files\McAfee",
        "C:\ProgramData\McAfee",
        "C:\ProgramData\McAfeeRemoval",
        "$env:LOCALAPPDATA\McAfee",
        "$env:APPDATA\McAfee"
    )
    foreach ($dir in $targetDirs) {
        if (Test-Path $dir) {
            try {
                Remove-Item -Path $dir -Recurse -Force -ErrorAction SilentlyContinue
                Write-Log "[+] Deleted Folder: $dir"
            } catch {
                Write-Log "[!] Locked file warning on folder. Will complete cleanup next boot: $dir"
            }
        }
    }
    Set-Progress 85

    Write-Log "[*] Sweeping Registry entries..."
    $targetReg = @(
        "HKLM:\SOFTWARE\McAfee",
        "HKLM:\SOFTWARE\WOW6432Node\McAfee",
        "HKCU:\Software\McAfee"
    )
    foreach ($reg in $targetReg) {
        if (Test-Path $reg) {
            try {
                Remove-Item -Path $reg -Recurse -Force -ErrorAction SilentlyContinue
                Write-Log "[+] Pruned Registry Path: $reg"
            } catch {}
        }
    }

    Refresh-AVStatus
    Set-Progress 100
    Write-Log "[+] McAfee Purge Engine Operation Completed successfully."
})
$TabCleanup.Controls.Add($btnPurgeMcAfee)

# -----------------------------------------------------------------------------
# TAB 5 — SYSTEM & SOFTWARE AUDIT COLLECTION
# -----------------------------------------------------------------------------

New-Label $TabAudit "System Information & Software Audits" 20 20

function Start-SoftwareCollection {
    param($ComputerName)

    $ScriptName = "Software Collection.ps1"
    $FullPath = Join-Path $Global:AgentDir $ScriptName

    Write-Log "[*] Handing off to $ScriptName for target: $ComputerName..."

    if (Test-Path $FullPath) {
        try {
            $ArgList = @(
                "-ExecutionPolicy", "Bypass",
                "-Command", "& { `$global:CompName = '$ComputerName'; . '$FullPath'; CollectComputer }"
            )

            $proc = Start-Process powershell.exe -ArgumentList $ArgList -WorkingDirectory $Global:AgentDir -WindowStyle Hidden -PassThru

            while (-not $proc.HasExited) {
                [System.Windows.Forms.Application]::DoEvents()
                Start-Sleep -Milliseconds 100
            }

            $ExpectedFolder = Join-Path $Global:AgentDir "Software Collection"
            Write-Log "[+] $ScriptName finished processing."
            Write-Log "[+] Output files archived silently inside: $ExpectedFolder"
        } catch {
            Write-Log "[!] Handoff failed: $($_.Exception.Message)"
            throw $_
        }
    } else {
        Write-Log "[!] ERROR: '$ScriptName' not found in $Global:AgentDir"
        throw "Script not found."
    }
}

function Start-SystemCollection {
    param($ComputerName)

    $ScriptName = "System Collection.ps1"
    $FullPath = Join-Path $Global:AgentDir $ScriptName

    Write-Log "[*] Handing off to $ScriptName for target: $ComputerName..."

    if (Test-Path $FullPath) {
        try {
            $ArgList = @(
                "-ExecutionPolicy", "Bypass",
                "-Command", "& { `$global:CompName = '$ComputerName'; . '$FullPath'; }"
            )

            $proc = Start-Process powershell.exe -ArgumentList $ArgList -WorkingDirectory $Global:AgentDir -WindowStyle Hidden -PassThru

            while (-not $proc.HasExited) {
                [System.Windows.Forms.Application]::DoEvents()
                Start-Sleep -Milliseconds 100
            }

            Write-Log "[+] $ScriptName finished processing."
        } catch {
            Write-Log "[!] Handoff failed: $($_.Exception.Message)"
            throw $_
        }
    } else {
        Write-Log "[!] ERROR: '$ScriptName' not found in $Global:AgentDir"
        throw "Script not found."
    }
}

New-Label $TabAudit "Target Computer Name:" 20 60
$txtAuditTarget = New-Object System.Windows.Forms.TextBox
$txtAuditTarget.Location = New-Object System.Drawing.Point(20, 85)
$txtAuditTarget.Size = New-Object System.Drawing.Size(390, 25)
$txtAuditTarget.Text = $env:COMPUTERNAME
$TabAudit.Controls.Add($txtAuditTarget)

function Toggle-AuditUI ($enabled) {
    $btnRunSoftCollect.Enabled = $enabled
    $btnRunSysCollect.Enabled  = $enabled
    $btnRunBothAudits.Enabled  = $enabled
    $txtAuditTarget.Enabled    = $enabled
}

$btnRunSoftCollect = New-Object System.Windows.Forms.Button
$btnRunSoftCollect.Text = "Collect Installed Software"
$btnRunSoftCollect.Location = New-Object System.Drawing.Point(20, 130)
$btnRunSoftCollect.Size = New-Object System.Drawing.Size(390, 40)
$btnRunSoftCollect.BackColor = [System.Drawing.Color]::Teal
$btnRunSoftCollect.ForeColor = [System.Drawing.Color]::White
$btnRunSoftCollect.Font = $FontBold
$btnRunSoftCollect.Add_Click({
    $target = if ([string]::IsNullOrWhiteSpace($txtAuditTarget.Text)) { $env:COMPUTERNAME } else { $txtAuditTarget.Text.Trim() }

    Toggle-AuditUI $false
    Set-Progress 25
    [System.Windows.Forms.Application]::DoEvents()

    try {
        Start-SoftwareCollection -ComputerName $target
        Set-Progress 100
    } catch {
        Write-Log "[!] Software Audit Failed: $($_.Exception.Message)"
        Set-Progress 0
    } finally {
        Toggle-AuditUI $true
    }
})
$TabAudit.Controls.Add($btnRunSoftCollect)

$btnRunSysCollect = New-Object System.Windows.Forms.Button
$btnRunSysCollect.Text = "Capture System Information"
$btnRunSysCollect.Location = New-Object System.Drawing.Point(20, 185)
$btnRunSysCollect.Size = New-Object System.Drawing.Size(390, 40)
$btnRunSysCollect.BackColor = [System.Drawing.Color]::Chocolate
$btnRunSysCollect.ForeColor = [System.Drawing.Color]::White
$btnRunSysCollect.Font = $FontBold
$btnRunSysCollect.Add_Click({
    $target = if ([string]::IsNullOrWhiteSpace($txtAuditTarget.Text)) { $env:COMPUTERNAME } else { $txtAuditTarget.Text.Trim() }

    Toggle-AuditUI $false
    Set-Progress 25
    [System.Windows.Forms.Application]::DoEvents()

    try {
        Start-SystemCollection -ComputerName $target
        Set-Progress 100
    } catch {
        Write-Log "[!] System Audit Failed: $($_.Exception.Message)"
        Set-Progress 0
    } finally {
        Toggle-AuditUI $true
    }
})
$TabAudit.Controls.Add($btnRunSysCollect)

$btnRunBothAudits = New-Object System.Windows.Forms.Button
$btnRunBothAudits.Text = "Run Both Audits"
$btnRunBothAudits.Location = New-Object System.Drawing.Point(20, 240)
$btnRunBothAudits.Size = New-Object System.Drawing.Size(390, 40)
$btnRunBothAudits.BackColor = [System.Drawing.Color]::DarkCyan
$btnRunBothAudits.ForeColor = [System.Drawing.Color]::White
$btnRunBothAudits.Font = $FontBold
$btnRunBothAudits.Add_Click({
    $target = if ([string]::IsNullOrWhiteSpace($txtAuditTarget.Text)) { $env:COMPUTERNAME } else { $txtAuditTarget.Text.Trim() }
    Toggle-AuditUI $false
    Set-Progress 10
    try {
        Start-SoftwareCollection -ComputerName $target
        Set-Progress 55
        Start-SystemCollection -ComputerName $target
        Set-Progress 100
        Write-Log "[+] Both audits completed."
    } catch {
        Write-Log "[!] Combined audit failed: $($_.Exception.Message)"
        Set-Progress 0
    } finally {
        Toggle-AuditUI $true
    }
})
$TabAudit.Controls.Add($btnRunBothAudits)

$btnOpenAuditFolder = New-Object System.Windows.Forms.Button
$btnOpenAuditFolder.Text = "Open Software Collection Folder"
$btnOpenAuditFolder.Location = New-Object System.Drawing.Point(20, 295)
$btnOpenAuditFolder.Size = New-Object System.Drawing.Size(390, 35)
$btnOpenAuditFolder.Add_Click({
    $folder = Join-Path $Global:AgentDir "Software Collection"
    if (Test-Path $folder) {
        Start-Process explorer.exe $folder
    } else {
        Write-Log "[!] Folder not found yet: $folder"
    }
})
$TabAudit.Controls.Add($btnOpenAuditFolder)

# -----------------------------------------------------------------------------
# TAB 6 — RESTORE ORIGINAL IP
# -----------------------------------------------------------------------------

New-Label $TabRestore "Saved Restore Points (loaded from disk)" 20 20

$lbSavedBaselines = New-Object System.Windows.Forms.ListBox
$lbSavedBaselines.Location = New-Object System.Drawing.Point(20, 50)
$lbSavedBaselines.Size = New-Object System.Drawing.Size(830, 160)
$lbSavedBaselines.Font = New-Object System.Drawing.Font("Consolas", 9)
$TabRestore.Controls.Add($lbSavedBaselines)

$Global:RestoreListMap = @()

function Format-BaselineRow($Record) {
    $dhcpTag = if ($Record.OriginalDHCP) { "DHCP" } else { "STATIC" }
    return "{0,-15} | {1,-22} | {2,-15} | {3,-15} | {4,-6} | captured {5}" -f `
        $Record.ComputerName, $Record.InterfaceAlias, $Record.OriginalIP, $Record.OriginalMask, $dhcpTag, $Record.CapturedAt
}

function Refresh-SavedBaselinesList {
    $lbSavedBaselines.Items.Clear()
    $Global:RestoreListMap = @(Get-BaselineStore)
    foreach ($rec in $Global:RestoreListMap) {
        [void]$lbSavedBaselines.Items.Add((Format-BaselineRow $rec))
    }
    if ($Global:RestoreListMap.Count -eq 0) {
        $lbSavedBaselines.Items.Add("(No saved restore points yet — select an adapter on the Assign IP tab to create one.)")
    }
}

$btnRefreshBaselines = New-Object System.Windows.Forms.Button
$btnRefreshBaselines.Text = "Refresh List"
$btnRefreshBaselines.Location = New-Object System.Drawing.Point(20, 215)
$btnRefreshBaselines.Size = New-Object System.Drawing.Size(150, 30)
$btnRefreshBaselines.Add_Click({ Refresh-SavedBaselinesList })
$TabRestore.Controls.Add($btnRefreshBaselines)

$btnExportBaselines = New-Object System.Windows.Forms.Button
$btnExportBaselines.Text = "Export Baselines..."
$btnExportBaselines.Location = New-Object System.Drawing.Point(180, 215)
$btnExportBaselines.Size = New-Object System.Drawing.Size(160, 30)
$btnExportBaselines.Add_Click({
    $dlg = New-Object System.Windows.Forms.SaveFileDialog
    $dlg.Filter = "JSON (*.json)|*.json"
    $dlg.FileName = "IP_Baselines_export_{0:yyyyMMdd}.json" -f (Get-Date)
    if ($dlg.ShowDialog() -eq "OK") {
        try {
            Copy-Item $Global:BaselineStorePath $dlg.FileName -Force -ErrorAction Stop
            Write-Log "[+] Baselines exported to $($dlg.FileName)"
        } catch {
            Write-Log "[!] Export failed: $_"
        }
    }
})
$TabRestore.Controls.Add($btnExportBaselines)

$btnImportBaselines = New-Object System.Windows.Forms.Button
$btnImportBaselines.Text = "Import / Merge Baselines..."
$btnImportBaselines.Location = New-Object System.Drawing.Point(350, 215)
$btnImportBaselines.Size = New-Object System.Drawing.Size(200, 30)
$btnImportBaselines.Add_Click({
    $dlg = New-Object System.Windows.Forms.OpenFileDialog
    $dlg.Filter = "JSON (*.json)|*.json"
    if ($dlg.ShowDialog() -ne "OK") { return }
    try {
        $raw = Get-Content $dlg.FileName -Raw
        $incoming = $raw | ConvertFrom-Json
        if ($incoming -isnot [System.Array]) { $incoming = @($incoming) }
        $store = @(Get-BaselineStore)
        foreach ($rec in $incoming) {
            $store = @($store | Where-Object { -not ($_.ComputerName -eq $rec.ComputerName -and $_.InterfaceAlias -eq $rec.InterfaceAlias) })
            $store += $rec
        }
        if (Save-BaselineStore $store) {
            Write-Log "[+] Merged $($incoming.Count) baseline(s) from import."
            Refresh-SavedBaselinesList
        }
    } catch {
        Write-Log "[!] Import failed: $_"
    }
})
$TabRestore.Controls.Add($btnImportBaselines)

$grpRestoreDetail = New-Object System.Windows.Forms.GroupBox
$grpRestoreDetail.Text = " Selected Restore Point Detail "
$grpRestoreDetail.Location = New-Object System.Drawing.Point(20, 260)
$grpRestoreDetail.Size = New-Object System.Drawing.Size(830, 180)
$grpRestoreDetail.Font = $FontBold
$TabRestore.Controls.Add($grpRestoreDetail)

$lblDetailAdapterTag = New-Object System.Windows.Forms.Label
$lblDetailAdapterTag.Text = "Adapter:"
$lblDetailAdapterTag.Location = New-Object System.Drawing.Point(20, 30)
$lblDetailAdapterTag.AutoSize = $true
$grpRestoreDetail.Controls.Add($lblDetailAdapterTag)
$lblDetailAdapterVal = New-Object System.Windows.Forms.Label
$lblDetailAdapterVal.Text = "-"
$lblDetailAdapterVal.Location = New-Object System.Drawing.Point(160, 30)
$lblDetailAdapterVal.Font = $FontRegular
$lblDetailAdapterVal.AutoSize = $true
$grpRestoreDetail.Controls.Add($lblDetailAdapterVal)

$lblDetailIpTag = New-Object System.Windows.Forms.Label
$lblDetailIpTag.Text = "Original IP:"
$lblDetailIpTag.Location = New-Object System.Drawing.Point(20, 60)
$lblDetailIpTag.AutoSize = $true
$grpRestoreDetail.Controls.Add($lblDetailIpTag)
$lblDetailIpVal = New-Object System.Windows.Forms.Label
$lblDetailIpVal.Text = "-"
$lblDetailIpVal.Location = New-Object System.Drawing.Point(160, 60)
$lblDetailIpVal.Font = $FontRegular
$lblDetailIpVal.AutoSize = $true
$grpRestoreDetail.Controls.Add($lblDetailIpVal)

$lblDetailMaskTag = New-Object System.Windows.Forms.Label
$lblDetailMaskTag.Text = "Original Mask:"
$lblDetailMaskTag.Location = New-Object System.Drawing.Point(20, 90)
$lblDetailMaskTag.AutoSize = $true
$grpRestoreDetail.Controls.Add($lblDetailMaskTag)
$lblDetailMaskVal = New-Object System.Windows.Forms.Label
$lblDetailMaskVal.Text = "-"
$lblDetailMaskVal.Location = New-Object System.Drawing.Point(160, 90)
$lblDetailMaskVal.Font = $FontRegular
$lblDetailMaskVal.AutoSize = $true
$grpRestoreDetail.Controls.Add($lblDetailMaskVal)

$lblDetailGwTag = New-Object System.Windows.Forms.Label
$lblDetailGwTag.Text = "Gateway:"
$lblDetailGwTag.Location = New-Object System.Drawing.Point(430, 30)
$lblDetailGwTag.AutoSize = $true
$grpRestoreDetail.Controls.Add($lblDetailGwTag)
$lblDetailGwVal = New-Object System.Windows.Forms.Label
$lblDetailGwVal.Text = "-"
$lblDetailGwVal.Location = New-Object System.Drawing.Point(560, 30)
$lblDetailGwVal.Font = $FontRegular
$lblDetailGwVal.AutoSize = $true
$grpRestoreDetail.Controls.Add($lblDetailGwVal)

$lblDetailDnsTag = New-Object System.Windows.Forms.Label
$lblDetailDnsTag.Text = "DNS:"
$lblDetailDnsTag.Location = New-Object System.Drawing.Point(430, 60)
$lblDetailDnsTag.AutoSize = $true
$grpRestoreDetail.Controls.Add($lblDetailDnsTag)
$lblDetailDnsVal = New-Object System.Windows.Forms.Label
$lblDetailDnsVal.Text = "-"
$lblDetailDnsVal.Location = New-Object System.Drawing.Point(560, 60)
$lblDetailDnsVal.Font = $FontRegular
$lblDetailDnsVal.AutoSize = $true
$grpRestoreDetail.Controls.Add($lblDetailDnsVal)

$lblDetailCapturedTag = New-Object System.Windows.Forms.Label
$lblDetailCapturedTag.Text = "Captured At:"
$lblDetailCapturedTag.Location = New-Object System.Drawing.Point(20, 120)
$lblDetailCapturedTag.AutoSize = $true
$grpRestoreDetail.Controls.Add($lblDetailCapturedTag)
$lblDetailCapturedVal = New-Object System.Windows.Forms.Label
$lblDetailCapturedVal.Text = "-"
$lblDetailCapturedVal.Location = New-Object System.Drawing.Point(160, 120)
$lblDetailCapturedVal.Font = $FontRegular
$lblDetailCapturedVal.AutoSize = $true
$grpRestoreDetail.Controls.Add($lblDetailCapturedVal)

$lbSavedBaselines.Add_SelectedIndexChanged({
    $idx = $lbSavedBaselines.SelectedIndex
    if ($idx -lt 0 -or $idx -ge $Global:RestoreListMap.Count) { return }
    $rec = $Global:RestoreListMap[$idx]
    $lblDetailAdapterVal.Text  = "$($rec.InterfaceAlias)  (on $($rec.ComputerName))"
    $lblDetailIpVal.Text       = $rec.OriginalIP
    $lblDetailMaskVal.Text     = $rec.OriginalMask
    $lblDetailGwVal.Text       = if ([string]::IsNullOrEmpty($rec.OriginalGateway)) { "(none)" } else { $rec.OriginalGateway }
    $lblDetailDnsVal.Text      = if ([string]::IsNullOrEmpty($rec.OriginalDNS)) { "(none)" } else { $rec.OriginalDNS }
    $lblDetailCapturedVal.Text = "$($rec.CapturedAt)  [$(if ($rec.OriginalDHCP) {'DHCP'} else {'STATIC'})]"
})

$btnPerformRestore = New-Object System.Windows.Forms.Button
$btnPerformRestore.Text = "Revert Selected Adapter Back to This Baseline"
$btnPerformRestore.Location = New-Object System.Drawing.Point(20, 455)
$btnPerformRestore.Size = New-Object System.Drawing.Size(830, 50)
$btnPerformRestore.BackColor = [System.Drawing.Color]::Chocolate
$btnPerformRestore.ForeColor = [System.Drawing.Color]::White
$btnPerformRestore.Font = $FontBold
$btnPerformRestore.Add_Click({
    $idx = $lbSavedBaselines.SelectedIndex
    if ($idx -lt 0 -or $idx -ge $Global:RestoreListMap.Count) {
        [System.Windows.Forms.MessageBox]::Show("Select a saved restore point from the list first.", "Nothing Selected", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning)
        return
    }
    if (-not (Assert-AdminOrWarn "Restore IP")) { return }
    $rec = $Global:RestoreListMap[$idx]
    $TargetAdapter = $rec.InterfaceAlias

    $confirm = [System.Windows.Forms.MessageBox]::Show(
        "This will revert adapter '$TargetAdapter' back to:`n`nIP: $($rec.OriginalIP)`nMask: $($rec.OriginalMask)`nGateway: $(if ([string]::IsNullOrEmpty($rec.OriginalGateway)) {'(none)'} else {$rec.OriginalGateway})`nMode: $(if ($rec.OriginalDHCP) {'DHCP'} else {'STATIC'})`n(captured $($rec.CapturedAt))`n`nContinue?",
        "Confirm Restore",
        [System.Windows.Forms.MessageBoxButtons]::YesNo,
        [System.Windows.Forms.MessageBoxIcon]::Question
    )
    if ($confirm -ne [System.Windows.Forms.DialogResult]::Yes) { return }

    Set-Progress 20
    Write-Log "[*] Starting rollback recovery operation on adapter: $TargetAdapter"

    try {
        if ($rec.OriginalDHCP -eq $true) {
            Write-Log "[*] Re-enabling Automated DHCP configuration rules..."
            netsh.exe interface ipv4 set address name=$TargetAdapter source=dhcp
            netsh.exe interface ipv4 set dnsservers name=$TargetAdapter source=dhcp
        } else {
            $origIP   = $rec.OriginalIP
            $origMask = $rec.OriginalMask
            $origGW   = $rec.OriginalGateway
            $origDNS  = $rec.OriginalDNS

            Write-Log "[*] Re-applying static profile layout: IP: $origIP | Mask: $origMask | GW: $origGW"

            if (![string]::IsNullOrEmpty($origGW)) {
                netsh.exe interface ipv4 set address name=$TargetAdapter source=static addr=$origIP mask=$origMask gateway=$origGW gwmetric=1
            } else {
                netsh.exe interface ipv4 set address name=$TargetAdapter source=static addr=$origIP mask=$origMask gateway=none
            }

            if (![string]::IsNullOrEmpty($origDNS)) {
                netsh.exe interface ipv4 set dns name=$TargetAdapter source=static addr=$origDNS
            }
        }

        Set-Progress 70
        Wait-Responsive 3
        $live = Get-LiveIPv4OnAdapter -InterfaceAlias $TargetAdapter
        Write-Log "[ SUCCESS ] Adapter restored. Live IP now: $live"

        Write-DeploymentHistory -SelectedAdapter $TargetAdapter `
            -OriginalIP "RESTORE ACTION" `
            -OriginalMask "RESTORE ACTION" `
            -AssignedTempIP $rec.OriginalIP

        Set-Progress 100

        $clearIt = [System.Windows.Forms.MessageBox]::Show(
            "Restore completed. Remove this saved restore point now that it's no longer needed?`n`n(Choose No if you plan to change this adapter's IP again soon and want to keep this baseline around.)",
            "Clean Up Restore Point?",
            [System.Windows.Forms.MessageBoxButtons]::YesNo,
            [System.Windows.Forms.MessageBoxIcon]::Question
        )
        if ($clearIt -eq [System.Windows.Forms.DialogResult]::Yes) {
            Remove-BaselineFor -ComputerName $rec.ComputerName -InterfaceAlias $rec.InterfaceAlias
            Write-Log "[*] Cleared saved restore point for '$TargetAdapter'."
        }
        Refresh-SavedBaselinesList
    } catch {
        Write-Log "[!] Rollback Operation Error Failed: $_"
        Set-Progress 0
    }
})
$TabRestore.Controls.Add($btnPerformRestore)

$btnDeleteBaseline = New-Object System.Windows.Forms.Button
$btnDeleteBaseline.Text = "Delete Selected Restore Point (without restoring)"
$btnDeleteBaseline.Location = New-Object System.Drawing.Point(20, 515)
$btnDeleteBaseline.Size = New-Object System.Drawing.Size(830, 35)
$btnDeleteBaseline.BackColor = [System.Drawing.Color]::DimGray
$btnDeleteBaseline.ForeColor = [System.Drawing.Color]::White
$btnDeleteBaseline.Font = $FontBold
$btnDeleteBaseline.Add_Click({
    $idx = $lbSavedBaselines.SelectedIndex
    if ($idx -lt 0 -or $idx -ge $Global:RestoreListMap.Count) {
        [System.Windows.Forms.MessageBox]::Show("Select a saved restore point from the list first.", "Nothing Selected", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning)
        return
    }
    $rec = $Global:RestoreListMap[$idx]
    $confirm = [System.Windows.Forms.MessageBox]::Show(
        "Permanently delete the saved restore point for '$($rec.InterfaceAlias)' without applying it?`n`nThis cannot be undone.",
        "Confirm Delete",
        [System.Windows.Forms.MessageBoxButtons]::YesNo,
        [System.Windows.Forms.MessageBoxIcon]::Warning
    )
    if ($confirm -ne [System.Windows.Forms.DialogResult]::Yes) { return }
    Remove-BaselineFor -ComputerName $rec.ComputerName -InterfaceAlias $rec.InterfaceAlias
    Write-Log "[*] Deleted saved restore point for '$($rec.InterfaceAlias)' (no changes applied to the adapter)."
    Refresh-SavedBaselinesList
})
$TabRestore.Controls.Add($btnDeleteBaseline)

# -----------------------------------------------------------------------------
# TAB 7 — SETTINGS
# -----------------------------------------------------------------------------

New-Label $TabSettings "Persistent Tool Settings (saved to Tool_Config.json)" 20 20

New-Label $TabSettings "Scanner / RHEL Host:" 20 60
$txtCfgHost = New-Object System.Windows.Forms.TextBox
$txtCfgHost.Location = New-Object System.Drawing.Point(220, 55)
$txtCfgHost.Size = New-Object System.Drawing.Size(250, 25)
$txtCfgHost.Text = $Global:RHELTargetHost
$TabSettings.Controls.Add($txtCfgHost)

New-Label $TabSettings "SSH User:" 20 100
$txtCfgSshUser = New-Object System.Windows.Forms.TextBox
$txtCfgSshUser.Location = New-Object System.Drawing.Point(220, 95)
$txtCfgSshUser.Size = New-Object System.Drawing.Size(250, 25)
$txtCfgSshUser.Text = $Global:SshUser
$TabSettings.Controls.Add($txtCfgSshUser)

New-Label $TabSettings "SSH Options:" 20 140
$txtCfgSshOpts = New-Object System.Windows.Forms.TextBox
$txtCfgSshOpts.Location = New-Object System.Drawing.Point(220, 135)
$txtCfgSshOpts.Size = New-Object System.Drawing.Size(500, 25)
$txtCfgSshOpts.Text = $Global:SshOpts
$TabSettings.Controls.Add($txtCfgSshOpts)

New-Label $TabSettings "Agent Link Port:" 20 180
$txtCfgPort = New-Object System.Windows.Forms.TextBox
$txtCfgPort.Location = New-Object System.Drawing.Point(220, 175)
$txtCfgPort.Size = New-Object System.Drawing.Size(100, 25)
$txtCfgPort.Text = "$($Global:AgentLinkPort)"
$TabSettings.Controls.Add($txtCfgPort)

New-Label $TabSettings "nessuscli Path:" 20 220
$txtCfgCli = New-Object System.Windows.Forms.TextBox
$txtCfgCli.Location = New-Object System.Drawing.Point(220, 215)
$txtCfgCli.Size = New-Object System.Drawing.Size(500, 25)
$txtCfgCli.Text = $Global:NessusCliPath
$TabSettings.Controls.Add($txtCfgCli)

$lblCfgHint = New-Object System.Windows.Forms.Label
$lblCfgHint.Text = "Linking key is never stored in Tool_Config.json. Set env var NESSUS_LINK_KEY to auto-fill the masked key field."
$lblCfgHint.Location = New-Object System.Drawing.Point(20, 270)
$lblCfgHint.Size = New-Object System.Drawing.Size(800, 40)
$lblCfgHint.Font = $FontRegular
$TabSettings.Controls.Add($lblCfgHint)

$btnSaveSettings = New-Object System.Windows.Forms.Button
$btnSaveSettings.Text = "Save Settings"
$btnSaveSettings.Location = New-Object System.Drawing.Point(20, 320)
$btnSaveSettings.Size = New-Object System.Drawing.Size(250, 45)
$btnSaveSettings.BackColor = [System.Drawing.Color]::DarkGreen
$btnSaveSettings.ForeColor = [System.Drawing.Color]::White
$btnSaveSettings.Font = $FontBold
$btnSaveSettings.Add_Click({
    $Global:RHELTargetHost = $txtCfgHost.Text.Trim()
    $Global:SshUser        = $txtCfgSshUser.Text.Trim()
    $Global:SshOpts        = $txtCfgSshOpts.Text.Trim()
    $portParsed = 0
    if ([int]::TryParse($txtCfgPort.Text.Trim(), [ref]$portParsed)) { $Global:AgentLinkPort = $portParsed }
    $Global:NessusCliPath  = $txtCfgCli.Text.Trim()

    $Global:ToolConfig.RHELTargetHost = $Global:RHELTargetHost
    $Global:ToolConfig.SshUser        = $Global:SshUser
    $Global:ToolConfig.SshOpts        = $Global:SshOpts
    $Global:ToolConfig.AgentLinkPort  = $Global:AgentLinkPort
    $Global:ToolConfig.NessusCliPath  = $Global:NessusCliPath
    $Global:ToolConfig.AVDir          = $Global:AVDir
    $Global:ToolConfig.AgentDir       = $Global:AgentDir

    if (Save-ToolConfig $Global:ToolConfig) {
        $txtScannerIP.Text = $Global:RHELTargetHost
        $txtLinkPort.Text  = "$($Global:AgentLinkPort)"
        Update-StatusStrip
        Write-Log "[+] Settings saved to Tool_Config.json"
        [System.Windows.Forms.MessageBox]::Show("Settings saved.", "Saved", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information)
    } else {
        [System.Windows.Forms.MessageBox]::Show("Failed to save settings.", "Error", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error)
    }
})
$TabSettings.Controls.Add($btnSaveSettings)

$btnOpenConfig = New-Object System.Windows.Forms.Button
$btnOpenConfig.Text = "Open Config File"
$btnOpenConfig.Location = New-Object System.Drawing.Point(290, 320)
$btnOpenConfig.Size = New-Object System.Drawing.Size(200, 45)
$btnOpenConfig.Add_Click({
    if (Test-Path $Global:ConfigPath) {
        Start-Process notepad.exe $Global:ConfigPath
    } else {
        Write-Log "[!] Config file not found yet."
    }
})
$TabSettings.Controls.Add($btnOpenConfig)

# -----------------------------------------------------------------------------
# RUN PROGRAM
# -----------------------------------------------------------------------------

$Form.Add_Shown({
    Refresh-AVStatus
    Refresh-SavedBaselinesList
    Update-MsiLabel
    Update-StatusStrip
    Write-Log "Nessus Tool v$Script:ToolVersion started."
    if ($Global:IsAdmin) {
        Write-Log "[+] Running elevated (Administrator)."
    } else {
        Write-Log "[!] NOT elevated — many actions will warn or fail. Right-click → Run with PowerShell as Administrator."
    }
    Write-Log "[*] Scanner: $($Global:RHELTargetHost):$($Global:AgentLinkPort) | Config: $Global:ConfigPath"
})

[void]$Form.ShowDialog()
