plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// ローカルビルドは jp.ohnaka.MimicX.dev / "Mimic X Dev" としてインストールされ、
// GitHub Actions のリリースビルドだけが prod 値 (jp.ohnaka.MimicX / "Mimic X")
// になる。CI は flutter build に -PisProdBuild=true を渡してこれを切替える。
val isProdBuild = (findProperty("isProdBuild") as? String)?.toBoolean() ?: false
val appBundleId = if (isProdBuild) "jp.ohnaka.MimicX" else "jp.ohnaka.MimicX.dev"
val appDisplayName = if (isProdBuild) "Mimic X" else "Mimic X Dev"

android {
    namespace = "jp.ohnaka.MimicX"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_11
        targetCompatibility = JavaVersion.VERSION_11
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_11.toString()
    }

    defaultConfig {
        applicationId = appBundleId
        // AndroidManifest.xml の android:label を切り替えるためのプレースホルダ。
        manifestPlaceholders["appLabel"] = appDisplayName
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        create("release") {
            val keystorePath = System.getenv("ANDROID_KEYSTORE_PATH")
            if (!keystorePath.isNullOrBlank()) {
                storeFile = file(keystorePath)
                storePassword = System.getenv("ANDROID_KEYSTORE_PASSWORD")
                keyAlias = System.getenv("ANDROID_KEY_ALIAS")
                keyPassword = System.getenv("ANDROID_KEY_PASSWORD")
            }
        }
    }

    buildTypes {
        release {
            signingConfig = if (System.getenv("ANDROID_KEYSTORE_PATH").isNullOrBlank()) {
                signingConfigs.getByName("debug")
            } else {
                signingConfigs.getByName("release")
            }
        }
    }
}

flutter {
    source = "../.."
}
