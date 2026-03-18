#Requires -RunAsAdministrator
#Requires -Version 5.1

$ErrorActionPreference = "Stop"
$ProgressPreference    = "SilentlyContinue"

# ---------------------------------------------------------------------------
# CONFIGURATION
# ---------------------------------------------------------------------------

$Config = @{
    ServerName   = "dc1"
    DomainName   = ""
    NetBIOSName  = ""
    DSRMPassword = ""
    CACommonName = ""

    DatabasePath = $null
    LogPath      = $null
    SysvolPath   = $null

    DomainMode   = "Win2016"
    ForestMode   = "Win2016"
}

# ---------------------------------------------------------------------------
# CONSTANTS
# ---------------------------------------------------------------------------

$StateDir   = "C:\ADSetup"
$StateFile  = "$StateDir\state.json"
$LogFile    = "$StateDir\setup.log"
$TaskName   = "ADDomainSetup-Continue"
$ScriptPath = $PSCommandPath

# ---------------------------------------------------------------------------
# LOGGING
# ---------------------------------------------------------------------------

function Write-Log {
    param([string]$Message, [string]$Level = "INFO")

    $ts   = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $line = "[$ts] [$Level] $Message"

    if (Test-Path $StateDir) {
        Add-Content -Path $LogFile -Value $line -ErrorAction SilentlyContinue
    }

    Write-Output $line

    switch ($Level) {
        "STEP"  { Write-Host "`n==> $Message" -ForegroundColor Cyan }
        "OK"    { Write-Host "    [OK]  $Message" -ForegroundColor Green }
        "WARN"  { Write-Host "    [!!]  $Message" -ForegroundColor Yellow }
        "ERROR" { Write-Host "    [ERR] $Message" -ForegroundColor Red }
    }
}

function Measure-Step {
    param([string]$Name, [scriptblock]$Script)

    $start = Get-Date
    Write-Log "START: $Name" "STEP"

    & $Script

    $end = Get-Date
    $duration = ($end - $start).TotalSeconds
    Write-Log "END: $Name (Duration: $([math]::Round($duration,2)) sec)" "OK"
}

# ---------------------------------------------------------------------------
# GLOBAL ERROR HANDLER
# ---------------------------------------------------------------------------

trap {
    Write-Log "UNHANDLED ERROR: $($_.Exception.Message)" "ERROR"
    Write-Log "STACK TRACE: $($_.ScriptStackTrace)" "ERROR"

    $end = Get-Date
    Write-Log "SCRIPT FAILED at $($end.ToString('yyyy-MM-dd HH:mm:ss'))" "ERROR"

    if ($R -and $R.ScriptStartTime) {
        $duration = ($end - $R.ScriptStartTime)
        Write-Log "TOTAL RUNTIME BEFORE FAILURE: $([math]::Round($duration.TotalMinutes,2)) minutes" "ERROR"
    }

    Write-Log "==== FAILURE ====" "ERROR"
    exit 1
}

# ---------------------------------------------------------------------------
# HELPERS
# ---------------------------------------------------------------------------

function Get-RequiredValue {
    param([string]$Value, [string]$Prompt, [switch]$AsSecure)

    if ($Value) { return $Value }

    if ($AsSecure) {
        return Read-Host -Prompt $Prompt -AsSecureString
    }

    do {
        $v = Read-Host -Prompt $Prompt
    } while ([string]::IsNullOrWhiteSpace($v))

    return $v
}

function Save-State {
    param($State)

    if (-not (Test-Path $StateDir)) {
        New-Item -ItemType Directory -Path $StateDir | Out-Null
    }

    $enc = $State.DSRMPasswordSecure | ConvertFrom-SecureString -Key $State.AESKey

    @{
        ServerName       = $State.ServerName
        DomainName       = $State.DomainName
        NetBIOSName      = $State.NetBIOSName
        DSRMEncrypted    = $enc
        AESKey           = ($State.AESKey -join ",")
        CACommonName     = $State.CACommonName
        DomainMode       = $State.DomainMode
        ForestMode       = $State.ForestMode
        ScriptStartTime  = $State.ScriptStartTime.ToString("o")
    } | ConvertTo-Json | Set-Content $StateFile
}

function Load-State {
    if (-not (Test-Path $StateFile)) { return $null }

    $j = Get-Content $StateFile -Raw | ConvertFrom-Json
    $key = $j.AESKey -split "," | ForEach-Object { [byte]$_ }

    return @{
        ServerName         = $j.ServerName
        DomainName         = $j.DomainName
        NetBIOSName        = $j.NetBIOSName
        DSRMPasswordSecure = ($j.DSRMEncrypted | ConvertTo-SecureString -Key $key)
        CACommonName       = $j.CACommonName
        DomainMode         = $j.DomainMode
        ForestMode         = $j.ForestMode
        ScriptStartTime    = [datetime]::Parse($j.ScriptStartTime)
    }
}

