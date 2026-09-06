$ErrorActionPreference = 'Stop'

if (-not [Environment]::Is64BitOperatingSystem) {
    throw 'Hidden Tunes Desktop 1.0.1 requires 64-bit Windows.'
}
if ([Security.Principal.WindowsIdentity]::GetCurrent().IsSystem) {
    throw 'Hidden Tunes is per-user. Run Chocolatey as the intended Windows user, not SYSTEM.'
}

$packageArgs = @{
    packageName = 'hidden-tunes'
    fileType = 'exe'
    url64bit = 'https://downloads.hiddentunes.com/desktop/windows/1.0.1/Hidden-Tunes-Desktop-1.0.1-win-x64.exe'
    checksum64 = '3b8f17048e441ee9cfd9e59b2cab529a3372d3bee61d888796b1ba67be6df40b'
    checksumType64 = 'sha256'
    silentArgs = '/S /currentuser'
    validExitCodes = @(0)
}
Install-ChocolateyPackage @packageArgs

# Confirm the installer registered this version for the invoking Windows account.
$registryPath = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\7ac3b9d9-a2ab-59e0-9fa4-b8f102a0c89e'
$entry = Get-ItemProperty -LiteralPath $registryPath
if ($entry.DisplayVersion -ne '1.0.1' -or $entry.Publisher -ne 'Hidden Tunes') {
    throw 'Hidden Tunes 1.0.1 was not registered for this Windows account.'
}

# The same-account marker prevents this package from uninstalling another user's app.
$toolsDir = Split-Path -Parent $MyInvocation.MyCommand.Definition
$currentSid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
Set-Content -LiteralPath (Join-Path $toolsDir '.hidden-tunes-install-sid') -Value $currentSid -Encoding ASCII
