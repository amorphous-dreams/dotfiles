#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Idempotent WSL2 setup script for Consumer Cellular dev boxes.

.DESCRIPTION
    Installs and configures WSL2 with Ubuntu 24.04 LTS, correct networking
    for use on the corporate VPN (GlobalProtect / NAT + dnsTunneling mode),
    and sensible defaults. Safe to re-run — skips steps already completed.

    What this script does:
      1.  Verifies prerequisites (Windows 11 22H2+, admin rights, VT-x)
      2.  Enables required Windows features (WSL, VirtualMachinePlatform,
          HypervisorPlatform, Hyper-V)
      3.  Installs / updates WSL to the latest pre-release (2.7+)
      4.  Installs Ubuntu 24.04 LTS if not present
      5.  Writes ~/.wslconfig with NAT + dnsTunneling networking
          (mirror mode blocked by IPv6 GPO — see IT ticket template at bottom)
      6.  Sets Ubuntu 24.04 as the default distro
      7.  Provisions WSL with a first-run setup script (git, curl, etc.)
      8.  Copies Windows SSH keys into WSL
      9.  Verifies GitHub SSH connectivity
      10. Copies Setup-Ubuntu.sh sidecar into WSL for post-install steps
      11. Prints a summary and next steps

.PARAMETER SkipSshCopy
    Skip copying SSH keys from Windows to WSL.

.PARAMETER SkipProvision
    Skip running the WSL first-run provisioning (apt installs, git config, etc.).

.PARAMETER WslDistro
    WSL distro name to install. Defaults to 'Ubuntu-24.04'.

.EXAMPLE
    # Standard first-time setup
    .\Setup-WSL2.ps1

    # Re-run safely on existing machine (nothing will be overwritten)
    .\Setup-WSL2.ps1

    # Skip SSH copy if keys not ready yet
    .\Setup-WSL2.ps1 -SkipSshCopy

.NOTES
    Networking: This script configures NAT + dnsTunneling mode. Mirror mode
    is blocked on Consumer Cellular machines by a GPO that sets
    HKLM\SYSTEM\CurrentControlSet\Services\Tcpip6\Parameters\DisabledComponents=0xFF.
    See the IT ticket template at the bottom of this file to request the
    GPO exemption needed for mirror mode.
#>

