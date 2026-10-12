param(
    [ValidateSet('stable','beta')]
    [string] $Channel = 'stable',
    [string] $Version = '0.2.0-web.1',
    [int] $BridgeSchema = 2,
    [switch] $Both,
    [switch] $CommitAndPush
)

$ErrorActionPreference = 'Stop'
$Repo = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..')).Path
$WebRoot = Join-Path $Repo 'launcher_web'
$Catalog = Join-Path $Repo 'ios\hub\HubCatalog.json'
$Updater = Join-Path $Repo 'scripts\publish\update-hub-catalog.py'
$Python = if (Get-Command py -ErrorAction SilentlyContinue) { 'py' } else { 'python' }

foreach ($required in @('CLOUDFLARE_ACCOUNT_ID','R2_BUCKET','R2_PUBLIC_BASE_URL')) {
    if (-not (Get-Item "Env:$required" -ErrorAction SilentlyContinue)) {
        $value = [Environment]::GetEnvironmentVariable($required, 'User')
        if ($value) { Set-Item "Env:$required" $value }
    }
}

if (-not $env:CLOUDFLARE_ACCOUNT_ID -or -not $env:R2_BUCKET -or -not $env:R2_PUBLIC_BASE_URL) {
    throw 'R2 settings are missing. Run configure-r2.ps1 first.'
}

$AwsCommand = Get-Command aws -ErrorAction SilentlyContinue
$AwsPath = if ($AwsCommand) { $AwsCommand.Source } else { $null }
if (-not $AwsPath) {
    $scriptsDir = (& py -c "import sysconfig; print(sysconfig.get_path('scripts', scheme='nt_user'))").Trim()
    $AwsPath = @(
        (Join-Path $scriptsDir 'aws.cmd'),
        (Join-Path $scriptsDir 'aws.exe'),
        (Join-Path $scriptsDir 'aws')
    ) | Where-Object { Test-Path $_ } | Select-Object -First 1
}
if (-not $AwsPath) { throw 'AWS CLI is required. Run configure-r2.ps1 first.' }
if (-not (Test-Path (Join-Path $WebRoot 'index.html'))) { throw "Launcher web root is incomplete: $WebRoot" }

$ProfileArgs = @('--profile','generals-r2')
$Endpoint = "https://$($env:CLOUDFLARE_ACCOUNT_ID).r2.cloudflarestorage.com"
$Channels = if ($Both) { @('stable','beta') } else { @($Channel) }

foreach ($targetChannel in $Channels) {
    $Dest = "s3://$($env:R2_BUCKET)/launcher/$targetChannel"
    Write-Host "Publishing launcher web -> $targetChannel" -ForegroundColor Cyan

    # Images can be cached for a day. Core HTML/CSS/JS are overwritten below with no-cache.
    & $AwsPath @ProfileArgs s3 sync $WebRoot $Dest `
        --endpoint-url $Endpoint --region auto --delete `
        --exclude '*.html' --exclude '*.js' --exclude '*.css' --exclude 'README.md' `
        --cache-control 'public,max-age=86400'
    if ($LASTEXITCODE -ne 0) { throw "R2 asset sync failed for $targetChannel." }

    foreach ($name in @('index.html','app.js','styles.css')) {
        $source = Join-Path $WebRoot $name
        & $AwsPath @ProfileArgs s3 cp $source "$Dest/$name" `
            --endpoint-url $Endpoint --region auto `
            --cache-control 'no-cache, no-store, must-revalidate'
        if ($LASTEXITCODE -ne 0) { throw "R2 upload failed: $name ($targetChannel)." }
    }

    $url = "$($env:R2_PUBLIC_BASE_URL.TrimEnd('/'))/launcher/$targetChannel/index.html"
    $response = Invoke-WebRequest -UseBasicParsing -Uri $url -TimeoutSec 30
    if ($response.StatusCode -ne 200) { throw "Launcher URL returned HTTP $($response.StatusCode): $url" }
    Write-Host "Launcher OK: $url" -ForegroundColor Green

    & $Python $Updater --catalog $Catalog launcher `
        --channel $targetChannel --version $Version --url $url --bridge-schema $BridgeSchema
    if ($LASTEXITCODE -ne 0) { throw "Launcher catalog update failed for $targetChannel." }
}

# Catalog is the bootstrap metadata for the native host.
& $AwsPath @ProfileArgs s3 cp $Catalog "s3://$($env:R2_BUCKET)/catalog.json" `
    --endpoint-url $Endpoint --region auto `
    --cache-control 'no-cache, no-store, must-revalidate' `
    --content-type 'application/json'
if ($LASTEXITCODE -ne 0) { throw 'Catalog upload failed.' }

if ($CommitAndPush) {
    git -C $Repo add -- ios/hub/HubCatalog.json launcher_web scripts/publish/windows/publish-launcher-web-r2.ps1
    if (-not (git -C $Repo diff --cached --quiet)) {
        git -C $Repo commit -m 'release(launcher): publish remote web launcher [skip ci]'
        if ($LASTEXITCODE -ne 0) { throw 'Commit failed.' }
        git -C $Repo push
        if ($LASTEXITCODE -ne 0) { throw 'Push failed.' }
    }
}

Write-Host ''
Write-Host 'LAUNCHER WEB PUBLISHED' -ForegroundColor Green
Write-Host "Catalog: $($env:R2_PUBLIC_BASE_URL.TrimEnd('/'))/catalog.json"
