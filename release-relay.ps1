# Release pipeline for the esp-relay firmware (ESP32 OTA).
#
# Mirrors release.ps1 (the tablet APK pipeline) but for the ESP-IDF firmware.
# Firmware releases share the tablet's repo and are namespaced by a "relay-v"
# tag prefix + a "relay-mart.bin" asset, so the two release streams never
# collide. The device's OTA checker (ota_find_update in main.c) only looks at
# "relay-v*" tags; the tablet's UpdateService ignores them.
#
# What it does:
#   1. Reads the GitHub token from .github_token at the repo root.
#   2. Bumps FW_VERSION_NAME / FW_VERSION_CODE in main.c (patch +1, or -Version).
#   3. Builds the firmware with idf.py (run this from an ESP-IDF PowerShell).
#   4. git-commits the bump, tags `relay-vX.Y.Z+CODE`, pushes.
#   5. Creates a GitHub Release for that tag and uploads the .bin as
#      `relay-mart.bin` - the asset name the device's OTA searches for.
#
# Usage (from an ESP-IDF PowerShell, so idf.py is on PATH):
#   .\release-relay.ps1 "Add periodic OTA check"
#   .\release-relay.ps1 -Message "..." -Version 1.2.0
#   .\release-relay.ps1 -Message "..." -DryRun
#   .\release-relay.ps1 -Message "..." -NoPush

