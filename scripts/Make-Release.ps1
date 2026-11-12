<#
.SYNOPSIS
    Packages a player-ready zip: install.bat + installer scripts + the built mod.
.DESCRIPTION
    Run after Build-Prism.bat and Build-Jeode.bat (the release workflow does all
    three). No game files go in the zip: the installer builds the menu hooks from
    the player's own copy of the game.
.PARAMETER Version
    Version label, e.g. 0.1.0 (a leading "v" is dropped). Stamped into manifest.json.
#>
param(
    [Parameter(Mandatory = $true)][string]$Version
)

$ErrorActionPreference = "Stop"
$Root = Split-Path -Parent $PSScriptRoot
$Version = $Version.TrimStart("v")
$Name = "msm-a11y-$Version"
$Out = Join-Path $Root "release"
$Stage = Join-Path $Out $Name
$ModSrc = Join-Path $Root "jeode\msm-a11y"
$Prism = Join-Path $Root "native\prism\prism.dll"

foreach ($need in @((Join-Path $ModSrc "a11y.dll"), (Join-Path $ModSrc "init.lua"), $Prism)) {
    if (-not (Test-Path $need)) { throw "missing $need - build first (Build-Prism.bat, Build-Jeode.bat)" }
}

if (Test-Path $Stage) { Remove-Item -Recurse -Force $Stage }
$modDest = Join-Path $Stage "mod\msm-a11y"
$instDest = Join-Path $Stage "installer"
$licDest = Join-Path $Stage "licenses"
New-Item -ItemType Directory -Force $modDest, $instDest, $licDest | Out-Null

Copy-Item (Join-Path $ModSrc "a11y.dll"), (Join-Path $ModSrc "init.lua"), $Prism $modDest
$manifest = Get-Content (Join-Path $ModSrc "manifest.json") -Raw | ConvertFrom-Json
$manifest.version = $Version
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
[System.IO.File]::WriteAllText((Join-Path $modDest "manifest.json"), ($manifest | ConvertTo-Json -Depth 10), $utf8NoBom)

Copy-Item (Join-Path $Root "installer\install.bat"), (Join-Path $Root "installer\update.bat"), (Join-Path $Root "installer\uninstall.bat"), (Join-Path $Root "installer\debug.bat") $Stage
Copy-Item (Join-Path $Root "installer\Common.ps1"), (Join-Path $Root "installer\Install.ps1"), (Join-Path $Root "installer\Update.ps1"), (Join-Path $Root "installer\Uninstall.ps1"), (Join-Path $Root "installer\Collect-Logs.ps1"), (Join-Path $Root "scripts\Build-MenuOverrides.ps1") $instDest
Copy-Item (Join-Path $Root "README.md"), (Join-Path $Root "CHANGELOG.md"), (Join-Path $Root "tutorial.md"), (Join-Path $Root "getting-started.md"), (Join-Path $Root "breeding-guide.md"), (Join-Path $Root "clubbox-guide.md"), (Join-Path $Root "tips.md") $Stage
if (Test-Path (Join-Path $Root "LICENSE")) { Copy-Item (Join-Path $Root "LICENSE") $Stage }
$prismLicense = Join-Path $Root "native\prism\PRISM-LICENSE.txt"
if (Test-Path $prismLicense) { Copy-Item $prismLicense (Join-Path $licDest "Prism-MPL-2.0.txt") }

$zip = Join-Path $Out "$Name.zip"
if (Test-Path $zip) { Remove-Item -Force $zip }
Compress-Archive -Path $Stage -DestinationPath $zip
Write-Host "release zip: $zip"