function Register-Task {
    $action = New-ScheduledTaskAction -Execute "powershell.exe" `
        -Argument "-ExecutionPolicy Bypass -File `"$ScriptPath`""

    Register-ScheduledTask -TaskName $TaskName `
        -Action $action `
        -Trigger (New-ScheduledTaskTrigger -AtStartup) `
        -Principal (New-ScheduledTaskPrincipal -UserId "SYSTEM" -RunLevel Highest) `
        -Force | Out-Null
}

function Remove-Task {
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
}

# ---------------------------------------------------------------------------
# INIT LOG DIR
# ---------------------------------------------------------------------------

if (-not (Test-Path $StateDir)) {
    New-Item -ItemType Directory -Path $StateDir | Out-Null
}

# ---------------------------------------------------------------------------
# LOAD OR INIT CONFIG
# ---------------------------------------------------------------------------

$saved = Load-State

if ($saved) {
    $R = $saved
    Write-Log "SCRIPT RESUMED at $(Get-Date)" "STEP"
}
else {
    $start = Get-Date
    Write-Log "SCRIPT STARTED at $start" "STEP"

    $Config.DomainName = Get-RequiredValue $Config.DomainName "Domain (e.g. corp.local)"

    if (-not $Config.NetBIOSName) {
        $Config.NetBIOSName = ($Config.DomainName -split '\.')[0].ToUpper()
    }

    $pwd = if ($Config.DSRMPassword) {
        ConvertTo-SecureString $Config.DSRMPassword -AsPlainText -Force
    } else {
        Get-RequiredValue "" "DSRM password" -AsSecure
    }

    $Config.CACommonName = Get-RequiredValue $Config.CACommonName "CA Name"

    $key = New-Object byte[] 32
    ([System.Security.Cryptography.RandomNumberGenerator]::Create()).GetBytes($key)

    $R = @{
        ServerName         = $Config.ServerName
        DomainName         = $Config.DomainName
        NetBIOSName        = $Config.NetBIOSName
        DSRMPasswordSecure = $pwd
        AESKey             = $key
        CACommonName       = $Config.CACommonName
        DomainMode         = $Config.DomainMode
        ForestMode         = $Config.ForestMode
        ScriptStartTime    = $start
    }

    Save-State $R
    Register-Task
}

# ---------------------------------------------------------------------------
# CONFIG LOGGING
# ---------------------------------------------------------------------------

Write-Log "CONFIG:"
Write-Log "  Domain: $($R.DomainName)"
Write-Log "  NetBIOS: $($R.NetBIOSName)"
Write-Log "  CA: $($R.CACommonName)"

# ---------------------------------------------------------------------------
# PRECHECK
# ---------------------------------------------------------------------------

if ($R.DomainName -notmatch "\.") { throw "Invalid domain" }

# ---------------------------------------------------------------------------
# RENAME
# ---------------------------------------------------------------------------

if ($env:COMPUTERNAME -ne $R.ServerName) {
    Rename-Computer -NewName $R.ServerName -Force
    Restart-Computer -Force
    exit
}

# ---------------------------------------------------------------------------
# PROMOTION
# ---------------------------------------------------------------------------

$cs = Get-CimInstance Win32_ComputerSystem
if ($cs.DomainRole -lt 4) {

    Measure-Step "Install AD DS" {
        Install-WindowsFeature AD-Domain-Services -IncludeManagementTools
    }

    Measure-Step "Promote to DC" {
        Install-ADDSForest `
            -DomainName $R.DomainName `
            -DomainNetbiosName $R.NetBIOSName `
            -SafeModeAdministratorPassword $R.DSRMPasswordSecure `
            -InstallDns `
            -Force `
            -NoRebootOnCompletion:$false
    }

    exit
}

# ---------------------------------------------------------------------------
# AD CS
# ---------------------------------------------------------------------------

if (-not (Get-WindowsFeature ADCS-Cert-Authority).Installed) {
    Install-WindowsFeature ADCS-Cert-Authority -IncludeManagementTools
}

if (-not (Test-Path "HKLM:\SYSTEM\CurrentControlSet\Services\CertSvc\Configuration\$($R.CACommonName)")) {
    Install-AdcsCertificationAuthority `
        -CAType EnterpriseRootCA `
        -CACommonName $R.CACommonName `
        -Force
}

# ---------------------------------------------------------------------------
# LDAPS
# ---------------------------------------------------------------------------

certutil -pulse | Out-Null

$cert = Get-ChildItem Cert:\LocalMachine\My | Where-Object {
    $_.EnhancedKeyUsageList.ObjectId -contains "1.3.6.1.5.5.7.3.1"
} | Select-Object -First 1

if ($cert) {
    Write-Log "LDAPS cert OK"
} else {
    Write-Log "LDAPS cert missing" "WARN"
}

# ---------------------------------------------------------------------------
# COMPLETE
# ---------------------------------------------------------------------------

Remove-Task
Remove-Item $StateFile -Force -ErrorAction SilentlyContinue

$end = Get-Date
$dur = ($end - $R.ScriptStartTime)

Write-Log "SCRIPT COMPLETE in $([math]::Round($dur.TotalMinutes,2)) minutes" "OK"

Start-Sleep 10
Stop-Computer -Force