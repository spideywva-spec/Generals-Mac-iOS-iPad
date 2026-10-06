param(
    [ValidateSet("stable", "beta")]
    [string] $Channel = "stable",
    [string] $Version = "009-Final+P3-HF4",
    [string] $MinHubVersion = "1.4.13"
)

$ErrorActionPreference = "Stop"
$SourceRepo = (Resolve-Path (Join-Path $PSScriptRoot "..\..\..\..")).Path
$SourceParent = Split-Path $SourceRepo -Parent
if ((Split-Path $SourceParent -Leaf) -eq "worktrees") {
    $Workspace = Split-Path $SourceParent -Parent
} else {
    $Workspace = $SourceParent
}

$InputDir = Join-Path $Workspace "input\mods\contra-009"
$OutputDir = Join-Path $Workspace "output\mods"
$CacheDir = Join-Path $Workspace "cache\contra-009"
$ExtractRoot = Join-Path $CacheDir "simdec"
$InstallDir = Join-Path $ExtractRoot "InstallPath"
$BuildDir = Join-Path $CacheDir "build"
$StageDir = Join-Path $CacheDir "profile"
$Setup = Join-Path $InputDir "Contra009Setup.exe"
$Builder = Join-Path $SourceRepo "scripts\build\ios\build-gxmod.py"
$Verifier = Join-Path $SourceRepo "scripts\build\ios\verify-gxmod.py"
$Output = Join-Path $OutputDir "contra-009.gxmod"
$Python = if (Get-Command py -ErrorAction SilentlyContinue) { "py" } else { "python" }

$Hotfix1 = Join-Path $InputDir "Contra009FinalPatch3Hotfix.1.rar"
$Hotfix2 = Join-Path $InputDir "Contra009FinalPatch3Hotfix2.rar"
$Hotfix3 = Join-Path $InputDir "Contra009FinalPatch3Hotfix3.1.rar"
$Hotfix4 = Join-Path $InputDir "Contra009FinalPatch3Hotfix4.rar"

$Expected = @{
    $Setup   = @{ Md5 = "aa68311fdcd5f14279a9e0caeb9e3407"; Bytes = 1309558852 }
    $Hotfix1 = @{ Md5 = "0cb962c51da2d4ada6da4c9bdbc77f8a"; Bytes = 22727337 }
    $Hotfix2 = @{ Md5 = "8c6915f78a3e1712354a38e8ab9a0ace"; Bytes = 2952775 }
    $Hotfix3 = @{ Md5 = "5c79c1f95651dfcdad2df1fdd98efbe7"; Bytes = 6580488 }
    $Hotfix4 = @{ Md5 = "8ce80eef912fcbea71851d8cbf044224"; Bytes = 3069363 }
}
foreach ($Path in $Expected.Keys) {
    if (-not (Test-Path -LiteralPath $Path)) { throw "Missing Contra 009 source: $Path" }
    $Item = Get-Item -LiteralPath $Path
    $Hash = (Get-FileHash -LiteralPath $Path -Algorithm MD5).Hash.ToLowerInvariant()
    if ($Item.Length -ne $Expected[$Path].Bytes) {
        throw "Size mismatch for $($Path): expected $($Expected[$Path].Bytes), got $($Item.Length)"
    }
    if ($Hash -ne $Expected[$Path].Md5) {
        throw "MD5 mismatch for $($Path): expected $($Expected[$Path].Md5), got $Hash"
    }
}

$SevenZipCandidates = @(
    (Get-Command 7z -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Source -ErrorAction SilentlyContinue),
    "C:\Program Files\7-Zip\7z.exe",
    "C:\Program Files (x86)\7-Zip\7z.exe"
) | Where-Object { $_ -and (Test-Path -LiteralPath $_) } | Select-Object -Unique
$SevenZip = $SevenZipCandidates | Select-Object -First 1
if (-not $SevenZip) { throw "7-Zip is required to extract Contra 009 hotfix archives." }

