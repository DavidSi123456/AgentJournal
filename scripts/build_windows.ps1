param(
    [ValidateSet('debug', 'release')][string]$Configuration = 'debug',
    [switch]$CoreOnly
)
$ErrorActionPreference = 'Stop'
if ($env:OS -ne 'Windows_NT') { throw 'Run this script on Windows, in a Visual Studio developer PowerShell.' }
$projectDir = Split-Path -Parent $PSScriptRoot
$originalLocation = Get-Location
function Invoke-SwiftChecked {
    param([string[]]$Arguments)
    & swift @Arguments
    if ($LASTEXITCODE -ne 0) { throw "Swift failed with exit code $LASTEXITCODE" }
}
try {
    Set-Location $projectDir
    if (-not (Get-Command swift -ErrorAction SilentlyContinue)) { throw 'Install the Swift Windows toolchain first: https://www.swift.org/install/windows/' }
    Invoke-SwiftChecked -Arguments @('--version')
    $corePackage = Join-Path $projectDir '.build/portable-core-package'
    $coreSourceDir = Join-Path $corePackage 'Sources/AgentJournalCore'
    New-Item -ItemType Directory -Force -Path $coreSourceDir | Out-Null
    Copy-Item -LiteralPath (Join-Path $projectDir 'Windows/CorePackage.swift') -Destination (Join-Path $corePackage 'Package.swift')
    foreach ($sourceFile in (Get-Content -LiteralPath (Join-Path $projectDir 'Windows/CoreSources.txt'))) {
        if ($sourceFile -notmatch '^[A-Za-z]+\.swift$') { throw 'Invalid core source filename.' }
        Copy-Item -LiteralPath (Join-Path $projectDir "Sources/AgentJournalKit/$sourceFile") -Destination (Join-Path $coreSourceDir $sourceFile)
    }
    $checksDir = Join-Path $corePackage 'Sources/AgentJournalPortableChecks'
    $cliDir = Join-Path $corePackage 'Sources/AgentJournalPortableCLI'
    New-Item -ItemType Directory -Force -Path $checksDir, $cliDir | Out-Null
    Copy-Item -LiteralPath (Join-Path $projectDir 'Tests/AgentJournalPortableTests/CheckRunner.swift') -Destination $checksDir
    Copy-Item -LiteralPath (Join-Path $projectDir 'Tests/AgentJournalPortableTests/PortableJournalTests.swift') -Destination $checksDir
    Copy-Item -LiteralPath (Join-Path $projectDir 'Sources/AgentJournalPortableCLI/main.swift') -Destination $cliDir
    Invoke-SwiftChecked -Arguments @('run', '--package-path', $corePackage, '--scratch-path', '.build/windows-core', '--jobs', '4', 'AgentJournalPortableChecks')
    Invoke-SwiftChecked -Arguments @('run', '--package-path', $corePackage, '--scratch-path', '.build/windows-core', 'AgentJournalPortableCLI', '--demo')
    if (-not $CoreOnly) {
        Invoke-SwiftChecked -Arguments @('build', '--scratch-path', '.build/windows-desktop', '-c', $Configuration,
                                         '--jobs', '4', '--product', 'AgentJournalWindows')
        $binPath = & swift build --scratch-path .build/windows-desktop -c $Configuration --show-bin-path
        if ($LASTEXITCODE -ne 0) { throw 'Cannot locate the Windows build output.' }
        $executablePath = Join-Path ($binPath | Select-Object -Last 1) 'AgentJournalWindows.exe'
        if (-not (Test-Path -LiteralPath $executablePath -PathType Leaf)) { throw 'The Windows executable was not produced.' }
        Write-Host "Developer build: $executablePath"
        Write-Host 'Run from the build folder on a machine with Swift runtime and the required WinUI runtime installed.'
        Write-Host 'This is NOT a standalone installer, signed release, or full macOS feature equivalent.'
    }
} finally {
    Set-Location $originalLocation
}
