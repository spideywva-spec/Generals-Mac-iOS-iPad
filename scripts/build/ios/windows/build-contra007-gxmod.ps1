param(
    [ValidateSet("stable", "beta")]
    [string] $Channel = "stable",
    [string] $Version = "0.07+FixedAI2+MapFix",
    [string] $MinHubVersion = "1.4.12"
)

$ErrorActionPreference = "Stop"
$SourceRepo = (Resolve-Path (Join-Path $PSScriptRoot "..\..\..\..")).Path
$SourceParent = Split-Path $SourceRepo -Parent
if ((Split-Path $SourceParent -Leaf) -eq "worktrees") {
    $Workspace = Split-Path $SourceParent -Parent
} else {
    $Workspace = $SourceParent
}

$InputDir = Join-Path $Workspace "input\mods\contra-007"
$OutputDir = Join-Path $Workspace "output\mods"
$CacheDir = Join-Path $Workspace "cache\contra-007"
$StageDir = Join-Path $CacheDir "profile"
$MainArchive = Join-Path $InputDir "Contra007.rar"
$AiPatch = Join-Path $InputDir "Contra007FixedAI.zip"
$MapFix = Join-Path $InputDir "Contra007MapFix.zip"
$Builder = Join-Path $SourceRepo "scripts\build\ios\build-gxmod.py"
$Verifier = Join-Path $SourceRepo "scripts\build\ios\verify-gxmod.py"
$Output = Join-Path $OutputDir "contra-007.gxmod"
$Python = if (Get-Command py -ErrorAction SilentlyContinue) { "py" } else { "python" }

$Expected = @{
    $MainArchive = @{ Md5 = "92e617d9c45880faaee9a79ac83edb7c"; Bytes = 115766360 }
    $AiPatch = @{ Md5 = "b0ae31d59da54c06fe3c41b6fee43b22"; Bytes = 249006 }
    $MapFix = @{ Md5 = "32e3770d323ba9e01854d4aa03e9dd9d"; Bytes = 32705 }
}
foreach ($Path in $Expected.Keys) {
    if (-not (Test-Path $Path)) { throw "Missing Contra 007 source: $Path" }
    $Item = Get-Item $Path
    $Hash = (Get-FileHash $Path -Algorithm MD5).Hash.ToLowerInvariant()
    if ($Item.Length -ne $Expected[$Path].Bytes) {
        throw "Size mismatch for ${Path}: expected $($Expected[$Path].Bytes), got $($Item.Length)"
    }
    if ($Hash -ne $Expected[$Path].Md5) {
        throw "MD5 mismatch for ${Path}: expected $($Expected[$Path].Md5), got $Hash"
    }
}

$SevenZipCandidates = @(
    (Get-Command 7z -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Source -ErrorAction SilentlyContinue),
    "C:\Program Files\7-Zip\7z.exe",
    "C:\Program Files (x86)\7-Zip\7z.exe"
) | Where-Object { $_ -and (Test-Path $_) } | Select-Object -Unique
$SevenZip = $SevenZipCandidates | Select-Object -First 1
if (-not $SevenZip) { throw "7-Zip is required to extract Contra007.rar." }

if (Test-Path $CacheDir) { Remove-Item $CacheDir -Recurse -Force }
New-Item -ItemType Directory -Force -Path $StageDir, $OutputDir | Out-Null

$RawDir = Join-Path $CacheDir "raw"
New-Item -ItemType Directory -Force -Path $RawDir | Out-Null
& $SevenZip x -y "-o$RawDir" $MainArchive | Out-Null
if ($LASTEXITCODE -ne 0) { throw "Failed to extract Contra007.rar." }

foreach ($Name in @("!Contra007.big", "!Contra007-en.big", "!Contra006Music.big")) {
    $Source = Join-Path $RawDir $Name
    if (-not (Test-Path $Source)) { throw "Required Contra 007 file is missing: $Name" }
    Copy-Item $Source (Join-Path $StageDir $Name)
}

$AiDir = Join-Path $CacheDir "ai"
$MapDir = Join-Path $CacheDir "map"
Expand-Archive -Path $AiPatch -DestinationPath $AiDir -Force
Expand-Archive -Path $MapFix -DestinationPath $MapDir -Force

$AiSource = Join-Path $AiDir "Generals Zero Hour\Data\Scripts\SkirmishScripts.scb"
$AiTarget = Join-Path $StageDir "Data\Scripts\SkirmishScripts.scb"
New-Item -ItemType Directory -Force -Path (Split-Path $AiTarget) | Out-Null
if (-not (Test-Path $AiSource)) { throw "Fixed AI payload is missing." }
Copy-Item $AiSource $AiTarget

$MapSource = Join-Path $MapDir "Maps\MapCache.ini"
$MapTarget = Join-Path $StageDir "Maps\MapCache.ini"
New-Item -ItemType Directory -Force -Path (Split-Path $MapTarget) | Out-Null
if (-not (Test-Path $MapSource)) { throw "Map Fix payload is missing." }
Copy-Item $MapSource $MapTarget

$Staged = @(Get-ChildItem $StageDir -Recurse -File)
if ($Staged.Count -ne 5) {
    throw "Contra 007 staging must contain exactly 5 files, got $($Staged.Count)."
}

$BuilderArgs = @(
    "--variant", "generic",
    "--generic-source", $StageDir,
    "--profile-id", "contra-007",
    "--name", "Contra 007",
    "--runtime-adapter", "generic",
    "--channel", $Channel,
    "--version", $Version,
    "--min-hub-version", $MinHubVersion,
    "--output", $Output
)
& $Python $Builder @BuilderArgs
if ($LASTEXITCODE -ne 0) { throw "Contra 007 .gxmod build failed." }

& $Python $Verifier $Output
if ($LASTEXITCODE -ne 0) { throw "Contra 007 .gxmod verification failed." }

Write-Host ""
Write-Host "READY: $Output" -ForegroundColor Green
Get-ChildItem $StageDir -Recurse -File |
    ForEach-Object { $_.FullName.Substring($StageDir.Length + 1) } |
    Sort-Object |
    ForEach-Object { Write-Host "  $_" }
