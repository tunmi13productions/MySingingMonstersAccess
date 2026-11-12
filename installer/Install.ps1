<#
.SYNOPSIS
    Installs My Singing Monsters Access (and Jeode, if missing).
.DESCRIPTION
    1. Finds the game folder (Steam libraries), or asks for it.
    2. Installs the Jeode mod loader from its GitHub releases if it isn't there.
    3. Copies the mod into <game>\mods\msm-a11y.
    4. Builds the menu hooks from YOUR copy of the game's menu files.
    Run it through install.bat. Safe to run again (that is also how you update).
.PARAMETER GamePath
    The folder that contains MySingingMonsters.exe. Found automatically if omitted.
#>
param(
    [string]$GamePath
)

$ErrorActionPreference = "Stop"
$Here = $PSScriptRoot
$Root = Split-Path -Parent $Here
$ModSource = Join-Path $Root "mod\msm-a11y"

. (Join-Path $Here "Common.ps1")

function Fail([string]$text) {
    Say ""
    Say "INSTALL FAILED: $text" Red
    Say ""
    exit 1
}
function Ask([string]$question) {
    $answer = Read-Host "$question (y/n)"
    return $answer.Trim().ToLower().StartsWith("y")
}

Say "My Singing Monsters Access - installer" Cyan
Say "==================================================" Cyan
Say ""

if (-not (Test-Path (Join-Path $ModSource "a11y.dll"))) {
    Fail "the mod files are missing next to this installer (expected $ModSource). Extract the whole zip first, then run install.bat from the extracted folder."
}

$GamePath = Resolve-GamePath $GamePath
if (-not $GamePath) {
    Fail "$ExeName was not found in that folder. Run install.bat again and give the folder that contains $ExeName."
}

# --- The game must be closed -------------------------------------------------
Wait-GameClosed

# --- Jeode -------------------------------------------------------------------
$jeodeDll = Join-Path $GamePath "jeode\libjeode.dll"
$proxyDll = Join-Path $GamePath "winhttp.dll"
if ((Test-Path $jeodeDll) -and (Test-Path $proxyDll)) {
    Say "Jeode mod loader: already installed." Green
} else {
    Say ""
    Say "The Jeode mod loader is not installed. The mod needs it to run." Yellow
    Say "Jeode is a separate project: https://github.com/Paficent/jeode"
    Say "Note: some antivirus programs (Windows Defender, Avast, AVG) wrongly flag Jeode."
    Say "If yours removes it, add the game folder as an exclusion and run this installer again."
    if (-not (Ask "Download and install the latest Jeode now?")) {
        Fail "Jeode is required. Install it from https://github.com/Paficent/jeode/releases/latest and run install.bat again."
    }
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        $headers = @{ "User-Agent" = "msm-a11y-installer" }
        $release = Invoke-RestMethod -Uri "https://api.github.com/repos/Paficent/jeode/releases/latest" -Headers $headers
        Say "Latest Jeode release: $($release.tag_name)"
        $assets = @{}
        foreach ($a in $release.assets) { $assets[$a.name] = $a.browser_download_url }
        foreach ($need in @("winhttp.dll", "libjeode.dll")) {
            if (-not $assets.ContainsKey($need)) { throw "the release has no $need" }
        }
        New-Item -ItemType Directory -Force (Join-Path $GamePath "jeode") | Out-Null
        Invoke-WebRequest -Uri $assets["winhttp.dll"] -OutFile $proxyDll -Headers $headers -UseBasicParsing
        Invoke-WebRequest -Uri $assets["libjeode.dll"] -OutFile $jeodeDll -Headers $headers -UseBasicParsing
    } catch {
        Fail "could not download Jeode ($($_.Exception.Message)). Install it by hand from https://github.com/Paficent/jeode/releases/latest (put winhttp.dll in the game folder and libjeode.dll in a 'jeode' folder inside it), then run install.bat again."
    }
    Say "Jeode installed." Green
}

