param(
    [ValidateSet("stable", "beta")]
    [string] $Channel = "stable",
    [string] $Version = "0.986-P11",
    [string] $MinHubVersion = "1.4.15"
)

$ErrorActionPreference = "Stop"

$SourceRepo = (Resolve-Path (Join-Path $PSScriptRoot "..\..\..\..")).Path
$SourceParent = Split-Path $SourceRepo -Parent
if ((Split-Path $SourceParent -Leaf) -eq "worktrees") {
    $Workspace = Split-Path $SourceParent -Parent
} else {
    $Workspace = $SourceParent
}

$InputDir = Join-Path $Workspace "input\mods\teod"
$Archive = Join-Path $InputDir "MODDB_Ver11.rar"
$CacheDir = Join-Path $Workspace "cache\teod"
$RawDir = Join-Path $CacheDir "raw"
$StageDir = Join-Path $CacheDir "profile"
$OutputDir = Join-Path $Workspace "output\mods"
$Output = Join-Path $OutputDir "teod.gxmod"
$Builder = Join-Path $SourceRepo "scripts\build\ios\build-gxmod.py"
$Verifier = Join-Path $SourceRepo "scripts\build\ios\verify-gxmod.py"
$Python = if (Get-Command py -ErrorAction SilentlyContinue) { "py" } else { "python" }

$ExpectedMd5 = "0b56d18bab69d45d5a9539fc131d1fc7"
$ExpectedBytes = 669580641

if (-not (Test-Path -LiteralPath $Archive)) {
    throw "Missing TEOD source archive: $Archive"
}
$Item = Get-Item -LiteralPath $Archive
$Hash = (Get-FileHash -LiteralPath $Archive -Algorithm MD5).Hash.ToLowerInvariant()
if ($Item.Length -ne $ExpectedBytes) {
    throw "Size mismatch for $($Archive): expected $ExpectedBytes, got $($Item.Length)"
}
if ($Hash -ne $ExpectedMd5) {
    throw "MD5 mismatch for $($Archive): expected $ExpectedMd5, got $Hash"
}

$SevenZipCandidates = @(
    (Get-Command 7z -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Source -ErrorAction SilentlyContinue),
    "C:\Program Files\7-Zip\7z.exe",
    "C:\Program Files (x86)\7-Zip\7z.exe"
) | Where-Object { $_ -and (Test-Path -LiteralPath $_) } | Select-Object -Unique
$SevenZip = $SevenZipCandidates | Select-Object -First 1
if (-not $SevenZip) {
    throw "7-Zip is required to extract TEOD."
}

if (Test-Path -LiteralPath $RawDir) { Remove-Item $RawDir -Recurse -Force }
if (Test-Path -LiteralPath $StageDir) { Remove-Item $StageDir -Recurse -Force }
New-Item -ItemType Directory -Force -Path $RawDir, $StageDir, $OutputDir | Out-Null

& $SevenZip x -y "-o$RawDir" $Archive | Out-Null
if ($LASTEXITCODE -ne 0) {
    throw "Failed to extract TEOD archive."
}

$RequiredBigs = @(
    "!TEOD_English.big",
    "!TEOD_INI.big",
    "!TEOD_Maps.big",
    "!TEOD_Music.big",
    "!TEOD_Sounds.big",
    "!TEOD_Speech.big",
    "!TEOD_Terrain.big",
    "!TEOD_Textures.big",
    "!TEOD_Voices.big",
    "!TEOD_W3D.big",
    "!TEOD_Window.big"
)
foreach ($Name in $RequiredBigs) {
    $Source = Join-Path $RawDir $Name
    if (-not (Test-Path -LiteralPath $Source)) { throw "Required TEOD BIG is missing: $Name" }
    Copy-Item -LiteralPath $Source -Destination (Join-Path $StageDir $Name)
}

$RequiredLoose = @(
    "Data\Scripts\MultiplayerScripts.scb",
    "Data\Scripts\Scripts.ini",
    "Data\Scripts\SkirmishScripts.scb",
    "Data\English\generals.csf"
)
foreach ($Rel in $RequiredLoose) {
    $Source = Join-Path $RawDir $Rel
    if (-not (Test-Path -LiteralPath $Source)) { throw "Required TEOD loose file is missing: $Rel" }
    $Target = Join-Path $StageDir $Rel
    New-Item -ItemType Directory -Force -Path (Split-Path $Target) | Out-Null
    Copy-Item -LiteralPath $Source -Destination $Target
}

$MoviesSource = Join-Path $RawDir "Data\English\Movies"
if (-not (Test-Path -LiteralPath $MoviesSource)) {
    throw "TEOD English movies directory is missing."
}
$MoviesTarget = Join-Path $StageDir "Data\English\Movies"
New-Item -ItemType Directory -Force -Path $MoviesTarget | Out-Null
Copy-Item -Path (Join-Path $MoviesSource "*") -Destination $MoviesTarget -Recurse -Force

$Disallowed = @(
    "*.exe", "*.dll", "*.bat", "*.cmd", "*.lnk", "*.pdb",
    "*Installation.txt", "*Deinstallation.txt", "Install_Final.bmp", "Backup_Install_Final.bmp"
)
foreach ($Pattern in $Disallowed) {
    if (Get-ChildItem $StageDir -Recurse -File -Filter $Pattern -ErrorAction SilentlyContinue) {
        throw "Disallowed Windows/installer artifact leaked into TEOD staging: $Pattern"
    }
}
if (Test-Path -LiteralPath (Join-Path $StageDir "Data\Backup Scripts")) {
    throw "TEOD backup scripts must not be included in the active profile."
}

$BigCount = @(Get-ChildItem $StageDir -File -Filter "*.big").Count
$ScriptCount = @(Get-ChildItem (Join-Path $StageDir "Data\Scripts") -File).Count
$MovieCount = @(Get-ChildItem $MoviesTarget -File -Filter "*.bik").Count
if ($BigCount -ne 11) { throw "Expected 11 TEOD BIG files, got $BigCount." }
if ($ScriptCount -ne 3) { throw "Expected 3 active TEOD script files, got $ScriptCount." }
if ($MovieCount -lt 1) { throw "Expected TEOD English movies, got none." }

$BuilderArgs = @(
    "--variant", "generic",
    "--generic-source", $StageDir,
    "--profile-id", "teod",
    "--name", "The End of Days",
    "--runtime-adapter", "generic",
    "--channel", $Channel,
    "--version", $Version,
    "--min-hub-version", $MinHubVersion,
    "--output", $Output
)
& $Python $Builder @BuilderArgs
if ($LASTEXITCODE -ne 0) { throw "TEOD .gxmod build failed." }

& $Python $Verifier $Output
if ($LASTEXITCODE -ne 0) { throw "TEOD .gxmod verification failed." }

Write-Host ""
Write-Host "READY: $Output" -ForegroundColor Green
Write-Host "Profile: The End of Days 0.986 P11"
Write-Host "BIG files: $BigCount"
Write-Host "Script files: $ScriptCount"
Write-Host "English movies: $MovieCount"
Write-Host "Excluded: d3d8.dll, The End of Days_Modded.exe, installer images/text, backup scripts"
