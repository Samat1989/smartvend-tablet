# Release pipeline for the m102_tester APK.
#
# What it does, in order:
#   1. Reads the GitHub token from .github_token at the repo root.
#   2. Auto-bumps pubspec.yaml: version patch +1 with rollover at 99
#      (1.1.99 -> 1.2.0 -> ... -> 1.99.99 -> 2.0.0). The build number is
#      DERIVED from the version (major*10000 + minor*100 + patch), so it
#      can never drift out of sync. Override the version with -Version 1.2.0;
#      the build is computed automatically (or forced with -Build).
#   3. Runs `flutter analyze`. Aborts release if there are issues.
#   4. Builds armeabi-v7a release APK (the only ABI we ship to the
#      Unisoc SC9832E tablets).
#   5. git-commits modified tracked files + the version bump.
#   6. Creates an annotated tag `vX.Y.Z+N` and pushes it to origin.
#   7. Creates a GitHub Release for that tag and uploads the APK as
#      asset `app-armeabi-v7a-release.apk` — the name the in-app
#      UpdateService searches for.
#
# Usage:
#   .\release.ps1 "Fix dispense hang on cable disconnect"
#   .\release.ps1 -Message "..." -Version 1.2.0          # bump minor
#   .\release.ps1 -Message "..." -Prerelease             # don't surface as "latest"
#   .\release.ps1 -Message "..." -DryRun                 # print actions, don't execute
#   .\release.ps1 -Message "..." -NoPush                 # build+commit+tag locally only
#
# Setup once:
#   1. Generate a fine-grained PAT at https://github.com/settings/tokens
#      with `Contents: read+write` scope for Samat1989/smartvend-tablet.
#   2. Save the token (one line, no quotes) to .github_token in the repo root.
#      The file is .gitignored.

