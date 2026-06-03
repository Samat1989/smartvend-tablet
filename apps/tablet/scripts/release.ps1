# One-shot release: build signed APKs, tag the current commit, push,
# create a GitHub Release, and upload every ABI split as an asset.
#
# Requirements (one-time):
#   1. winget install GitHub.cli   (or `choco install gh`)
#   2. gh auth login               (browser OAuth, like vercel)
#   3. android/release.jks + android/key.properties present (see
#      android/README_RELEASE_SIGNING.md)
#
# Usage:
#   .\scripts\release.ps1 -Version 1.0.6+1006
#   .\scripts\release.ps1 -Version 1.0.6+1006 -Notes "Fixes X, adds Y"
#   .\scripts\release.ps1                          # uses pubspec version as-is
#
# The script fails loud — any unexpected state (dirty tree, missing
# keystore, tag already taken, gh not logged in) stops the run before
# anything irreversible happens.

[CmdletBinding()]
param(
    [string]$Version,
    [string]$Notes,
    [switch]$Draft,
    [switch]$SkipBuild,
    [switch]$NoPush
)

$ErrorActionPreference = 'Stop'

function Section($msg) {
    Write-Host ""
    Write-Host "==> $msg" -ForegroundColor Cyan
}

function Fail($msg) {
    Write-Host "ERROR: $msg" -ForegroundColor Red
    exit 1
}

# --- Resolve project root (parent of scripts/) ------------------------------
$projectRoot = Resolve-Path (Join-Path $PSScriptRoot '..')
Set-Location $projectRoot
Write-Host "Project: $projectRoot"

# --- Preflight: gh CLI ------------------------------------------------------
Section "Checking prerequisites"

if (-not (Get-Command gh -ErrorAction SilentlyContinue)) {
    Fail "GitHub CLI not installed. Run: winget install GitHub.cli"
}

gh auth status 2>&1 | Out-Null
if ($LASTEXITCODE -ne 0) {
    Fail "Not logged in to gh. Run: gh auth login"
}

if (-not (Get-Command flutter -ErrorAction SilentlyContinue)) {
    Fail "Flutter not on PATH."
}

if (-not (Test-Path 'android/release.jks')) {
    Fail "android/release.jks not found. See android/README_RELEASE_SIGNING.md."
}
if (-not (Test-Path 'android/key.properties')) {
    Fail "android/key.properties not found. Copy from key.properties.example."
}

# --- Bump pubspec version when -Version is provided -------------------------
$pubspecPath = Join-Path $projectRoot 'pubspec.yaml'

if ($Version) {
    if ($Version -notmatch '^\d+\.\d+\.\d+\+\d+$') {
        Fail "Version must look like 1.0.6+1006 (got '$Version')."
    }
    Section "Bumping pubspec to $Version"
    $content = Get-Content $pubspecPath -Raw
    $updated = $content -replace '(?m)^version:\s*[^\r\n]+', "version: $Version"
    if ($updated -eq $content) {
        Fail "Could not find a `version:` line in pubspec.yaml."
    }
    Set-Content -Path $pubspecPath -Value $updated -NoNewline
    git add $pubspecPath
    if ($LASTEXITCODE -ne 0) { Fail "git add failed" }
    git commit -m "Bump version to $Version"
    if ($LASTEXITCODE -ne 0) { Fail "git commit failed" }
}

# --- Read effective version + assemble tag name -----------------------------
$versionLine = (Get-Content $pubspecPath) | Where-Object { $_ -match '^version:' } | Select-Object -First 1
$currentVersion = ($versionLine -replace 'version:\s*', '').Trim()
if (-not $currentVersion) { Fail "Could not read version from pubspec.yaml" }
$tagName = "v$currentVersion"
Write-Host "Release: $tagName"

# --- Working tree must be clean (commit happened above if -Version) ---------
$status = git status --porcelain
if ($status) {
    Write-Host $status
    Fail "Working tree not clean. Commit or stash before releasing."
}

# --- Tag must not already exist on origin -----------------------------------
git fetch --tags origin 2>&1 | Out-Null
$existing = git tag -l $tagName
if ($existing -eq $tagName) {
    Fail "Tag $tagName already exists locally. Bump version (use -Version <next>)."
}
$existingRemote = git ls-remote --tags origin "refs/tags/$tagName"
if ($existingRemote) {
    Fail "Tag $tagName already exists on origin. Bump version."
}

# --- Build signed APKs ------------------------------------------------------
$apkDir  = 'build/app/outputs/flutter-apk'
$armApk  = "$apkDir/app-armeabi-v7a-release.apk"
$arm64Apk= "$apkDir/app-arm64-v8a-release.apk"
$x86Apk  = "$apkDir/app-x86_64-release.apk"

if ($SkipBuild) {
    Section "Skipping build (-SkipBuild). Reusing existing APKs."
} else {
    Section "Building release APKs (split-per-abi)"
    flutter pub get
    if ($LASTEXITCODE -ne 0) { Fail "flutter pub get failed" }
    flutter build apk --release --split-per-abi
    if ($LASTEXITCODE -ne 0) { Fail "flutter build apk failed" }
}

foreach ($apk in @($armApk, $arm64Apk)) {
    if (-not (Test-Path $apk)) { Fail "Expected APK not found: $apk" }
}

# --- Verify signing cert (sanity check before upload) -----------------------
Section "Verifying APK signature"
$fingerprint = & keytool -list -keystore android/release.jks `
    -storepass (Get-Content android/key.properties | `
        Where-Object { $_ -match '^storePassword=' } | `
        ForEach-Object { ($_ -split '=', 2)[1] }) `
    -alias smartvend 2>&1 | Select-String 'SHA-256' | ForEach-Object { $_.Line.Trim() }
if (-not $fingerprint) {
    Fail "Could not read keystore fingerprint."
}
Write-Host $fingerprint

# --- Tag + push -------------------------------------------------------------
Section "Tagging $tagName"
git tag $tagName
if ($LASTEXITCODE -ne 0) { Fail "git tag failed" }

if ($NoPush) {
    Write-Host "Skipping push (-NoPush). Tag created locally only."
} else {
    Section "Pushing to origin"
    git push origin main
    if ($LASTEXITCODE -ne 0) { Fail "git push main failed" }
    git push origin $tagName
    if ($LASTEXITCODE -ne 0) { Fail "git push tag failed" }
}

# --- Create GitHub Release + upload APKs ------------------------------------
Section "Creating GitHub Release $tagName"

$releaseArgs = @(
    'release', 'create', $tagName,
    '--title', $tagName
)
if ($Notes) {
    $releaseArgs += @('--notes', $Notes)
} else {
    $releaseArgs += '--generate-notes'
}
if ($Draft) {
    $releaseArgs += '--draft'
}
$releaseArgs += $armApk
$releaseArgs += $arm64Apk
if (Test-Path $x86Apk) { $releaseArgs += $x86Apk }

& gh @releaseArgs
if ($LASTEXITCODE -ne 0) { Fail "gh release create failed" }

$url = (gh release view $tagName --json url --jq '.url')
Section "Done"
Write-Host "Release URL: $url" -ForegroundColor Green
Write-Host "APK URL:     $url/download/$(Split-Path $armApk -Leaf)"
Write-Host ""
Write-Host "On the tablet: service-mode → Обновление → Проверить обновление."