if (-not (Test-Path -LiteralPath (Join-Path $InstallDir "!Contra009Final.ctr"))) {
    $Simdec = Join-Path $Workspace "cache\tools\simdec-nightly\simdec.exe"
    foreach ($Tool in @(
        $Simdec,
        (Join-Path (Split-Path $Simdec -Parent) "Bio.cs.dll"),
        (Join-Path (Split-Path $Simdec -Parent) "Microsoft.Deployment.Compression.dll"),
        (Join-Path (Split-Path $Simdec -Parent) "Microsoft.Deployment.Compression.Cab.dll")
    )) {
        if (-not (Test-Path -LiteralPath $Tool)) {
            throw "Smart Install Maker extractor is missing: $Tool. Restore cache\tools\simdec-nightly or pre-extract Contra009Setup.exe into $ExtractRoot."
        }
    }
    if (Test-Path -LiteralPath $ExtractRoot) { Remove-Item $ExtractRoot -Recurse -Force }
    New-Item -ItemType Directory -Force -Path $ExtractRoot | Out-Null
    Push-Location (Split-Path $Simdec -Parent)
    try {
        & $Simdec $Setup $ExtractRoot
        if ($LASTEXITCODE -ne 0) { throw "simdec failed to extract Contra009Setup.exe." }
    } finally {
        Pop-Location
    }
}

if (Test-Path -LiteralPath $BuildDir) { Remove-Item $BuildDir -Recurse -Force }
if (Test-Path -LiteralPath $StageDir) { Remove-Item $StageDir -Recurse -Force }
New-Item -ItemType Directory -Force -Path $BuildDir, $StageDir, $OutputDir | Out-Null

$HfDirs = @{}
foreach ($Pair in @(
    @{ Key = "hf1"; Path = $Hotfix1 },
    @{ Key = "hf2"; Path = $Hotfix2 },
    @{ Key = "hf3"; Path = $Hotfix3 },
    @{ Key = "hf4"; Path = $Hotfix4 }
)) {
    $Dest = Join-Path $BuildDir $Pair.Key
    New-Item -ItemType Directory -Force -Path $Dest | Out-Null
    & $SevenZip x -y "-o$Dest" $Pair.Path | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "Failed to extract $($Pair.Path)." }
    $HfDirs[$Pair.Key] = $Dest
}

function Copy-CtrAsBig([string] $Source, [string] $TargetName) {
    if (-not (Test-Path -LiteralPath $Source)) { throw "Required Contra 009 archive is missing: $Source" }
    $Stream = [System.IO.File]::OpenRead($Source)
    try {
        $Header = New-Object byte[] 4
        if ($Stream.Read($Header, 0, 4) -ne 4) { throw "Short Contra 009 archive: $Source" }
        $Magic = [System.Text.Encoding]::ASCII.GetString($Header)
    } finally {
        $Stream.Dispose()
    }
    if ($Magic -ne "BIGF") { throw "Contra 009 archive is not BIGF: $Source" }
    Copy-Item -LiteralPath $Source -Destination (Join-Path $StageDir $TargetName)
}

# Explicit numeric priority avoids relying on Windows directory enumeration.
# The portable archive loader processes names ascending; later archives override earlier ones.
$Install = $InstallDir
Copy-CtrAsBig (Join-Path $Install "!Contra009Final.ctr")                    "10-Contra009-Base.big"
Copy-CtrAsBig (Join-Path $Install "!Contra009Final_EN.ctr")                 "11-Contra009-Base-EN.big"
Copy-CtrAsBig (Join-Path $Install "!Contra009Final_EngVO.ctr")              "12-Contra009-Base-EngVO.big"
Copy-CtrAsBig (Join-Path $Install "!Contra009Final_NewMusic.ctr")           "13-Contra009-NewMusic.big"

