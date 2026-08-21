plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "kz.smartvend.mmd"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_17.toString()
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "kz.smartvend.mmd"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    packaging {
        resources {
            // BouncyCastle ships signature files that collide once its jars
            // are merged into an APK.
            excludes += setOf("META-INF/versions/9/OSGI-INF/MANIFEST.MF")
        }
    }

    buildTypes {
        release {
            // TODO: Add your own signing config for the release build.
            // Signing with the debug keys for now, so `flutter run --release` works.
            signingConfig = signingConfigs.getByName("debug")
        }
    }
}

flutter {
    source = "../.."
}

dependencies {
    // Speaks the ADB wire protocol, including the Android 11 pairing
    // handshake. Dual licensed GPL-3.0-or-later / Apache-2.0 — we rely on the
    // Apache terms.
    implementation("com.github.MuntashirAkon:libadb-android:3.1.1")
    // TLSv1.3 on Android versions whose own stack predates it; the pairing
    // handshake requires it.
    implementation("org.conscrypt:conscrypt-android:2.5.3")
    // Android has no public API for minting a self-signed X.509, and ADB
    // insists we present one. Must be the jdk15to18 line: libadb-android
    // already pulls bcprov from it, and mixing the two lines collides on
    // every shared class.
    implementation("org.bouncycastle:bcpkix-jdk15to18:1.81")
}
