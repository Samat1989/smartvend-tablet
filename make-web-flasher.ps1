# Build esp-relay and produce the browser-flasher bundle in docs/flash/.
#
# Generates docs/flash/relay-merged.bin (bootloader + partition table + otadata
# + app merged into one 0x0 image) and refreshes the version in manifest.json.
# ESP Web Tools (docs/flash/index.html) flashes that single image over Web
# Serial, so a remote helper only needs Chrome/Edge + a USB cable.
#
# Usage (plain PowerShell is fine; get_idf is auto-loaded):
#   .\make-web-flasher.ps1                 # build + merge locally
#   .\make-web-flasher.ps1 -Commit         # also git-commit docs/flash
#   .\make-web-flasher.ps1 -Commit -Push   # commit + push (GitHub Pages updates)

[CmdletBinding()]
param([switch]$Commit, [switch]$Push)
$ErrorActionPreference = 'Stop'

$RepoRoot = $PSScriptRoot
$FwPath   = Join-Path $RepoRoot 'firmware/esp-relay'
$MainC    = Join-Path $FwPath 'main/main.c'
$OutDir   = Join-Path $RepoRoot 'docs/flash'
$OutBin   = Join-Path $OutDir 'relay-merged.bin'
$Manifest = Join-Path $OutDir 'manifest.json'

function Step($m) { Write-Host "==> $m" -ForegroundColor Cyan }
function Done($m) { Write-Host "[OK] $m" -ForegroundColor Green }

# ---------- load ESP-IDF env ----------
if (-not (Get-Command idf.py -ErrorAction SilentlyContinue)) {
    if (Get-Command get_idf -ErrorAction SilentlyContinue) {
        Step 'Loading ESP-IDF environment (get_idf)'
        get_idf
    }
}
if (-not (Get-Command idf.py -ErrorAction SilentlyContinue)) {
    throw 'idf.py not available. Run get_idf or the ESP-IDF export.ps1, then retry.'
}

# ---------- build ----------
Step 'Building firmware (idf.py build)'
Push-Location $FwPath
try {
    idf.py build | Out-Host
    if ($LASTEXITCODE -ne 0) { throw 'idf.py build failed' }
} finally { Pop-Location }

# ---------- merge into a single image ----------
Step 'Merging bootloader + partitions + app into one image'
if (-not (Test-Path $OutDir)) { New-Item -ItemType Directory -Force $OutDir | Out-Null }
Push-Location (Join-Path $FwPath 'build')
try {
    # flash_args lists the offset/file pairs + flash params, paths relative to build/.
    # NB: this esptool spells it "merge_bin" (underscore), not "merge-bin".
    esptool.py --chip esp32 merge_bin -o $OutBin "@flash_args" | Out-Host
    if ($LASTEXITCODE -ne 0) { throw 'esptool merge_bin failed' }
} finally { Pop-Location }
Done ("relay-merged.bin: {0:F0} KB" -f ((Get-Item $OutBin).Length / 1KB))

# ---------- sync manifest version from main.c ----------
$mainText = Get-Content $MainC -Raw -Encoding UTF8
if ($mainText -match '#define\s+FW_VERSION_NAME\s+"([^"]+)"') {
    $ver = $Matches[1]
    $mj  = Get-Content $Manifest -Raw -Encoding UTF8
    $mj  = $mj -replace '"version"\s*:\s*"[^"]*"', "`"version`": `"$ver`""
    # Write UTF-8 WITHOUT BOM so JSON.parse in the browser is happy.
    [System.IO.File]::WriteAllText($Manifest, $mj, (New-Object System.Text.UTF8Encoding($false)))
    Done "manifest version -> $ver"
}

# ---------- optional commit / push ----------
if ($Commit) {
    Step 'Committing docs/flash'
    & git -C $RepoRoot add $OutDir
    & git -C $RepoRoot commit -m "web-flasher: refresh relay-merged.bin"
    if ($Push) {
        $branch = (& git -C $RepoRoot rev-parse --abbrev-ref HEAD).Trim()
        & git -C $RepoRoot push origin $branch
        Done "pushed $branch"
    }
}

Write-Host ""
Done 'Flasher bundle ready in docs/flash/'
Write-Host '   Enable once: GitHub repo -> Settings -> Pages -> Source: main /docs' -ForegroundColor Gray
Write-Host '   Flasher URL: https://samat1989.github.io/smartvend-tablet/flash/' -ForegroundColor Gray