[CmdletBinding()]
param(
    [Parameter(Mandatory=$true, Position=0)]
    [string]$Message,

    # Override semver. Format: "1.2.3" (no +build).
    [string]$Version,

    # Override build number. By default we increment current+1.
    [int]$Build,

    [switch]$Prerelease,
    [switch]$NoPush,
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'

# ---------- paths + repo coords ----------
$RepoRoot  = $PSScriptRoot
$Owner     = 'Samat1989'
$Repo      = 'smartvend-tablet'
$AppPath   = Join-Path $RepoRoot 'apps/tablet'
$Pubspec   = Join-Path $AppPath 'pubspec.yaml'
$AssetName = 'app-armeabi-v7a-release.apk'   # matches UpdateService.assetName
$ApkPath   = Join-Path $AppPath "build\app\outputs\flutter-apk\$AssetName"
$TokenFile = Join-Path $RepoRoot '.github_token'

# Resolve flutter — prefer PATH, fall back to the known install dir.
$flutterCmd = (Get-Command flutter -ErrorAction SilentlyContinue).Source
if (-not $flutterCmd) {
    $fallback = 'C:\src\flutter\bin\flutter.bat'
    if (Test-Path $fallback) { $flutterCmd = $fallback }
}
if (-not $flutterCmd) { throw "flutter not found on PATH and no fallback at C:\src\flutter\bin\flutter.bat" }

function Step($msg)  { Write-Host "==> $msg" -ForegroundColor Cyan }
function Info($msg)  { Write-Host "    $msg" -ForegroundColor Gray }
function Done($msg)  { Write-Host "[OK] $msg" -ForegroundColor Green }

# ---------- 1. Token ----------
Step 'Reading GitHub token'
if (-not (Test-Path $TokenFile)) {
    throw "Token file not found: $TokenFile`nCreate it with a fine-grained PAT (Contents: read+write on $Owner/$Repo)."
}
$token = (Get-Content $TokenFile -Raw).Trim()
if (-not $token) { throw "Token file $TokenFile is empty." }
Info "Token loaded ($($token.Length) chars)"

# ---------- 2. Compute new version ----------
Step 'Reading current version from pubspec.yaml'
# Read as UTF-8 explicitly — Windows PowerShell 5.1's default Get-Content
# uses the system ANSI code page (cp1251 on Russian Windows). That
# silently corrupts any em-dash / Cyrillic in the file when we rewrite
# it: bytes E2 80 94 get decoded as Cyrillic "вЂ\"" and re-encoded back
# to UTF-8 as 6 garbage bytes. -Encoding UTF8 fixes the round-trip.
$pubspecText = Get-Content $Pubspec -Raw -Encoding UTF8
if ($pubspecText -notmatch "(?m)^version:\s*(\d+)\.(\d+)\.(\d+)\+(\d+)\s*$") {
    throw "Cannot find 'version: X.Y.Z+N' line in $Pubspec"
}
$majCur, $minCur, $patchCur, $buildCur = [int]$Matches[1], [int]$Matches[2], [int]$Matches[3], [int]$Matches[4]
Info "Current: $majCur.$minCur.$patchCur+$buildCur"

if ($Version) {
    if ($Version -notmatch '^(\d+)\.(\d+)\.(\d+)$') {
        throw "Bad -Version '$Version'. Expected X.Y.Z (no +build)."
    }
    $majNew, $minNew, $patchNew = [int]$Matches[1], [int]$Matches[2], [int]$Matches[3]
} else {
    # Auto-increment the version with rollover at 99: patch +1, and when it
    # would exceed 99 reset it to 0 and carry into minor (then minor into
    # major the same way). Keeps releases monotonic with zero manual input.
    $majNew, $minNew, $patchNew = $majCur, $minCur, ($patchCur + 1)
    if ($patchNew -gt 99) { $patchNew = 0; $minNew++ }
    if ($minNew   -gt 99) { $minNew   = 0; $majNew++ }
}

# Derive the build number straight from the version so it can never drift out
# of sync with the version name: major*10000 + minor*100 + patch. With each
# part capped at 99 this is strictly monotonic as the version grows
# (1.1.6 -> 10106, 1.1.7 -> 10107, 1.2.0 -> 10200). -Build still forces a
# value as an escape hatch, but normally you never touch it.
$derivedBuild = [int]$majNew * 10000 + [int]$minNew * 100 + [int]$patchNew
$buildNew = if ($PSBoundParameters.ContainsKey('Build')) { $Build } else { $derivedBuild }

# Flutter's --split-per-abi adds an ABI offset to the shipped
# versionCode (armeabi-v7a = +1000). The installed APK on the tablet
# reports buildNumber = pubspec + 1000, and the in-app updater
# (UpdateService) compares "tag's parsed build" > "installed
# buildNumber". So the tag MUST encode the post-offset value, otherwise
# every release looks older than what's installed and no update ever
# fires. The pubspec keeps the pre-offset base so day-to-day Flutter
# tooling stays sane.
$AbiOffset = 1000   # armeabi-v7a — bump if we ever ship arm64/x86_64
$tagBuild  = $buildNew + $AbiOffset

$newVersion = "$majNew.$minNew.$patchNew+$buildNew"
$tag        = "v$majNew.$minNew.$patchNew+$tagBuild"
Info "New:     $newVersion   (tag: $tag, shipped versionCode: $tagBuild)"

# Tag collision check — better to fail now than after pushing commit
$remoteHas = & git -C $RepoRoot ls-remote --tags origin "refs/tags/$tag" 2>$null
if ($remoteHas) { throw "Tag $tag already exists on origin. Bump further (or delete the existing tag)." }
$localHas = & git -C $RepoRoot tag -l $tag
if ($localHas) { throw "Tag $tag already exists locally. Delete with 'git tag -d $tag' or bump further." }

# ---------- 3. Pre-build analyze (before bumping anything irreversible) ----------
Step 'Running flutter analyze'
Push-Location $AppPath
try {
    $analyzeOut = & $flutterCmd analyze 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Host ($analyzeOut -join "`n")
        throw 'flutter analyze reported issues — fix them before releasing.'
    }
    Done 'flutter analyze clean'
} finally { Pop-Location }

# ---------- 4. Bump pubspec.yaml ----------
Step "Bumping pubspec.yaml to $newVersion"
if ($DryRun) {
    Info "[DRY] would write 'version: $newVersion'"
} else {
    $newText = $pubspecText -replace "(?m)^version:\s*\d+\.\d+\.\d+\+\d+\s*$", "version: $newVersion"
    # Preserve original bytes (no transcoding to UTF-16) and no extra newline.
    Set-Content -Path $Pubspec -Value $newText -NoNewline -Encoding utf8
    Done 'pubspec.yaml updated'
}

