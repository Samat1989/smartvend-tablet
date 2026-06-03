# Release signing

The production tablet APK must be signed with **the same keystore on
every device** so the in-app updater can apply incremental updates.

## Local builds

1. Generate the keystore once (already done — `release.jks` lives here
   but is gitignored):
   ```
   keytool -genkeypair -v -keystore release.jks -keyalg RSA -keysize 2048 \
     -validity 10000 -alias smartvend
   ```
2. Copy `key.properties.example` → `key.properties` and fill in the
   password. `build.gradle.kts` reads it for `flutter build apk
   --release`.

## CI (GitHub Actions)

`.github/workflows/release.yml` reconstructs the keystore on the
runner from four repo secrets. Add them under
**Settings → Secrets and variables → Actions → New repository secret**:

| Name | Value |
| --- | --- |
| `ANDROID_KEYSTORE_BASE64` | base64 of `release.jks` (see command below) |
| `ANDROID_KEYSTORE_PASSWORD` | the `storePassword` you used in keytool |
| `ANDROID_KEY_PASSWORD` | the `keyPassword` (usually the same) |
| `ANDROID_KEY_ALIAS` | `smartvend` |

### Generating the base64 blob

PowerShell:
```
[Convert]::ToBase64String([IO.File]::ReadAllBytes("release.jks")) | Set-Clipboard
```

Bash / Git Bash:
```
base64 -w 0 release.jks | clip
```

The clipboard now holds a long single-line string — paste it as the
value of `ANDROID_KEYSTORE_BASE64` in GitHub Secrets.

## Releasing

### Option 1 — One-shot local script (recommended)

`scripts/release.ps1` bumps the version, builds split-per-abi APKs,
tags the commit, pushes to origin, creates a GitHub Release, and
uploads every ABI as an asset. Requires `gh` CLI (one-time
`winget install GitHub.cli` + `gh auth login`).

```powershell
cd m102_tester
.\scripts\release.ps1 -Version 1.0.6+1006
# or with explicit release notes
.\scripts\release.ps1 -Version 1.0.6+1006 -Notes "Adds: …  Fixes: …"
# or, if pubspec is already at the desired version:
.\scripts\release.ps1
```

Flags: `-Draft` (create release as draft), `-SkipBuild` (reuse
existing APKs), `-NoPush` (tag + build locally without pushing).

The script refuses to run if the working tree is dirty, the tag
already exists, the keystore is missing, or `gh` isn't authenticated
— failing loud before any destructive step.

### Option 2 — GitHub Actions

Push a tag manually and let CI do the build:

```
git tag v1.0.5+1005   # versionName+versionCode — matches pubspec.yaml
git push origin v1.0.5+1005
```

`.github/workflows/release.yml` picks up the tag, builds + signs the
APK split using the repo secrets above, and attaches the assets to a
new GitHub Release. Slower than the local script (~5 min vs ~2 min)
and requires a paid GitHub plan in some account states, but useful
when no dev machine is around.

Either route ends the same way: the tablet's service-mode →
Обновление screen reads the latest release via `api.github.com` and
installs the APK via `PackageInstaller`.