# --- Jeode's native-mod question ---------------------------------------------
# Jeode asks "Do you wish to load these native mods?" at every launch, because
# this mod has a native part (a11y.dll, for keys and speech). Turn that
# question off in jeode\config.json ("suppress_native_warnings"), keeping every
# other setting as it is. If the file isn't there yet (Jeode writes it on its
# first run), create it with Jeode's usual settings.
$jeodeConfig = Join-Path $GamePath "jeode\config.json"
try {
    if (Test-Path $jeodeConfig) {
        $text = [IO.File]::ReadAllText($jeodeConfig)
        if ($text -match '"suppress_native_warnings"\s*:\s*true') {
            $changed = $false
        } elseif ($text -match '"suppress_native_warnings"\s*:\s*false') {
            $text = $text -replace '("suppress_native_warnings"\s*:\s*)false', '${1}true'
            $changed = $true
        } else {
            $cfg = $text | ConvertFrom-Json
            $cfg | Add-Member -NotePropertyName "suppress_native_warnings" -NotePropertyValue $true -Force
            $text = $cfg | ConvertTo-Json
            $changed = $true
        }
        if ($changed) { [IO.File]::WriteAllText($jeodeConfig, $text) }
    } else {
        New-Item -ItemType Directory -Force (Split-Path -Parent $jeodeConfig) | Out-Null
        $text = "{`r`n  `"last_update_check`": 0,`r`n  `"overlays_enabled`": false,`r`n  `"debug`": false,`r`n  `"allow_unsafe_functions`": false,`r`n  `"suppress_native_warnings`": true,`r`n  `"toggle_key`": `"F1`"`r`n}`r`n"
        [IO.File]::WriteAllText($jeodeConfig, $text)
    }
    Say "Jeode will no longer ask whether to load the mod's native part each time the game starts."
} catch {
    Say "Note: couldn't update Jeode's settings ($($_.Exception.Message)). Jeode may ask 'Do you wish to load these native mods?' when the game starts; answer Yes." Yellow
}

# --- The mod -----------------------------------------------------------------
$modDest = Join-Path $GamePath "mods\msm-a11y"
Say ""
Say "Installing the mod into $modDest ..."
# Keep the player's settings (settings.ini) across reinstalls and updates.
$settingsFile = Join-Path $modDest "settings.ini"
$savedSettings = $null
if (Test-Path $settingsFile) { $savedSettings = Get-Content -Raw $settingsFile }
if (Test-Path $modDest) { Remove-Item -Recurse -Force $modDest }
New-Item -ItemType Directory -Force $modDest | Out-Null
Copy-Item -Recurse -Force (Join-Path $ModSource "*") $modDest
if ($null -ne $savedSettings) { [IO.File]::WriteAllText($settingsFile, $savedSettings) }

if (-not (Test-Path (Join-Path $modDest "prism.dll"))) {
    Say "Warning: prism.dll is missing, so the mod will not be able to speak." Yellow
}

# --- Menu hooks, built from this player's own game files ---------------------
Say "Building the menu hooks from your game's menu files (takes a few seconds)..."
try {
    & (Join-Path $Here "Build-MenuOverrides.ps1") -GamePath $GamePath -OutDir (Join-Path $modDest "data\menus")
} catch {
    Fail "could not build the menu hooks: $($_.Exception.Message)"
}

Say ""
Say "INSTALLED." Green
Say ""
Say "Next:"
Say "  1. Start My Singing Monsters from Steam as usual."
Say "  2. While it loads you should hear: 'My Singing Monsters accessibility mod loaded via Jeode.'"
Say "  3. Press Control+Shift+A for status. The README lists every key."
Say ""
Say "After a game update, run install.bat again so the menu hooks match the new game files."
Say "If something goes wrong, the log is at: $GamePath\data\accessibility.log"
Say ""