# Anything beyond this point that fails needs the pubspec bump rolled back.
$bumpedAndUncommitted = -not $DryRun
try {
    # ---------- 5. Build APK ----------
    Step 'Building APK (armeabi-v7a, release)'
    if ($DryRun) {
        Info '[DRY] would run: flutter build apk --release --split-per-abi --target-platform android-arm'
    } else {
        Push-Location $AppPath
        try {
            & $flutterCmd build apk --release --split-per-abi --target-platform android-arm | Out-Host
            if ($LASTEXITCODE -ne 0) { throw 'flutter build apk failed' }
        } finally { Pop-Location }
        if (-not (Test-Path $ApkPath)) { throw "Expected APK not found: $ApkPath" }
        $apkSize = (Get-Item $ApkPath).Length / 1MB
        Done ("APK ready ({0:F1} MB)" -f $apkSize)
    }

    # ---------- 6. Git commit ----------
    # `commit -a` only stages tracked files that are modified — won't pick
    # up untracked stuff like secret.bin / nvs_keys.bin / climate_logs.txt.
    Step 'Committing version bump + tracked changes'
    if ($DryRun) {
        Info "[DRY] would: git add pubspec.yaml && git commit -am `"$Message`""
    } else {
        & git -C $RepoRoot add $Pubspec
        $hasChanges = (& git -C $RepoRoot status --porcelain | Where-Object { $_ }) -ne $null
        if ($hasChanges) {
            & git -C $RepoRoot commit -am $Message
            if ($LASTEXITCODE -ne 0) { throw 'git commit failed' }
            Done ("Committed: $Message")
        } else {
            Info 'Nothing to commit (only the tag will be created)'
        }
        # Once committed, the bump is permanent — clear the rollback flag.
        $bumpedAndUncommitted = $false
    }

    # ---------- 7. Tag ----------
    Step "Creating tag $tag"
    if ($DryRun) {
        Info "[DRY] would: git tag -a $tag -m `"$Message`""
    } else {
        & git -C $RepoRoot tag -a $tag -m $Message
        if ($LASTEXITCODE -ne 0) { throw 'git tag failed' }
        Done "Tag $tag created"
    }

    # ---------- 8. Push (unless -NoPush) ----------
    if ($NoPush) {
        Info 'Skipping push (-NoPush). Done locally.'
        return
    }

    $branch = (& git -C $RepoRoot rev-parse --abbrev-ref HEAD).Trim()
    Step "Pushing branch $branch + tag $tag"
    if ($DryRun) {
        Info "[DRY] would: git push origin $branch && git push origin $tag"
    } else {
        & git -C $RepoRoot push origin $branch
        if ($LASTEXITCODE -ne 0) { throw "git push origin $branch failed" }
        & git -C $RepoRoot push origin $tag
        if ($LASTEXITCODE -ne 0) { throw "git push origin $tag failed" }
        Done "Pushed branch + tag"
    }

    # ---------- 9. GitHub Release + asset upload ----------
    Step "Creating GitHub Release $tag and uploading $AssetName"
    if ($DryRun) {
        Info '[DRY] would POST /releases and upload APK'
        return
    }

    $headers = @{
        'Accept'               = 'application/vnd.github+json'
        'Authorization'        = "Bearer $token"
        'X-GitHub-Api-Version' = '2022-11-28'
    }
    $body = @{
        tag_name   = $tag
        name       = $tag
        body       = $Message
        draft      = $false
        prerelease = [bool]$Prerelease
    } | ConvertTo-Json -Compress

    # PS 5.1's ConvertTo-Json leaves Cyrillic raw (no \u escaping), and
    # Invoke-RestMethod then encodes a *string* body with a single-byte
    # codepage — turning every non-ASCII char into "?". Send explicit UTF-8
    # bytes (with charset on the Content-Type) so release notes survive.
    $bodyBytes = [System.Text.Encoding]::UTF8.GetBytes($body)

    try {
        $release = Invoke-RestMethod -Method POST `
            -Uri "https://api.github.com/repos/$Owner/$Repo/releases" `
            -Headers $headers -Body $bodyBytes -ContentType 'application/json; charset=utf-8'
    } catch {
        throw "Release create failed: $($_.Exception.Message). Tag is pushed; you can create the release manually in the GitHub UI."
    }
    Done "Release created: $($release.html_url)"

    # GitHub's upload_url is of the form ".../releases/123/assets{?name,label}".
    # Strip the template suffix and tack on the asset name as a query param.
    $uploadUrl = ($release.upload_url -replace '\{\?.*\}$', '') + "?name=$AssetName"
    $apkBytes  = [System.IO.File]::ReadAllBytes($ApkPath)
    $upHeaders = @{
        'Accept'        = 'application/vnd.github+json'
        'Authorization' = "Bearer $token"
        'Content-Type'  = 'application/octet-stream'
    }
    try {
        $uploaded = Invoke-RestMethod -Method POST -Uri $uploadUrl `
            -Headers $upHeaders -Body $apkBytes
    } catch {
        throw "APK upload failed: $($_.Exception.Message). Release exists but has no asset — upload manually or delete the release and retry."
    }
    Done "Uploaded: $($uploaded.browser_download_url)"

    Write-Host ""
    Done "RELEASE $tag PUBLISHED"
}
catch {
    Write-Host ""
    Write-Host "[FAIL] $($_.Exception.Message)" -ForegroundColor Red
    # If we bumped pubspec but never committed, revert the bump so the
    # working tree isn't left in a broken state.
    if ($bumpedAndUncommitted) {
        Write-Host "Rolling back pubspec.yaml bump..." -ForegroundColor Yellow
        & git -C $RepoRoot checkout HEAD -- $Pubspec 2>$null
    }
    exit 1
}
