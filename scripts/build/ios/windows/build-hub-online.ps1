param(
    [string] $Version = "1.4.14"
)

$ErrorActionPreference = "Stop"
$Workspace = (Resolve-Path (Join-Path $PSScriptRoot "..\..\..\..\..")).Path
$RepoRoot = (& git -C $PSScriptRoot rev-parse --show-toplevel 2>$null | Select-Object -First 1).Trim()
if ((Split-Path -Leaf (Split-Path -Parent $RepoRoot)) -eq "worktrees") {
    $Workspace = Split-Path -Parent (Split-Path -Parent $RepoRoot)
}
$RepoName = "dvorovrus/Generals-Mac-iOS-iPad"
$Branch = "feature/generals-hub-online"
$Workflow = "build-ios-shell.yml"
$ArtifactName = "GeneralsXZH-launcher-unsigned"
$ArtifactFile = "GeneralsXZH-launcher-unsigned.ipa"
$Output = Join-Path $Workspace "output\GeneralsZH-Hub-Online-unsigned.ipa"
$Builder = Join-Path $RepoRoot "scripts\build\ios\build-variant-ipa.py"
$Verifier = Join-Path $RepoRoot "scripts\build\ios\verify-variant-ipa.py"
$Python = if (Get-Command py -ErrorAction SilentlyContinue) { "py" } else { "python" }

foreach ($required in @($Builder,$Verifier)) {
    if (-not (Test-Path -LiteralPath $required)) { throw "Required input not found: $required" }
}
if (-not (Get-Command gh -ErrorAction SilentlyContinue)) { throw "GitHub CLI (gh) is required." }
& gh auth status *> $null
if ($LASTEXITCODE -ne 0) { throw "GitHub CLI is not authenticated." }

$runsJson = & gh run list --repo $RepoName --workflow $Workflow --branch $Branch --status success --limit 1 --json databaseId
$runs = @($runsJson | ConvertFrom-Json)
if ($runs.Count -eq 0) { throw "No successful Online-capable Hub shared shell found on $Branch." }
$RunId = [long]$runs[0].databaseId
$run = (& gh run view $RunId --repo $RepoName --json status,conclusion,url,headSha,headBranch | ConvertFrom-Json)
if ($run.conclusion -ne "success" -or $run.headBranch -ne $Branch) { throw "Run $RunId is not a successful Online-capable Hub shared shell." }

$ArtifactDir = Join-Path $Workspace "artifacts\ipad\hub-online\$RunId"
$Shell = Join-Path $ArtifactDir $ArtifactFile
New-Item -ItemType Directory -Force -Path $ArtifactDir | Out-Null
if (-not (Test-Path -LiteralPath $Shell)) {
    Write-Host "Downloading Online-capable Hub shared shell..." -ForegroundColor Cyan
    & gh run download $RunId --repo $RepoName --name $ArtifactName --dir $ArtifactDir
    if ($LASTEXITCODE -ne 0) { throw "Artifact download failed." }
}

Write-Host "Packaging lightweight Generals Hub (engine + launcher only)..." -ForegroundColor Cyan
& $Python $Builder --variant hub --shell $Shell --app-version $Version --build-number $RunId --output $Output
if ($LASTEXITCODE -ne 0) { throw "Hub Online IPA packaging failed." }

Write-Host "Verifying Hub Online IPA..." -ForegroundColor Cyan
& $Python $Verifier --variant hub $Output
if ($LASTEXITCODE -ne 0) { throw "Hub Online IPA verification failed." }

$sizeMb = [math]::Round((Get-Item -LiteralPath $Output).Length / 1MB, 1)
$nl = [Environment]::NewLine
$SourceInfo = "Run: $RunId" + $nl + "Commit: $($run.headSha)" + $nl + "URL: $($run.url)" + $nl + "Shell: $Shell" + $nl + "Version: $Version" + $nl + "Build: $RunId" + $nl + "Base content: external online.gxmod" + $nl + "Mode: Generals Hub" + $nl
[System.IO.File]::WriteAllText("$Output.source.txt", $SourceInfo)

Write-Host ""
Write-Host "READY: $Output ($sizeMb MB)" -ForegroundColor Green
Write-Host "Install this IPA once with Sideloadly; download Zero Hour + Online, Enhanced and Contra X from the Hub."