Copy-CtrAsBig (Join-Path $Install "!!Contra009Final_Patch1.ctr")            "20-Contra009-Patch1.big"
Copy-CtrAsBig (Join-Path $Install "!!Contra009Final_Patch1_EN.ctr")         "21-Contra009-Patch1-EN.big"
Copy-CtrAsBig (Join-Path $Install "!!Contra009Final_Patch1_EngVO.ctr")      "22-Contra009-Patch1-EngVO.big"

Copy-CtrAsBig (Join-Path $Install "!!!Contra009Final_Patch2.ctr")           "30-Contra009-Patch2.big"
Copy-CtrAsBig (Join-Path $Install "!!!Contra009Final_Patch2_GameData.ctr")  "31-Contra009-Patch2-GameData.big"
Copy-CtrAsBig (Join-Path $Install "!!!Contra009Final_Patch2_EN.ctr")        "32-Contra009-Patch2-EN.big"
Copy-CtrAsBig (Join-Path $Install "!!!Contra009Final_Patch2_EngVO.ctr")     "33-Contra009-Patch2-EngVO.big"

Copy-CtrAsBig (Join-Path $Install "!!!!Contra009Final_Patch3.ctr")          "40-Contra009-Patch3.big"
Copy-CtrAsBig (Join-Path $Install "!!!!Contra009Final_Patch3_GameData.ctr") "41-Contra009-Patch3-GameData.big"
Copy-CtrAsBig (Join-Path $Install "!!!!Contra009Final_Patch3_EngVO.ctr")    "42-Contra009-Patch3-EngVO.big"

Copy-CtrAsBig (Join-Path $HfDirs["hf1"] "!!!!!Contra009Final_Patch3_Hotfix.ctr")      "50-Contra009-P3-Hotfix1.big"
Copy-CtrAsBig (Join-Path $HfDirs["hf2"] "!!!!!!Contra009Final_Patch3_Hotfix2.ctr")    "60-Contra009-P3-Hotfix2.big"
Copy-CtrAsBig (Join-Path $HfDirs["hf3"] "!!!!!!!Contra009Final_Patch3_Hotfix3.ctr")   "70-Contra009-P3-Hotfix3.big"
Copy-CtrAsBig (Join-Path $HfDirs["hf3"] "!!!!!!!Contra009Final_Patch3_Hotfix3_AI.ctr") "71-Contra009-P3-Hotfix3-AI.big"
Copy-CtrAsBig (Join-Path $HfDirs["hf4"] "!!!!!!!!Contra009Final_Patch3_Hotfix4.ctr")  "80-Contra009-P3-Hotfix4.big"

# Hotfixes replace the Patch 3 localization in-place. Use the newest English Legacy file.
Copy-CtrAsBig (Join-Path $HfDirs["hf4"] "!!!!Contra009Final_Patch3_EN_Legacy.ctr")     "90-Contra009-Patch3-EN-Legacy.big"

$Staged = @(Get-ChildItem $StageDir -File)
if ($Staged.Count -ne 20) {
    throw "Contra 009 staging must contain exactly 20 active BIG archives, got $($Staged.Count)."
}

$BuilderArgs = @(
    "--variant", "generic",
    "--generic-source", $StageDir,
    "--profile-id", "contra-009",
    "--name", "Contra 009",
    "--runtime-adapter", "generic",
    "--channel", $Channel,
    "--version", $Version,
    "--min-hub-version", $MinHubVersion,
    "--output", $Output
)
& $Python $Builder @BuilderArgs
if ($LASTEXITCODE -ne 0) { throw "Contra 009 .gxmod build failed." }

& $Python $Verifier $Output
if ($LASTEXITCODE -ne 0) { throw "Contra 009 .gxmod verification failed." }

Write-Host ""
Write-Host "READY: $Output" -ForegroundColor Green
Write-Host "Profile: Contra 009 Final + Patch 1-3 + Hotfix 1-4"
Write-Host "Language: English Legacy"
Write-Host "Voices: English"
Write-Host "Music: Contra new music"
Get-ChildItem $StageDir -File | Sort-Object Name | ForEach-Object { Write-Host "  $($_.Name)" }