[CmdletBinding()]
param(
    [switch]$SkipSshCopy,
    [switch]$SkipProvision,
    [string]$WslDistro = "Ubuntu-24.04"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# ── Helpers ───────────────────────────────────────────────────────────────────

function Write-Step   { param($msg) Write-Host "`n  → $msg" -ForegroundColor Cyan }
function Write-Ok     { param($msg) Write-Host "    ✓ $msg" -ForegroundColor Green }
function Write-Skip   { param($msg) Write-Host "    ~ $msg" -ForegroundColor DarkGray }
function Write-Warn   { param($msg) Write-Host "    ! $msg" -ForegroundColor Yellow }
function Write-Fail   { param($msg) Write-Host "    ✗ $msg" -ForegroundColor Red }

# Run a scriptblock with a timeout (seconds). Returns output or $null on timeout.
function Invoke-WithTimeout {
    param(
        [scriptblock]$ScriptBlock,
        [int]$TimeoutSeconds = 30,
        [string]$Label = "operation",
        [object[]]$ArgumentList = @()
    )
    $job = if ($ArgumentList.Count -gt 0) {
        Start-Job -ScriptBlock $ScriptBlock -ArgumentList $ArgumentList
    } else {
        Start-Job -ScriptBlock $ScriptBlock
    }
    $spinner = @('|','/','-','\')
    $i = 0
    $startTime = Get-Date
    while ($true) {
        $elapsed = [int]((Get-Date) - $startTime).TotalSeconds
        if ($elapsed -ge $TimeoutSeconds) { break }
        if ($job.State -ne 'Running') { break }
        Write-Host ("`r    $($spinner[$i % 4]) $Label ($elapsed`s)...   ") -NoNewline -ForegroundColor DarkGray
        Start-Sleep -Milliseconds 250
        $i++
    }
    Write-Host "`r                                                            `r" -NoNewline
    if ($job.State -eq 'Running') {
        Stop-Job $job
        Remove-Job $job -Force
        return $null  # timed out
    }
    $result = Receive-Job $job
    Remove-Job $job -Force
    return $result
}

$RebootRequired = $false

# ── Step 1: Prerequisites ─────────────────────────────────────────────────────

Write-Step "Checking prerequisites"

# Windows version
$build = [System.Environment]::OSVersion.Version.Build
if ($build -lt 22621) {
    Write-Fail "Windows 11 22H2 (build 22621) or later required. Current build: $build"
    exit 1
}
Write-Ok "Windows build $build (22H2+)"

# Admin check
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Fail "Script must be run as Administrator"
    exit 1
}
Write-Ok "Running as Administrator"

# Virtualization check
# VirtualizationFirmwareEnabled reports raw BIOS VT-x flag — can be False on Hyper-V
# guests even when virtualization is fully active. HypervisorPresent is the reliable check.
$virtFirmware  = (Get-CimInstance Win32_Processor).VirtualizationFirmwareEnabled
$hypervisorUp  = (Get-CimInstance Win32_ComputerSystem).HypervisorPresent
$virtEnabled   = $virtFirmware -or $hypervisorUp

if (-not $virtEnabled) {
    Write-Host ""
    Write-Fail "Hardware virtualization (Intel VT-x) is disabled in BIOS/UEFI."
    Write-Host ""
    Write-Host "  To fix this:" -ForegroundColor White
    Write-Host "    1. Reboot and enter UEFI/BIOS setup (F2, F10, Del, or F12 during POST)" -ForegroundColor White
    Write-Host "    2. Find 'Intel Virtualization Technology' or 'VT-x' under Advanced/CPU settings" -ForegroundColor White
    Write-Host "    3. Set it to Enabled" -ForegroundColor White
    Write-Host "    4. Save and exit (F10), then re-run this script" -ForegroundColor White
    Write-Host ""
    Write-Host "  Verify after reboot:" -ForegroundColor DarkGray
    Write-Host "    (Get-CimInstance Win32_ComputerSystem).HypervisorPresent  # should be True" -ForegroundColor DarkGray
    Write-Host ""
    exit 1
}

if ($hypervisorUp) {
    Write-Ok "Hardware virtualization enabled (Hyper-V active)"
} else {
    Write-Ok "Hardware virtualization enabled (VT-x firmware)"
}

# ── Step 2: Windows Features ──────────────────────────────────────────────────

Write-Step "Enabling required Windows features"

$features = @(
    "Microsoft-Windows-Subsystem-Linux",
    "VirtualMachinePlatform",
    "HypervisorPlatform",
    "Microsoft-Hyper-V-All"
)

# If WSL is already functional (modern install path), skip legacy feature flags.
# wsl --install on modern WSL 2.0+ does not require the optional feature to be
# formally "Enabled" in Windows feature list — checking it causes spurious
# reboot prompts on machines where WSL is already working.
$wslAlreadyFunctional = $false
try {
    $wslCheck = wsl --status 2>&1
    if (($wslCheck -join ' ') -match "Default Distribution|Default Version") {
        $wslAlreadyFunctional = $true
    }
} catch { }

if ($wslAlreadyFunctional) {
    Write-Skip "WSL already functional (modern install) — skipping legacy feature checks"
} else {
    foreach ($feature in $features) {
        $state = (Get-WindowsOptionalFeature -Online -FeatureName $feature -ErrorAction SilentlyContinue).State
        if ($state -eq "Enabled") {
            Write-Skip "$feature already enabled"
        } elseif ($null -eq $state) {
            Write-Warn "$feature not found on this SKU — skipping"
        } else {
            Write-Host "    enabling $feature..." -NoNewline
            $result = Enable-WindowsOptionalFeature -Online -FeatureName $feature -All -NoRestart
            if ($result.RestartNeeded) { $RebootRequired = $true }
            Write-Ok "enabled"
        }
    }
}

# HypervisorPlatform boot config
$hvLaunchLine = bcdedit /enum | Select-String "hypervisorlaunchtype"
$hvLaunch = if ($hvLaunchLine) { $hvLaunchLine.ToString().Trim() } else { "" }
if ($hvLaunch -notmatch "Auto") {
    bcdedit /set hypervisorlaunchtype auto | Out-Null
    Write-Ok "Set hypervisorlaunchtype=Auto"
    $RebootRequired = $true
} else {
    Write-Skip "hypervisorlaunchtype already Auto"
}

if ($RebootRequired) {
    Write-Warn "A reboot is required to activate Windows features."
    Write-Warn "Please reboot and re-run this script to continue."
    Write-Host ""
    $choice = Read-Host "  Reboot now? (y/N)"
    if ($choice -match "^[Yy]") { Restart-Computer -Force }
    exit 0
}

# ── Step 3: Install / Update WSL ──────────────────────────────────────────────

Write-Step "Installing / updating WSL"

# Check if wsl.exe exists
$wslExe = Get-Command wsl.exe -ErrorAction SilentlyContinue
if (-not $wslExe) {
    Write-Host "    installing WSL..." -NoNewline
    wsl --install --no-distribution | Out-Null
    Write-Ok "WSL installed"
    $RebootRequired = $true
}

# Update to latest (pre-release for 2.7+ mirror mode fixes)
Write-Host "    updating WSL to latest pre-release..." -NoNewline
$updateResult = Invoke-WithTimeout -TimeoutSeconds 120 -Label "updating WSL" -ScriptBlock {
    wsl --update --pre-release 2>&1
}
if ($null -eq $updateResult) {
    Write-Warn "WSL update timed out — continuing with current version"
} else {
    Write-Ok "WSL updated"
}

# Report version
$wslVersionLine = wsl --version 2>&1 | Select-String "WSL version"
$wslVersion = if ($wslVersionLine) { $wslVersionLine.ToString().Trim() } else { "WSL version unknown" }
Write-Ok $wslVersion

if ($RebootRequired) {
    Write-Warn "Reboot required before continuing. Re-run after reboot."
    $choice = Read-Host "  Reboot now? (y/N)"
    if ($choice -match "^[Yy]") { Restart-Computer -Force }
    exit 0
}

# ── Step 4: Install Ubuntu 24.04 ─────────────────────────────────────────────

Write-Step "Checking WSL distro: $WslDistro"

# Use wsl.exe directly to avoid UTF-16 encoding issues with --list --quiet
# Try multiple detection methods for reliability
$distroInstalled = $false
try {
    # Method 1: wsl --list --verbose (ASCII output)
    $listOutput = (wsl --list --verbose 2>&1) -join " "
    if ($listOutput -match [regex]::Escape($WslDistro)) { $distroInstalled = $true }

    # Method 2: check registry (most reliable)
    $regPath = "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Lxss"
    if (-not $distroInstalled -and (Test-Path $regPath)) {
        $keys = Get-ChildItem $regPath -ErrorAction SilentlyContinue
        foreach ($key in $keys) {
            $dn = (Get-ItemProperty $key.PSPath -ErrorAction SilentlyContinue).DistributionName
            if ($dn -match [regex]::Escape($WslDistro)) { $distroInstalled = $true; break }
        }
    }
} catch {
    $distroInstalled = $false
}

if ($distroInstalled) {
    Write-Skip "$WslDistro already installed"
} else {
    Write-Host ""
    Write-Host "    installing $WslDistro — this downloads ~600MB, may take 5-10 minutes..." -ForegroundColor Cyan
    $distroToInstall = $WslDistro
    $installResult = Invoke-WithTimeout -TimeoutSeconds 600 -Label "downloading $distroToInstall" -ScriptBlock {
        param($d)
        wsl --install -d $d 2>&1
    } -ArgumentList $distroToInstall
    # Re-run without timeout capture to handle interactive cases if needed
    if ($null -eq $installResult) {
        Write-Warn "Install timed out after 10 minutes. Checking if distro registered anyway..."
    } else {
        $installResult | Where-Object { $_ -match '\S' } | ForEach-Object {
            Write-Host "      $_" -ForegroundColor DarkGray
        }
    }
    # Verify the install actually registered the distro
    $postInstall = ((wsl --list --verbose 2>&1) -join "`n") -match [regex]::Escape($WslDistro)
    if (-not $postInstall) {
        Write-Host ""
        Write-Fail "$WslDistro installation did not complete successfully."
        Write-Host ""
        Write-Host "  Try installing manually and re-run this script:" -ForegroundColor White
        Write-Host "    wsl --install -d $WslDistro" -ForegroundColor Yellow
        Write-Host ""
        Write-Host "  If that fails, try from the Microsoft Store:" -ForegroundColor White
        Write-Host "    https://aka.ms/wslstore" -ForegroundColor Yellow
        Write-Host ""
        exit 1
    }
    Write-Ok "$WslDistro installed successfully"
}

# Verify distro is fully initialized (OOBE complete)
$distroReady = wsl -d $WslDistro -- echo "ready" 2>&1
if ($distroReady -notmatch "ready") {
    Write-Host ""
    Write-Warn "$WslDistro was installed but has not been initialized yet."
    Write-Host ""
    Write-Host "  Complete first-time Ubuntu setup by running:" -ForegroundColor White
    Write-Host "    wsl -d $WslDistro" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "  You will be prompted to create a Linux username and password." -ForegroundColor White
    Write-Host "  Once complete, type 'exit' to return to PowerShell, then re-run:" -ForegroundColor White
    Write-Host "    .\Setup-WSL2.ps1" -ForegroundColor Yellow
    Write-Host ""
    exit 0
}
Write-Ok "$WslDistro initialized and ready"

# Set as default
wsl --set-default $WslDistro 2>&1 | Out-Null
Write-Ok "$WslDistro set as default distro"

# Ensure WSL 2 (not WSL 1)
wsl --set-version $WslDistro 2 2>&1 | Out-Null
Write-Ok "WSL version set to 2"

# ── Step 5: Write .wslconfig ──────────────────────────────────────────────────

Write-Step "Writing .wslconfig"

$wslConfigPath = "$env:USERPROFILE\.wslconfig"
$wslConfigContent = @"
# WSL2 configuration — managed by Setup-WSL2.ps1
#
# NOTE: networkingMode=mirrored is blocked on Consumer Cellular machines by
# a GPO that sets DisabledComponents=0xFF on the IPv6 stack. NAT mode with
# dnsTunneling provides VPN DNS resolution for internal hostnames.
# See IT ticket template at bottom of Setup-WSL2.ps1 to request mirror mode.

[wsl2]
networkingMode=nat
dnsTunneling=true
firewall=true
autoProxy=true
"@

if (Test-Path $wslConfigPath) {
    $existing = Get-Content $wslConfigPath -Raw
    # Compare only functional settings, ignoring comments and whitespace
    $extractSettings = { param($s) ($s -split "`n" | Where-Object { $_ -match "^\s*[^#\s]" } | ForEach-Object { $_.Trim() }) -join "`n" }
    $existingSettings = & $extractSettings $existing
    $newSettings = & $extractSettings $wslConfigContent
    if ($existingSettings -eq $newSettings) {
        Write-Skip ".wslconfig already up to date"
    } else {
        $backup = "$wslConfigPath.bak.$(Get-Date -Format 'yyyyMMdd-HHmmss')"
        Copy-Item $wslConfigPath $backup
        Write-Warn "Existing .wslconfig backed up to $backup"
        Set-Content $wslConfigPath $wslConfigContent -Encoding UTF8
        Write-Ok ".wslconfig updated"
    }
} else {
    Set-Content $wslConfigPath $wslConfigContent -Encoding UTF8
    Write-Ok ".wslconfig written"
}

# ── Step 6: Restart WSL to apply config ───────────────────────────────────────

Write-Step "Restarting WSL to apply config"
# Only shut down if WSL is actually running
$wslRunning = wsl --list --running 2>&1
$wslHasRunning = ($wslRunning -join " ") -match [regex]::Escape($WslDistro)
if ($wslHasRunning) {
    $shutdownResult = Invoke-WithTimeout -TimeoutSeconds 20 -Label "shutting down WSL" -ScriptBlock {
        wsl --shutdown 2>&1
    }
    if ($null -eq $shutdownResult) {
        Write-Warn "wsl --shutdown timed out — WSL may still be stopping. Continuing after delay."
        Start-Sleep -Seconds 5
    } else {
        Start-Sleep -Seconds 2
        Write-Ok "WSL shutdown and restarted"
    }
} else {
    Write-Skip "WSL not running — no shutdown needed"
}

# ── Step 7: First-run provisioning ───────────────────────────────────────────

if (-not $SkipProvision) {
    Write-Step "Running first-run provisioning in WSL"

    $provisionScript = @'
#!/usr/bin/env bash
set -euo pipefail

LOG="/tmp/wsl_provision.log"
echo "  → Updating apt (output in $LOG)..."
sudo apt-get update -qq > "$LOG" 2>&1
sudo apt-get upgrade -y -qq >> "$LOG" 2>&1
UPGRADED=$(grep -c "^Unpacking" "$LOG" 2>/dev/null); UPGRADED=${UPGRADED:-0}
echo "    packages upgraded: $UPGRADED"

echo "  → Installing core packages..."
sudo apt-get install -y -qq     git     curl     wget     unzip     jq     build-essential     ca-certificates     gnupg     lsb-release     openssh-client     >> "$LOG" 2>&1
INSTALLED=$(grep -c "^Selecting previously unselected" "$LOG" 2>/dev/null); INSTALLED=${INSTALLED:-0}
echo "    new packages installed: $INSTALLED"

echo "  → Configuring git safe directory..."
git config --global --add safe.directory '*' 2>/dev/null || true

echo "  → Setting up .ssh directory..."
mkdir -p ~/.ssh
chmod 700 ~/.ssh

echo "  → WSL provisioning complete (full log: $LOG)"
'@

    # Write provision script to temp location accessible from WSL
    $tmpScript = "$env:TEMP\wsl_provision.sh"
    Set-Content $tmpScript $provisionScript -Encoding UTF8

    # Convert Windows path to WSL path
    $wslTmpPath = "/mnt/c/Users/$env:USERNAME/AppData/Local/Temp/wsl_provision.sh"

    wsl -d $WslDistro -- bash "$wslTmpPath"
    Remove-Item $tmpScript -ErrorAction SilentlyContinue
    Write-Ok "Provisioning complete"
} else {
    Write-Skip "Provisioning skipped (-SkipProvision)"
}

# ── Step 8: Copy SSH keys ────────────────────────────────────────────────────

if (-not $SkipSshCopy) {
    Write-Step "Copying SSH keys from Windows to WSL"

    $winSsh = "$env:USERPROFILE\.ssh"
    $winSshWsl = ($winSsh -replace 'C:\\', '/mnt/c/' -replace '\\', '/')

    if (-not (Test-Path $winSsh)) {
        Write-Warn "No .ssh directory found at $winSsh — skipping key copy"
        Write-Warn "Generate keys on Windows first: ssh-keygen -t ed25519 -C 'your@email.com'"
    } else {
        $copyScript = @"
#!/usr/bin/env bash
set -euo pipefail
WIN_SSH="$winSshWsl"
WSL_SSH="`$HOME/.ssh"
mkdir -p "`$WSL_SSH"
chmod 700 "`$WSL_SSH"
COPIED=0
SKIPPED=0

for src in "`$WIN_SSH"/id_* "`$WIN_SSH"/github_* "`$WIN_SSH"/*.pem; do
  [[ -e "`$src" ]] || continue
  [[ "`$src" == *.pub ]] && continue
  filename="`$(basename "`$src")"
  dst="`$WSL_SSH/`$filename"
  if [[ -f "`$dst" ]]; then
    echo "    ~ skipping `$filename (already exists)"
    ((SKIPPED++))
  else
    cp "`$src" "`$dst"
    chmod 600 "`$dst"
    echo "    ✓ copied  `$filename"
    ((COPIED++))
  fi
  # Always sync .pub independently — don't skip if private key was skipped
  if [[ -f "`$src.pub" ]]; then
    pub_dst="`$WSL_SSH/`$filename.pub"
    if [[ -f "`$pub_dst" ]]; then
      echo "    ~ skipping `$filename.pub (already exists)"
      ((SKIPPED++))
    else
      cp "`$src.pub" "`$pub_dst"
      chmod 644 "`$pub_dst"
      echo "    ✓ copied  `$filename.pub"
      ((COPIED++))
    fi
  fi
done

if [[ -f "`$WIN_SSH/config" && ! -f "`$WSL_SSH/config" ]]; then
  cp "`$WIN_SSH/config" "`$WSL_SSH/config"
  chmod 600 "`$WSL_SSH/config"
  echo "    ✓ copied  config"
  ((COPIED++))
fi

echo "    Done — `$COPIED copied, `$SKIPPED skipped"
"@
        $tmpCopy = "$env:TEMP\wsl_ssh_copy.sh"
        Set-Content $tmpCopy $copyScript -Encoding UTF8
        # Convert TEMP path to WSL mount path dynamically
        $wslCopyPath = ($tmpCopy -replace 'C:\\', '/mnt/c/' -replace '\\', '/') 
        wsl -d $WslDistro -- bash "$wslCopyPath"
        Remove-Item $tmpCopy -ErrorAction SilentlyContinue
    }
} else {
    Write-Skip "SSH key copy skipped (-SkipSshCopy)"
}

# ── Step 9: Verify GitHub SSH ────────────────────────────────────────────────

Write-Step "Testing GitHub SSH connectivity"
try {
    $ghResult = wsl -d $WslDistro -- ssh -T git@github.com -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 2>&1
    $ghClean = ($ghResult | Where-Object { $_ -notmatch "Warning:|Permanently added" }) -join " "
    if ($ghClean -match "successfully authenticated") {
        Write-Ok $ghClean.Trim()
    } else {
        Write-Warn "GitHub SSH test inconclusive — run 'ssh -T git@github.com' in WSL to verify"
    }
} catch {
    Write-Warn "GitHub SSH test skipped (no keys or network issue)"
}

# ── Step 10: Verify networking ───────────────────────────────────────────────

Write-Step "Verifying WSL networking"
$pingResult = wsl -d $WslDistro -- bash -c "ping -c 2 -W 3 8.8.8.8 2>&1"
if ($pingResult -match "0% packet loss|0 packet loss") {
    Write-Ok "Internet connectivity confirmed"
} elseif ($pingResult -match "bytes from") {
    Write-Ok "Internet connectivity confirmed"
} else {
    Write-Warn "Ping test inconclusive — run 'ping 8.8.8.8' in WSL to verify"
}

$dnsResult = wsl -d $WslDistro -- bash -c "getent hosts github.com 2>&1 | head -1"
if ($dnsResult -match "\d+\.\d+\.\d+\.\d+") {
    Write-Ok "DNS resolution working"
} else {
    Write-Warn "DNS test inconclusive"
}

# ── Step 11: Copy sidecar script into WSL ────────────────────────────────────

Write-Step "Copying Setup-Ubuntu.sh sidecar into WSL"

$sidecarSrc = Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) "Setup-Ubuntu.sh"
if (-not (Test-Path $sidecarSrc)) {
    $sidecarSrc = Join-Path (Get-Location) "Setup-Ubuntu.sh"
}

if (Test-Path $sidecarSrc) {
    # Get WSL home via $HOME — no bash redirects that PS misinterprets as Windows paths
    $wslHome = wsl -d $WslDistro -- bash -c "echo `$HOME"
    $wslHome = ($wslHome | Select-Object -First 1).Trim().TrimEnd("`r")
    $wslSrc  = ($sidecarSrc -replace '^([A-Z]):', { '/mnt/' + $_.Groups[1].Value.ToLower() } -replace '\\', '/')
    $sidecarDst = "$wslHome/Setup-Ubuntu.sh"

    $copyOut = wsl -d $WslDistro -- bash -c "cp '$wslSrc' '$sidecarDst' && chmod +x '$sidecarDst' && echo ok"
    if (($copyOut -join '') -match 'ok') {
        Write-Ok "Setup-Ubuntu.sh copied to $sidecarDst"
        Write-Ok "Run inside WSL: bash ~/Setup-Ubuntu.sh"
    } else {
        Write-Warn "Copy inconclusive — verify manually inside WSL:"
        Write-Warn "  ls ~/Setup-Ubuntu.sh"
    }
} else {
    Write-Warn "Setup-Ubuntu.sh not found alongside Setup-WSL2.ps1"
    Write-Warn "Expected at: $sidecarSrc"
    Write-Warn "Place both scripts in the same directory and re-run"
}


# ── Summary ───────────────────────────────────────────────────────────────────

Write-Host ""
Write-Host "  ════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host "   WSL2 Setup Complete" -ForegroundColor Cyan
Write-Host "  ════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host ""
Write-Host "  Distro   : $WslDistro"
Write-Host "  Network  : NAT + dnsTunneling (VPN-compatible)"
Write-Host "  Config   : $env:USERPROFILE\.wslconfig"
Write-Host ""
Write-Host "  Launch WSL:  wsl ~" -ForegroundColor White
Write-Host "  VS Code:     code-insiders . (from inside WSL)" -ForegroundColor White
Write-Host ""

if ($RebootRequired) {
    Write-Warn "A reboot is still pending. Reboot when convenient."
    Write-Host ""
}

Write-Host "  Mirror mode (optional / needs IT):" -ForegroundColor DarkGray
Write-Host "  Request GPO exemption: DisabledComponents=0x20" -ForegroundColor DarkGray
Write-Host "  Key: HKLM\SYSTEM\CurrentControlSet\Services\Tcpip6\Parameters" -ForegroundColor DarkGray
Write-Host ""

# ── Next Steps ────────────────────────────────────────────────────────────────

Write-Host "  ════════════════════════════════════════════════════" -ForegroundColor DarkCyan
Write-Host "   Next Steps — Finishing Your WSL2 Environment" -ForegroundColor DarkCyan
Write-Host "  ════════════════════════════════════════════════════" -ForegroundColor DarkCyan
Write-Host ""
Write-Host "  ┌─ FIRST: Inside WSL (wsl ~) ──────────────────────" -ForegroundColor White
Write-Host ""
Write-Host "  Run the sidecar script — it handles steps 1-8 idempotently:" -ForegroundColor White
Write-Host "    bash ~/Setup-Ubuntu.sh" -ForegroundColor Yellow
Write-Host "    bash ~/Setup-Ubuntu.sh --dry-run   # preview first" -ForegroundColor DarkGray
Write-Host "    bash ~/Setup-Ubuntu.sh --skip-docker  # flags available" -ForegroundColor DarkGray
Write-Host ""
Write-Host "  Or run steps manually:" -ForegroundColor DarkGray
Write-Host ""
Write-Host "  1. Tune /etc/wsl.conf  ← do this first, requires WSL restart" -ForegroundColor Cyan
Write-Host "       sudo tee /etc/wsl.conf <<EOF" -ForegroundColor DarkGray
Write-Host "       [user]" -ForegroundColor DarkGray
Write-Host "       default=<your-linux-username>" -ForegroundColor DarkGray
Write-Host "       [network]" -ForegroundColor DarkGray
Write-Host "       generateResolvConf=false" -ForegroundColor DarkGray
Write-Host "       [interop]" -ForegroundColor DarkGray
Write-Host "       appendWindowsPath=false  # prevents Windows PATH bleeding into WSL" -ForegroundColor DarkGray
Write-Host "       EOF" -ForegroundColor DarkGray
Write-Host ""
Write-Host "  ┌─ THEN: From PowerShell — restart WSL ────────────" -ForegroundColor White
Write-Host ""
Write-Host "  2. Restart WSL to apply wsl.conf" -ForegroundColor Cyan
Write-Host "       wsl --shutdown" -ForegroundColor DarkGray
Write-Host "       wsl ~" -ForegroundColor DarkGray
Write-Host ""
Write-Host "  ┌─ THEN: Back inside WSL ───────────────────────────" -ForegroundColor White
Write-Host ""
Write-Host "  3. Set your Git identity" -ForegroundColor Cyan
Write-Host "       git config --global user.name `"Your Name`"" -ForegroundColor DarkGray
Write-Host "       git config --global user.email `"you@consumercellular.com`"" -ForegroundColor DarkGray
Write-Host "       git config --global init.defaultBranch main" -ForegroundColor DarkGray
Write-Host ""
Write-Host "  4. Add SSH agent to ~/.bashrc (or ~/.zshrc if using zsh)" -ForegroundColor Cyan
Write-Host "       echo 'eval `"`$(ssh-agent -s)`"' >> ~/.bashrc" -ForegroundColor DarkGray
Write-Host "       echo 'ssh-add ~/.ssh/id_ed25519 2>/dev/null' >> ~/.bashrc" -ForegroundColor DarkGray
Write-Host "       source ~/.bashrc" -ForegroundColor DarkGray
Write-Host ""
Write-Host "  5. Install Node.js via nvm  ← required before Claude Code" -ForegroundColor Cyan
Write-Host "       curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.39.7/install.sh | bash" -ForegroundColor DarkGray
Write-Host "       source ~/.bashrc  # load nvm into current shell" -ForegroundColor DarkGray
Write-Host "       nvm install --lts" -ForegroundColor DarkGray
Write-Host "       node --version && npm --version  # verify" -ForegroundColor DarkGray
Write-Host ""
Write-Host "  6. Install Claude Code CLI" -ForegroundColor Cyan
Write-Host "       npm install -g @anthropic-ai/claude-code" -ForegroundColor DarkGray
Write-Host "       claude auth  # authenticate on first run" -ForegroundColor DarkGray
Write-Host "       claude  # launch interactive agent" -ForegroundColor DarkGray
Write-Host ""
Write-Host "  7. Clone your repos" -ForegroundColor Cyan
Write-Host "       mkdir -p ~/dev && cd ~/dev" -ForegroundColor DarkGray
Write-Host "       git clone git@github.com:your-org/your-repo.git" -ForegroundColor DarkGray
Write-Host ""
Write-Host "  8. Optional runtimes" -ForegroundColor Cyan
Write-Host "       Python  →  python3 --version  (3.12 already installed)" -ForegroundColor DarkGray
Write-Host ""
Write-Host "       Docker CE (team standard — NOM Container Tool Decision, May 2025)" -ForegroundColor DarkGray
Write-Host "       Install Docker Engine CE inside WSL — no Docker Desktop required or licensed." -ForegroundColor DarkGray
Write-Host "         curl -fsSL https://get.docker.com | sh" -ForegroundColor DarkGray
Write-Host "         sudo usermod -aG docker `$USER" -ForegroundColor DarkGray
Write-Host "         wsl --shutdown && wsl ~  # restart to apply group membership" -ForegroundColor DarkGray
Write-Host "         docker run hello-world  # verify" -ForegroundColor DarkGray
Write-Host "       Note: Docker Desktop is the long-term GUI plan pending enterprise licensing." -ForegroundColor DarkGray
Write-Host "       Do not install Docker Desktop without confirming org license with IT." -ForegroundColor DarkGray
Write-Host ""
Write-Host "  9. Optional — zsh + Starship prompt" -ForegroundColor Cyan
Write-Host "       sudo apt install -y zsh && chsh -s `$(which zsh)" -ForegroundColor DarkGray
Write-Host "       curl -sS https://starship.rs/install.sh | sh" -ForegroundColor DarkGray
Write-Host "       echo 'eval `"`$(starship init zsh)`"' >> ~/.zshrc" -ForegroundColor DarkGray
Write-Host "       # Then restart WSL: wsl --shutdown && wsl ~" -ForegroundColor DarkGray
Write-Host ""
Write-Host "  ┌─ VS Code Insiders ────────────────────────────────" -ForegroundColor White
Write-Host ""
Write-Host "  10. Connect VS Code Insiders to WSL" -ForegroundColor Cyan
Write-Host "        From inside WSL:  code-insiders ." -ForegroundColor DarkGray
Write-Host "        Or from Windows:  F1 → 'WSL: Connect to WSL'" -ForegroundColor DarkGray
Write-Host ""
Write-Host "  11. Install Claude for VS Code (in WSL context)" -ForegroundColor Cyan
Write-Host "        Ctrl+Shift+X → search 'Claude' → 'Install in WSL: Ubuntu-24.04'" -ForegroundColor DarkGray
Write-Host "        ext install Anthropic.claude-vscode" -ForegroundColor DarkGray
Write-Host "        Both Claude Code CLI and this extension share your Anthropic account." -ForegroundColor DarkGray
Write-Host ""
Write-Host "  ════════════════════════════════════════════════════" -ForegroundColor DarkCyan
Write-Host 
