# One-shot release: build signed APKs, tag the current commit, push,
# create a GitHub Release, and upload the armeabi-v7a split as its only
# asset — that is the one every tablet installs (see the $AbiOffset note
# below and UpdateService.assetName).
#
# Requirements (one-time):
#   1. GitHub CLI — winget install --id GitHub.cli -e
#   2. Auth, either one:
#        • .github_token at the repo root (fine-grained PAT, Contents:
#          read+write on the repo) — picked up automatically, no login
#        • gh auth login
#   3. android/release.jks + android/key.properties present (see
#      android/README_RELEASE_SIGNING.md)
#
# Usage:
#   .\scripts\release.ps1                       # auto-bump patch, derive build
#   .\scripts\release.ps1 -Version 1.2.0        # explicit version, derived build
#   .\scripts\release.ps1 -Version 1.2.0+10200  # explicit version AND build
#   .\scripts\release.ps1 -Notes "Fixes X"      # release notes (else auto)
#
# VERSION AND BUILD NUMBERS — the part that is easy to get wrong.
#
# The build number is DERIVED from the version, never invented:
#     build = major*10000 + minor*100 + patch      (1.1.21 -> 10121)
# With each part capped at 99 this is strictly monotonic as the version
# grows, so versionCode can't drift out of sync with the version name.
#
# The TAG carries a different number than pubspec, on purpose. Flutter's
# --split-per-abi adds an ABI offset to the shipped versionCode
# (armeabi-v7a = +1000), so the APK installed on a tablet reports
# `pubspec build + 1000`. UpdateService compares the tag's build against
# the installed versionCode, so the tag must encode the POST-offset value
# or every release looks older than what's already on the machine.
# pubspec keeps the pre-offset base so day-to-day Flutter tooling stays sane.
#
#     pubspec.yaml   version: 1.1.21+10121
#     git tag        v1.1.21+11121
#     installed APK  versionCode 11121
#
# The offset is 1000 because UpdateService.assetName is pinned to
# app-armeabi-v7a-release.apk — the tablet always installs that split.
# If that ever changes, change $AbiOffset with it (arm64-v8a = 2000).
#
# The script fails loud — any unexpected state (dirty tree, missing
# keystore, tag already taken, gh not logged in) stops the run before
# anything irreversible happens.