[CmdletBinding()]
param(
    [Parameter(Mandatory=$true, Position=0)]
    [string]$Message,
    [string]$Version,          # override semver "X.Y.Z" (no +code)
    [switch]$Prerelease,
    [switch]$NoPush,
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'

$RepoRoot  = $PSScriptRoot
$Owner     = 'Samat1989'
$Repo      = 'smartvend-tablet'
$FwPath    = Join-Path $RepoRoot 'firmware/esp-relay'
$MainC     = Join-Path $FwPath 'main/main.c'
$AssetName = 'relay-mart.bin'                                   # OTA_ASSET_NAME in main.c
$BinPath   = Join-Path $FwPath 'build/esp_relay_mart.bin'       # project(esp_relay_mart)
$TokenFile = Join-Path $RepoRoot '.github_token'

function Step($m) { Write-Host "==> $m" -ForegroundColor Cyan }
function Info($m) { Write-Host "    $m" -ForegroundColor Gray }
function Done($m) { Write-Host "[OK] $m" -ForegroundColor Green }

# ---------- idf.py (auto-load ESP-IDF env via get_idf) ----------
$idf = Get-Command idf.py -ErrorAction SilentlyContinue
if (-not $idf -and -not $DryRun) {
    # get_idf is the user's profile helper that dot-sources export.ps1 and puts
    # idf.py + the toolchain on PATH. Call it so this works from a plain shell.
    if (Get-Command get_idf -ErrorAction SilentlyContinue) {
        Step 'Loading ESP-IDF environment (get_idf)'
        get_idf
        $idf = Get-Command idf.py -ErrorAction SilentlyContinue
    }
}
if (-not $idf -and -not $DryRun) {
    throw "idf.py not available. Define get_idf in your PowerShell profile (or run ESP-IDF export.ps1), then retry."
}

# ---------- 1. Token ----------
Step 'Reading GitHub token'
if (-not (Test-Path $TokenFile)) {
    throw "Token file not found: $TokenFile (fine-grained PAT, Contents: read+write on $Owner/$Repo)."
}
$token = (Get-Content $TokenFile -Raw).Trim()
if (-not $token) { throw "Token file $TokenFile is empty." }

# ---------- 2. Compute new version ----------
Step 'Reading current version from main.c'
$mainText = Get-Content $MainC -Raw -Encoding UTF8
if ($mainText -notmatch '#define\s+FW_VERSION_NAME\s+"(\d+)\.(\d+)\.(\d+)"') {
    throw 'Cannot find #define FW_VERSION_NAME "X.Y.Z" in main.c'
}
$majCur, $minCur, $patchCur = [int]$Matches[1], [int]$Matches[2], [int]$Matches[3]
Info "Current: $majCur.$minCur.$patchCur"

if ($Version) {
    if ($Version -notmatch '^(\d+)\.(\d+)\.(\d+)$') { throw "Bad -Version '$Version'. Expected X.Y.Z." }
    $majNew, $minNew, $patchNew = [int]$Matches[1], [int]$Matches[2], [int]$Matches[3]
} else {
    $majNew, $minNew, $patchNew = $majCur, $minCur, ($patchCur + 1)
}
$codeNew    = $majNew * 10000 + $minNew * 100 + $patchNew     # matches ota_tag_code()
$newName    = "$majNew.$minNew.$patchNew"
$tag        = "relay-v$newName+$codeNew"
Info "New:     $newName   (tag: $tag, code: $codeNew)"

$remoteHas = & git -C $RepoRoot ls-remote --tags origin "refs/tags/$tag" 2>$null
if ($remoteHas) { throw "Tag $tag already exists on origin. Bump further." }
if (& git -C $RepoRoot tag -l $tag) { throw "Tag $tag already exists locally." }

# ---------- 3. Bump main.c ----------
Step "Bumping main.c to $newName (code $codeNew)"
if ($DryRun) {
    Info "[DRY] would set FW_VERSION_NAME=`"$newName`", FW_VERSION_CODE=$codeNew"
} else {
    $t = $mainText -replace '(#define\s+FW_VERSION_NAME\s+)"(\d+)\.(\d+)\.(\d+)"', "`${1}`"$newName`""
    $t = $t       -replace '(#define\s+FW_VERSION_CODE\s+)\d+',                   "`${1}$codeNew"
    Set-Content -Path $MainC -Value $t -NoNewline -Encoding utf8
    Done 'main.c version bumped'
}

$bumpedAndUncommitted = -not $DryRun
try {
    # ---------- 4. Build ----------
    Step 'Building firmware (idf.py build)'
    if ($DryRun) {
        Info '[DRY] would run: idf.py build'
    } else {
        Push-Location $FwPath
        try {
            idf.py build | Out-Host
            if ($LASTEXITCODE -ne 0) { throw 'idf.py build failed' }
        } finally { Pop-Location }
        if (-not (Test-Path $BinPath)) { throw "Expected firmware not found: $BinPath" }
        $sz = (Get-Item $BinPath).Length / 1KB
        Done ("Firmware ready ({0:F0} KB)" -f $sz)
    }

    # ---------- 5. Commit ----------
    Step 'Committing version bump'
    if ($DryRun) {
        Info "[DRY] would: git commit -am `"$Message`""
    } else {
        & git -C $RepoRoot add $MainC
        & git -C $RepoRoot commit -m $Message
        if ($LASTEXITCODE -ne 0) { throw 'git commit failed' }
        $bumpedAndUncommitted = $false
        Done "Committed: $Message"
    }

    # ---------- 6. Tag ----------
    Step "Creating tag $tag"
    if (-not $DryRun) {
        & git -C $RepoRoot tag -a $tag -m $Message
        if ($LASTEXITCODE -ne 0) { throw 'git tag failed' }
        Done "Tag $tag created"
    }

    if ($NoPush) { Info 'Skipping push (-NoPush). Done locally.'; return }
    if ($DryRun) { Info '[DRY] would push branch + tag, create release, upload bin'; return }

    # ---------- 7. Push ----------
    $branch = (& git -C $RepoRoot rev-parse --abbrev-ref HEAD).Trim()
    Step "Pushing branch $branch + tag $tag"
    & git -C $RepoRoot push origin $branch; if ($LASTEXITCODE -ne 0) { throw "git push $branch failed" }
    & git -C $RepoRoot push origin $tag;    if ($LASTEXITCODE -ne 0) { throw "git push $tag failed" }
    Done 'Pushed branch + tag'

    # ---------- 8. GitHub Release + asset ----------
    Step "Creating GitHub Release $tag and uploading $AssetName"
    $headers = @{
        'Accept'               = 'application/vnd.github+json'
        'Authorization'        = "Bearer $token"
        'X-GitHub-Api-Version' = '2022-11-28'
    }
    $body = @{
        tag_name = $tag; name = $tag; body = $Message
        draft = $false; prerelease = [bool]$Prerelease
    } | ConvertTo-Json -Compress
    try {
        $release = Invoke-RestMethod -Method POST `
            -Uri "https://api.github.com/repos/$Owner/$Repo/releases" `
            -Headers $headers -Body $body -ContentType 'application/json'
    } catch {
        throw "Release create failed: $($_.Exception.Message). Tag is pushed; create the release manually."
    }
    Done "Release created: $($release.html_url)"

    $uploadUrl = ($release.upload_url -replace '\{\?.*\}$', '') + "?name=$AssetName"
    $binBytes  = [System.IO.File]::ReadAllBytes($BinPath)
    $upHeaders = @{
        'Accept'        = 'application/vnd.github+json'
        'Authorization' = "Bearer $token"
        'Content-Type'  = 'application/octet-stream'
    }
    try {
        $uploaded = Invoke-RestMethod -Method POST -Uri $uploadUrl -Headers $upHeaders -Body $binBytes
    } catch {
        throw "Asset upload failed: $($_.Exception.Message). Release exists but has no .bin - upload manually."
    }
    Done "Uploaded: $($uploaded.browser_download_url)"

    Write-Host ""
    Done "FIRMWARE RELEASE $tag PUBLISHED"
}
catch {
    Write-Host ""
    Write-Host "[FAIL] $($_.Exception.Message)" -ForegroundColor Red
    if ($bumpedAndUncommitted) {
        Write-Host 'Rolling back main.c bump...' -ForegroundColor Yellow
        & git -C $RepoRoot checkout HEAD -- $MainC 2>$null
    }
    exit 1
}
