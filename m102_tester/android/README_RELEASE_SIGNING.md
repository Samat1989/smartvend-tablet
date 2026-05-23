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

```
git tag v1.0.5+1005   # versionName+versionCode — matches pubspec.yaml
git push origin v1.0.5+1005
```

GitHub Actions picks up the tag, builds + signs the APK split, attaches
`app-armeabi-v7a-release.apk` to a new GitHub Release. The tablet's
service-mode → Обновление screen reads the latest release via
`api.github.com` and installs it via `PackageInstaller`.