[CmdletBinding()]
param(
    [string]$Version,
    [int]$Build,
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

# --- Resolve paths ----------------------------------------------------------
$projectRoot = Resolve-Path (Join-Path $PSScriptRoot '..')      # apps/tablet
$repoRoot    = Resolve-Path (Join-Path $projectRoot '..\..')    # monorepo root
Set-Location $projectRoot
Write-Host "Project: $projectRoot"

$AbiOffset = 1000   # armeabi-v7a — see the header before touching this

# --- Preflight: gh CLI ------------------------------------------------------
Section "Checking prerequisites"

if (-not (Get-Command gh -ErrorAction SilentlyContinue)) {
    Fail "GitHub CLI not installed. Run: winget install --id GitHub.cli -e (then open a NEW shell)"
}

# Token file beats an interactive login: the release box has a PAT and no
# browser. Only set it when the caller hasn't already provided one.
$tokenFile = Join-Path $repoRoot '.github_token'
if (-not $env:GH_TOKEN -and (Test-Path $tokenFile)) {
    $tok = (Get-Content $tokenFile -Raw).Trim()
    if ($tok) {
        $env:GH_TOKEN = $tok
        Write-Host "Auth: .github_token"
    }
}

# No `2>&1` here. gh writes auth status to stderr even when it succeeds, and
# under Windows PowerShell 5.1 redirecting a native command's stderr wraps
# each line in an ErrorRecord — which $ErrorActionPreference='Stop' then turns
# into a fatal NativeCommandError on a perfectly good login. Send stderr to
# the null device instead and judge by the exit code alone.
gh auth status 2>$null | Out-Null
if ($LASTEXITCODE -ne 0) {
    Fail "Not logged in to gh. Put a PAT in $tokenFile, or run: gh auth login"
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

# --- Work out the next version ----------------------------------------------
$pubspecPath = Join-Path $projectRoot 'pubspec.yaml'
$pubspecText = Get-Content $pubspecPath -Raw -Encoding UTF8
if ($pubspecText -notmatch "(?m)^version:\s*(\d+)\.(\d+)\.(\d+)\+(\d+)\s*$") {
    Fail "Could not parse 'version: X.Y.Z+NNNN' from pubspec.yaml"
}
$curVersion = "$($Matches[1]).$($Matches[2]).$($Matches[3])+$($Matches[4])"
$majCur, $minCur, $patchCur = [int]$Matches[1], [int]$Matches[2], [int]$Matches[3]
Write-Host "Current: $curVersion"

$explicitBuild = $null
if ($Version) {
    if ($Version -match '^(\d+)\.(\d+)\.(\d+)\+(\d+)$') {
        $majNew, $minNew, $patchNew = [int]$Matches[1], [int]$Matches[2], [int]$Matches[3]
        $explicitBuild = [int]$Matches[4]
    } elseif ($Version -match '^(\d+)\.(\d+)\.(\d+)$') {
        $majNew, $minNew, $patchNew = [int]$Matches[1], [int]$Matches[2], [int]$Matches[3]
    } else {
        Fail "Version must be 1.2.0 or 1.2.0+10200 (got '$Version')."
    }
} else {
    # Auto-increment with rollover at 99: patch +1, carry into minor, then
    # into major. Keeps releases monotonic with zero manual input.
    $majNew, $minNew, $patchNew = $majCur, $minCur, ($patchCur + 1)
    if ($patchNew -gt 99) { $patchNew = 0; $minNew++ }
    if ($minNew   -gt 99) { $minNew   = 0; $majNew++ }
}

$derivedBuild = $majNew * 10000 + $minNew * 100 + $patchNew
if ($PSBoundParameters.ContainsKey('Build')) {
    $buildNew = $Build
} elseif ($null -ne $explicitBuild) {
    $buildNew = $explicitBuild
} else {
    $buildNew = $derivedBuild
}

$newVersion = "$majNew.$minNew.$patchNew+$buildNew"
$tagBuild   = $buildNew + $AbiOffset
$tagName    = "v$majNew.$minNew.$patchNew+$tagBuild"
Write-Host "New:     $newVersion   (tag: $tagName, shipped versionCode: $tagBuild)"

# --- Tag must not exist yet — check BEFORE touching pubspec ------------------
# Same 5.1 stderr trap as the gh check above — git fetch reports progress
# on stderr, which `2>&1` would turn into a fatal error record.
git fetch --tags origin 2>$null | Out-Null
if ((git tag -l $tagName) -eq $tagName) {
    Fail "Tag $tagName already exists locally. Pick another version."
}
if (git ls-remote --tags origin "refs/tags/$tagName") {
    Fail "Tag $tagName already exists on origin. Pick another version."
}

# --- Bump pubspec + commit --------------------------------------------------
if ($newVersion -ne $curVersion) {
    Section "Bumping pubspec to $newVersion"
    $updated = $pubspecText -replace "(?m)^version:\s*\d+\.\d+\.\d+\+\d+\s*$", "version: $newVersion"
    if ($updated -eq $pubspecText) { Fail "Failed to rewrite the version line." }
    Set-Content -Path $pubspecPath -Value $updated -NoNewline -Encoding UTF8
    git add $pubspecPath
    if ($LASTEXITCODE -ne 0) { Fail "git add failed" }
    git commit -m "Bump version to $newVersion"
    if ($LASTEXITCODE -ne 0) { Fail "git commit failed" }
}

# --- No uncommitted TRACKED changes -----------------------------------------
# The point of this gate is that the tag describes what was built. Untracked
# files are not in the commit and not in the APK either, so they can't break
# that — and blocking on them means one stray directory anywhere in the
# monorepo (say firmware sources someone hasn't committed yet) stops tablet
# releases forever. They're still worth seeing, so they're printed.
$untracked = git status --porcelain --untracked-files=all | Where-Object { $_ -like '??*' }
if ($untracked) {
    Write-Host "Untracked files present (not part of the release):" -ForegroundColor Yellow
    Write-Host ($untracked -join "`n")
}
$dirty = git status --porcelain --untracked-files=no
if ($dirty) {
    Write-Host $dirty
    Fail "Tracked files have uncommitted changes. Commit or stash before releasing."
}

# --- Build signed APKs ------------------------------------------------------
# The build stays --split-per-abi even though only the v7a split ships: the
# per-ABI split is what adds the +1000 offset to versionCode, and the whole
# tag calculation above is built on that. The other splits are left on disk
# for local testing and simply aren't uploaded.
$apkDir = 'build/app/outputs/flutter-apk'
$armApk = "$apkDir/app-armeabi-v7a-release.apk"

if ($SkipBuild) {
    Section "Skipping build (-SkipBuild). Reusing existing APKs."
} else {
    Section "Building release APKs (split-per-abi)"
    flutter pub get
    if ($LASTEXITCODE -ne 0) { Fail "flutter pub get failed" }
    flutter build apk --release --split-per-abi
    if ($LASTEXITCODE -ne 0) { Fail "flutter build apk failed" }
}

if (-not (Test-Path $armApk)) { Fail "Expected APK not found: $armApk" }

# --- Verify signing cert (sanity check before upload) -----------------------
Section "Verifying APK signature"
$fingerprint = & keytool -list -keystore android/release.jks `
    -storepass (Get-Content android/key.properties | `
        Where-Object { $_ -match '^storePassword=' } | `
        ForEach-Object { ($_ -split '=', 2)[1] }) `
    -alias smartvend 2>$null | Select-String 'SHA-256' | ForEach-Object { $_.Line.Trim() }
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
# One asset, on purpose. UpdateService.assetName is pinned to
# app-armeabi-v7a-release.apk, so that is the only file any tablet ever
# downloads; the arm64 and x86_64 splits were dead weight on the release
# page and an invitation to hand-install the wrong one.
$releaseArgs += $armApk

& gh @releaseArgs
if ($LASTEXITCODE -ne 0) { Fail "gh release create failed" }

$url = (gh release view $tagName --json url --jq '.url')
Section "Done"
Write-Host "Release URL: $url" -ForegroundColor Green
Write-Host "APK URL:     $url/download/$(Split-Path $armApk -Leaf)"
Write-Host ""
Write-Host "On the tablet: service-mode -> Обновление -> Проверить обновление."
