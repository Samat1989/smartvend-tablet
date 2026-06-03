# Fleet provisioning: getting a new tablet into device-owner kiosk mode

## Where this fits

Each new vending tablet needs to be **provisioned as device-owner** so
our app can:

- Silently `startLockTask` without the "App is pinned" dialog
- Hide the navigation bar and status bar permanently
- Reboot the whole device (used by the comms-watchdog escalation at
  reconnect #10, see [`board_client.dart`](../lib/board/board_client.dart))
- Set lock-task allowlist + features

Today this is a manual chore: factory reset → skip all accounts →
enable USB debugging → `adb install` → `adb shell dpm set-device-owner
kz.smartvend.m102_tester/.KioskAdminReceiver`. Works on one tablet but
doesn't scale.

This doc captures three paths we considered and what we'd build to
make on-site provisioning a one-minute operation. **None of this is
implemented yet** — it's a forward-looking design note.

---

## Path 1 — Flutter app that speaks ADB-over-Wi-Fi

**Idea:** a phone app that pretends to be the `adb` binary, connects
to a paired tablet's `adbd` over TCP, and runs the provisioning
commands itself.

**Tech:**

- Android 11+ Wireless ADB pairing: **TLS** + **SPAKE2** key exchange
  with a 6-digit code shown on the tablet. RFC: see AOSP
  `system/core/adb/daemon/auth.cpp`.
- After pairing, plain ADB binary protocol over the TLS socket. Wire
  format: <https://android.googlesource.com/platform/system/core/+/master/adb/protocol.txt>
- Services we'd need:
  - `host:devices` — list paired devices
  - `sync:` — push the APK
  - `shell:` — run `pm install -r /data/local/tmp/foo.apk` and `dpm
    set-device-owner …`

**Existing Dart libraries:**

- `adb_kit` — Flutter ADB client. Maturity varies, last audit was
  spotty on Android 11+ pairing.
- We'd likely write the pairing handshake ourselves and reuse the
  binary protocol from one of the open-source clients.

**Effort:** **1–2 weeks** for stable pairing + shell + sync. Not a
weekend project.

**Critical gotcha:** even with a working ADB client, `dpm
set-device-owner` **still requires no existing user accounts on the
tablet**. The Android-side check is independent of who calls it.
Phone-as-ADB-client does **not** bypass that — operator still has to
factory-reset and skip account setup on every tablet. So this path
solves only "skip the laptop", not "skip the factory reset".

**Verdict:** technically feasible, lots of work, and doesn't actually
remove the painful step.

---

## Path 2 — QR Code Provisioning (**recommended**)

Android's official mechanism for kiosk deployment. The Setup Wizard
on a brand-new (or factory-reset) device has a hidden entry point
that scans a QR code and uses its contents to fully provision the
device-owner in one shot.

### How the operator uses it

1. Factory-reset tablet (or unbox a new one).
2. On the Welcome screen, **tap any blank area 6 times** — opens the
   QR scanner.
3. Operator opens our companion app on their phone → it shows a QR
   code → tablet's camera scans it.
4. Tablet auto-connects to the configured Wi-Fi, downloads our APK
   from the URL in the QR, verifies SHA-256, installs it as
   device-owner, and finishes the setup wizard with our app in
   foreground.

**Total operator time per tablet: ~1 minute.** No laptop, no ADB, no
dpm command, no account-skip dance.

### QR payload format

```json
{
  "android.app.extra.PROVISIONING_DEVICE_ADMIN_COMPONENT_NAME":
    "kz.smartvend.m102_tester/.KioskAdminReceiver",
  "android.app.extra.PROVISIONING_DEVICE_ADMIN_PACKAGE_DOWNLOAD_LOCATION":
    "https://your-cdn/path/app-armeabi-v7a-release.apk",
  "android.app.extra.PROVISIONING_DEVICE_ADMIN_SIGNATURE_CHECKSUM":
    "<base64-of-SHA-256-of-APK>",
  "android.app.extra.PROVISIONING_WIFI_SSID": "Office_WiFi",
  "android.app.extra.PROVISIONING_WIFI_PASSWORD": "secret",
  "android.app.extra.PROVISIONING_WIFI_SECURITY_TYPE": "WPA",
  "android.app.extra.PROVISIONING_LOCALE": "ru_RU",
  "android.app.extra.PROVISIONING_TIME_ZONE": "Asia/Almaty"
}
```

Official extras reference: `DevicePolicyManager` Javadoc, section
"Provisioning Extras".

The checksum must be the **APK file's** SHA-256, NOT the signing-key
hash. Compute with `sha256sum app-release.apk | xxd -r -p | base64`.

### What we'd build

**`provision_qr/` — a Flutter project at the m109e repo root.**

Screens:

1. **APK source picker** — paste URL or pick latest from GitHub
   Releases via API.
2. **Wi-Fi credentials** — SSID + password + security type. Saved in
   `shared_preferences` so the operator types them once per office.
3. **Preview** — shows the JSON about to be encoded.
4. **QR display** — fullscreen via `qr_flutter` (already in our
   `pubspec.yaml` for the payment QR).

Auto-computed:

- SHA-256 of the APK: download the URL, hash, base64-encode. Cache
  per URL so we don't re-download every render.

Stretch:

- Multiple "profiles" (test Wi-Fi vs prod, dev APK vs release).
- "Send link" via QR or NFC of the *companion app itself* so a new
  technician can install the provision-tool in 30 seconds.

**Effort:** **1–2 hours.** Most of the work is UI; the QR payload
is just a `Map<String, String>` JSON-encoded.

### Pre-requisites we still need

- A **publicly-reachable URL** for the APK. Options:
  - GitHub Releases (free, fast, public — fine if our source is
    private-ish but the APK is okay to share)
  - Supabase Storage bucket (we already use Supabase for inventory)
  - Self-hosted on the office's static IP
- An **APK with the device-admin receiver already declared in the
  manifest** — we have this (`KioskAdminReceiver`).

---

## Path 3 — HTTP companion API on the kiosk (runtime ops only)

For **already-provisioned** tablets we can embed an HTTP server in
our own app (via the `shelf` package) on a fixed port (say 8888).
The operator's phone joins the same Wi-Fi, points a browser or
companion app at `http://<tablet-ip>:8888/` and gets:

- Force-reconnect the M102 board
- Push a new APK (self-update via `PackageInstaller`)
- View the bus log in real time
- Trigger factory reset (device-owner only)
- Reload catalog from Supabase
- Read sale history / refund report

**Not a provisioning solution** — needs the app to already be
running, which means device-owner is already set. But it's the right
mechanism for everything *after* provisioning.

**Effort:** ~1 day to set up the server, the route table, and a
matching mobile UI. Token-auth via a shared secret stored in
`DeviceStorage` (operator scans an in-app QR on the kiosk first time
they connect).

---

## Recommended sequence

1. **Now (one-off)**: keep doing the manual `adb shell dpm
   set-device-owner` on each new tablet. There are only a few
   right now.
2. **Once there are ≥ 5 tablets**: build `provision_qr/` (Path 2).
   Drops per-tablet time from ~15 min (factory reset + dev options
   + ADB + dpm) to ~1 min (factory reset + 6 taps + scan).
3. **Later, for ongoing fleet management**: build the HTTP companion
   API (Path 3) so the operator's phone is the remote control for
   every running tablet without needing a laptop on site.

Path 1 (Flutter ADB client) is **not recommended** — solves the
small bit (the dpm command) and doesn't help with the big bit (the
factory reset / no accounts requirement). The Android-mandated QR
flow already handles both.

---

## References

- [`02_M102_PASSWORD.md`](02_M102_PASSWORD.md) — the other "this isn't in the public docs" finding
- [`MainActivity.kt`](../android/app/src/main/kotlin/kz/smartvend/m102_tester/MainActivity.kt) — current device-owner integration (`configureDeviceOwnerKiosk`, `restartApp`, `rebootDevice`)
- [`KioskAdminReceiver.kt`](../android/app/src/main/kotlin/kz/smartvend/m102_tester/KioskAdminReceiver.kt) — the receiver component referenced in the QR payload above
- AOSP — `frameworks/base/core/java/android/app/admin/DevicePolicyManager.java` (the EXTRA names this doc uses)
