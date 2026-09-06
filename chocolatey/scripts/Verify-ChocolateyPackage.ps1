$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

if ($env:GITHUB_ACTIONS -ne 'true' -or $env:HT_RUNNER_ENVIRONMENT -ne 'github-hosted' -or $env:RUNNER_OS -ne 'Windows') {
    throw 'Refusing execution outside a GitHub-hosted Windows Actions runner.'
}
if ($env:USERNAME -eq 'Wills' -or $env:USERPROFILE -eq 'C:\Users\Wills') {
    throw 'Refusing execution in the owner account.'
}
if (-not $env:RUNNER_TEMP -or -not $env:GITHUB_WORKSPACE -or -not [Environment]::Is64BitOperatingSystem) {
    throw 'The isolated Windows x64 runner environment is missing.'
}
if ([Security.Principal.WindowsIdentity]::GetCurrent().IsSystem) {
    throw 'The current-user installer cannot be qualified as SYSTEM.'
}
$channelRoot = [IO.Path]::GetFullPath((Split-Path -Parent $PSScriptRoot)).TrimEnd('\')
if ($channelRoot -ne [IO.Path]::GetFullPath((Join-Path $env:GITHUB_WORKSPACE 'chocolatey')).TrimEnd('\')) {
    throw 'The script is not in this job checkout.'
}
$runnerTemp = [IO.Path]::GetFullPath($env:RUNNER_TEMP).TrimEnd('\')
$isolatedRoot = [IO.Path]::GetFullPath((Join-Path $runnerTemp 'hiddentunes-chocolatey-qualification'))
if ([IO.Path]::GetDirectoryName($isolatedRoot) -ne $runnerTemp -or (Test-Path -LiteralPath $isolatedRoot)) {
    throw 'The qualification workspace must be a new direct child of RUNNER_TEMP.'
}
$choco = (Get-Command choco.exe -CommandType Application -ErrorAction Stop).Source
if (-not $env:ChocolateyInstall) { throw 'The runner-provided Chocolatey installation was not found.' }
$release = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'release-lock.json') -Raw | ConvertFrom-Json
$registrySuffix = 'Software\Microsoft\Windows\CurrentVersion\Uninstall\' + $release.uninstallProductCode
$userRegistration = Join-Path 'HKCU:' $registrySuffix
$machineRegistrations = @((Join-Path 'HKLM:' $registrySuffix), ('HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\' + $release.uninstallProductCode))
foreach ($key in @($userRegistration) + $machineRegistrations) {
    if (Test-Path -LiteralPath $key) { throw 'A pre-existing Hidden Tunes installation was detected.' }
}
$installedPackageRoot = Join-Path $env:ChocolateyInstall ('lib\' + $release.packageId)
if ((Test-Path -LiteralPath $installedPackageRoot) -or (Get-Process -Name 'Hidden Tunes Desktop' -ErrorAction SilentlyContinue)) {
    throw 'A pre-existing Hidden Tunes package or process was detected.'
}

$packageRoot = Join-Path $channelRoot 'package'
$installScript = Join-Path $packageRoot 'tools\chocolateyInstall.ps1'
$uninstallScript = Join-Path $packageRoot 'tools\chocolateyUninstall.ps1'
if ((Get-FileHash -LiteralPath $installScript -Algorithm SHA256).Hash -ne $release.installScriptSha256 -or
    (Get-FileHash -LiteralPath $uninstallScript -Algorithm SHA256).Hash -ne $release.uninstallScriptSha256) {
    throw 'Package scripts differ from the reviewed installer workflow.'
}
[xml]$nuspec = Get-Content -LiteralPath (Join-Path $packageRoot 'hidden-tunes.nuspec') -Raw
if ($nuspec.package.metadata.id -ne $release.packageId -or $nuspec.package.metadata.version -ne $release.version) {
    throw 'Package ID or version differs from the qualified release.'
}
if ($nuspec.package.metadata.SelectSingleNode('*[local-name()="dependencies"]')) {
    throw 'This local-only qualification must not install dependency packages.'
}

$resultRoot = Join-Path $channelRoot 'ci-results'
$outRoot = Join-Path $isolatedRoot 'packages'
$cacheRoot = Join-Path $isolatedRoot 'cache'
New-Item -ItemType Directory -Path $isolatedRoot, $outRoot, $cacheRoot, $resultRoot | Out-Null
$result = [ordered]@{
    startedUtc = [DateTime]::UtcNow.ToString('o')
    repositoryCommit = $env:GITHUB_SHA
    packageId = $release.packageId
    version = $release.version
    packageBuild = 'NOT RUN'
    silentInstall = 'NOT RUN'
    versionAndIdentity = 'NOT RUN'
    uninstall = 'NOT RUN'
    applicationLaunch = 'NOT REQUESTED; NOT PART OF THIS TEST'
    functionalTesting = 'NOT RUN BY DESIGN'
    communityRepositorySubmission = 'NOT PERFORMED'
    status = 'RUNNING'
}
function Invoke-ChocoStep {
    param([string]$Name, [string[]]$Arguments)
    & $choco @Arguments 2>&1 | Tee-Object -FilePath (Join-Path $resultRoot ('choco-' + $Name + '.log'))
    if ($LASTEXITCODE -ne 0) { throw "Chocolatey $Name failed with exit code $LASTEXITCODE." }
}

try {
    $result.chocolateyVersion = (& $choco --version | Out-String).Trim()
    Invoke-ChocoStep -Name 'pack' -Arguments @('pack', (Join-Path $packageRoot 'hidden-tunes.nuspec'), '--outputdirectory', $outRoot, '--limit-output', '--no-color')
    $nupkg = Join-Path $outRoot ($release.packageId + '.' + $release.version + '.nupkg')
    $archive = [IO.Compression.ZipFile]::OpenRead($nupkg)
    try {
        $entries = @($archive.Entries.FullName)
        if (@($entries | Where-Object { $_ -match '\.(exe|dll|msi|7z|dmg)$' }).Count) { throw 'The package unexpectedly embeds application binaries.' }
        if ($entries -notcontains 'tools/.skipAutoUninstall') { throw 'The scoped auto-uninstall exclusion is missing.' }
    } finally { $archive.Dispose() }
    $result.packageBuild = 'PASS'
    $result.nupkgSha256 = (Get-FileHash -LiteralPath $nupkg -Algorithm SHA256).Hash.ToLowerInvariant()
    $result.packageEntries = $entries
    $result.installerUrl = $release.installerUrl
    $result.installerSha256EnforcedByPackage = $release.installerSha256
    $result.installerArguments = $release.installerArguments

    # Only our own local package is confirmed; no repository account or publishing action occurs.
    Invoke-ChocoStep -Name 'install' -Arguments @('install', $release.packageId, ('--version=' + $release.version), ('--source=' + $outRoot), '--yes', '--no-progress', '--no-color', '--execution-timeout=600', ('--cache-location=' + $cacheRoot))
    if (Get-Process -Name 'Hidden Tunes Desktop' -ErrorAction SilentlyContinue) { throw 'The silent installer unexpectedly launched the application.' }
    $result.silentInstall = 'PASS'
    $entry = Get-ItemProperty -LiteralPath $userRegistration
    if ($entry.DisplayVersion -ne $release.version -or $entry.Publisher -ne $release.publisher) { throw 'The current-user application version or publisher is incorrect.' }
    foreach ($key in $machineRegistrations) { if (Test-Path -LiteralPath $key) { throw 'The per-user package created a machine installation.' } }
    $match = [regex]::Match([string]$entry.UninstallString, '^"(?<file>[^"\r\n]+\\Uninstall Hidden Tunes Desktop\.exe)"\s+/currentuser\s*$', 'IgnoreCase')
    if (-not $match.Success) { throw 'The expected current-user uninstall registration is missing.' }
    $appRoot = [IO.Path]::GetFullPath((Split-Path -Parent $match.Groups['file'].Value)).TrimEnd('\')
    $userLocal = [IO.Path]::GetFullPath([Environment]::GetFolderPath('LocalApplicationData')).TrimEnd('\')
    if (-not $appRoot.StartsWith($userLocal + '\', [StringComparison]::OrdinalIgnoreCase)) { throw 'The application is outside this runner account LocalAppData.' }
    $application = Join-Path $appRoot $release.applicationFile
    $versionInfo = [Diagnostics.FileVersionInfo]::GetVersionInfo($application)
    $applicationHash = (Get-FileHash -LiteralPath $application -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($applicationHash -ne $release.applicationSha256 -or $versionInfo.FileVersion -ne $release.applicationFileVersion -or
        $versionInfo.ProductVersion -ne $release.applicationProductVersion -or $versionInfo.CompanyName -ne $release.publisher) { throw 'The installed application identity differs from the qualified public payload.' }
    $marker = Join-Path $installedPackageRoot 'tools\.hidden-tunes-install-sid'
    if ((Get-Content -LiteralPath $marker -Raw).Trim() -ne [Security.Principal.WindowsIdentity]::GetCurrent().User.Value) { throw 'The package installation-account marker is incorrect.' }
    $result.versionAndIdentity = 'PASS'
    $result.displayName = $entry.DisplayName
    $result.displayVersion = $entry.DisplayVersion
    $result.publisher = $entry.Publisher
    $result.applicationSha256 = $applicationHash
    $result.applicationFileVersion = $versionInfo.FileVersion
    $result.applicationProductVersion = $versionInfo.ProductVersion

    Invoke-ChocoStep -Name 'uninstall' -Arguments @('uninstall', $release.packageId, '--yes', '--no-progress', '--no-color', '--execution-timeout=300')
    $timer = [Diagnostics.Stopwatch]::StartNew()
    while (((Test-Path -LiteralPath $userRegistration) -or (Test-Path -LiteralPath $application)) -and $timer.Elapsed.TotalSeconds -lt 60) { Start-Sleep -Seconds 1 }
    if ((Test-Path -LiteralPath $userRegistration) -or (Test-Path -LiteralPath $application) -or (Test-Path -LiteralPath $installedPackageRoot)) { throw 'The application registration, executable, or Chocolatey package remains after uninstall.' }
    $result.uninstall = 'PASS'
    $result.status = 'PASS'
} catch {
    $result.status = 'FAIL'
    $result.error = $_.Exception.Message
    throw
} finally {
    $result.completedUtc = [DateTime]::UtcNow.ToString('o')
    $result | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $resultRoot 'package-result.json') -Encoding utf8
}
