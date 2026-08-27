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

Intentionally **not used**. The old `.github/workflows/release.yml`
was removed: it was copied from the pre-monorepo layout
(`m102_tester/` instead of `apps/tablet/`) and failed on every tag
push. Releases are built and uploaded locally by
`scripts/release_tablet.py` — CI plays no part.

## Releasing

`scripts/release_tablet.py` (repo root) bumps the version, builds
split-per-abi APKs, tags the commit, pushes to origin, creates a
GitHub Release, and uploads the armeabi-v7a split as its only asset.
Requires `gh` CLI (`sudo apt install gh`) plus `gh auth login`.
A PAT in `.github_token` at the repo root is an optional fallback
for a headless box with no keyring.

```bash
# from the repo root
python3 scripts/release_tablet.py --version 1.0.6+1006
# or with explicit release notes
python3 scripts/release_tablet.py --version 1.0.6+1006 --notes "Adds: …  Fixes: …"
# or, to auto-bump the patch version:
python3 scripts/release_tablet.py
```

Flags: `--draft` (create release as draft), `--skip-build` (reuse
existing APKs), `--no-push` (tag + build locally without pushing).

The script refuses to run if the working tree is dirty, the tag
already exists, the keystore is missing, or `gh` isn't authenticated
— failing loud before any destructive step.

After the release is published, the tablet's service-mode →
Обновление screen reads the latest release via `api.github.com` and
installs the APK via `PackageInstaller`.
