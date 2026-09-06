$ErrorActionPreference = 'Stop'

$toolsDir = Split-Path -Parent $MyInvocation.MyCommand.Definition
$marker = Join-Path $toolsDir '.hidden-tunes-install-sid'
$currentSid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
if (-not (Test-Path -LiteralPath $marker -PathType Leaf)) {
    throw 'Installation-account evidence is missing. Remove Hidden Tunes using Windows Installed Apps in its installation account.'
}
$installSid = (Get-Content -LiteralPath $marker | Out-String).Trim()
if ($installSid -ne $currentSid) {
    throw 'Hidden Tunes was installed for a different Windows account. Uninstall from that account.'
}

$registryPath = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\7ac3b9d9-a2ab-59e0-9fa4-b8f102a0c89e'
if (Test-Path -LiteralPath $registryPath) {
    $entry = Get-ItemProperty -LiteralPath $registryPath
    if ($entry.Publisher -ne 'Hidden Tunes' -or $entry.DisplayName -notlike 'Hidden Tunes Desktop *') {
        throw 'The registered application does not match Hidden Tunes Desktop.'
    }
    # Parse only the exact quoted NSIS current-user form; never evaluate registry text.
    $match = [regex]::Match([string]$entry.UninstallString, '^"(?<file>[^"\r\n]+\\Uninstall Hidden Tunes Desktop\.exe)"\s+/currentuser\s*$', 'IgnoreCase')
    if (-not $match.Success) {
        throw 'The current-user uninstaller registration has an unexpected format.'
    }
    $uninstaller = $match.Groups['file'].Value
    if (-not [IO.Path]::IsPathRooted($uninstaller) -or -not (Test-Path -LiteralPath $uninstaller -PathType Leaf)) {
        throw 'The registered Hidden Tunes uninstaller is unavailable.'
    }
    $packageArgs = @{
        packageName = 'hidden-tunes'
        fileType = 'exe'
        file = $uninstaller
        silentArgs = '/S /currentuser'
        validExitCodes = @(0)
    }
    Uninstall-ChocolateyPackage @packageArgs
}
Remove-Item -LiteralPath $marker -Force
