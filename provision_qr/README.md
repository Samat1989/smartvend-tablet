# provision_qr — Android QR-Code-Provisioning generator

Companion app for fleet rollout of the m102_tester vending tablet.
Operator runs this on their phone, fills in the APK URL + signing
cert SHA-256 + Wi-Fi credentials, taps **«Показать QR»** —
the phone displays a QR that a freshly factory-reset tablet scans
on its Welcome screen. Android then auto-downloads the APK,
verifies the cert, installs as device-owner, and finishes the setup
wizard in about a minute. No ADB cable required.

Background: [`/c/m109e/m102_tester/docs/03_FLEET_PROVISIONING.md`](../m102_tester/docs/03_FLEET_PROVISIONING.md).

## Workflow

1. **On the dev machine** — find the signing cert hash:
   ```powershell
   keytool -list -keystore C:\m109e\m102_tester\android\release.jks `
     -alias smartvend `
     -storepass <password>
   ```
   Copy the `SHA-256:` line (e.g. `9E:C3:C8:BA:…:85:EC`).

2. **In provision_qr**:
   * Paste APK URL — usually a GitHub Release asset:
     `https://github.com/Samat1989/smartvend-tablet/releases/download/vX.Y.Z+N/app-armeabi-v7a-release.apk`
   * Paste the SHA-256 hex (the app converts to the base64-URL-safe
     form Android expects).
   * Fill Wi-Fi SSID + password if the venue has Wi-Fi (otherwise
     the tablet asks at first boot).
   * Tap **«Показать QR»**.

3. **On the new tablet** (factory reset, on Welcome screen):
   * Tap 6 times anywhere on the screen → QR scanner opens.
   * Point at this app's screen.
   * Wait ~1 minute. Tablet reboots into m102_tester as device-owner.

## Architecture

```
lib/
  models/
    provisioning_config.dart   form data + Android-extras JSON encode
  services/
    checksum_helper.dart       keytool hex → base64-url-safe
    config_storage.dart        SharedPreferences single-config persist
  screens/
    home_screen.dart           the form
    qr_screen.dart             fullscreen QR + summary card + JSON view
  main.dart                    boots ConfigStorage + MaterialApp
```

The QR payload follows
[Android's QR Code Provisioning spec](https://developer.android.com/work/dpc/provisioning#qr-code) —
each `EXTRA_*` key maps to a `PROVISIONING_*` field in `toQrPayload()`.

## Build / run

```powershell
cd C:\m109e\provision_qr
flutter pub get
flutter run                  # debug, plug your phone via ADB
flutter build apk --release  # release APK for distribution
```

Release-signed APKs go into the operator/dealer team's phones — they
sit on the phone, not on customer kiosks.
