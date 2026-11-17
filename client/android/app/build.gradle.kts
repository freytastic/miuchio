import java.util.Properties

plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must follow the Android and Kotlin plugins
    id("dev.flutter.flutter-gradle-plugin")
}

// Upload key for Play
val keyProperties = Properties().apply {
    val file = rootProject.file("key.properties")
    if (file.exists()) file.inputStream().use { load(it) }
}
val hasUploadKey = keyProperties.isNotEmpty()
// Set by flash.sh so sideloaded release builds may use the debug key
val devBuild = System.getenv("MIUCHIO_DEV_BUILD") == "true"

gradle.taskGraph.whenReady {
    val storeBuild = allTasks.any {
        it.name == "bundleRelease" || it.name == "assembleRelease"
    }
    if (storeBuild && !hasUploadKey && !devBuild) {
        throw GradleException(
            "android/key.properties is missing, release builds need the upload key " +
                "(MIUCHIO_DEV_BUILD=true allows debug signing for sideloading)"
        )
    }
}

android {
    namespace = "com.freytastic.miuchio"
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
        applicationId = "com.freytastic.miuchio"
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        if (hasUploadKey) {
            create("release") {
                storeFile = rootProject.file(keyProperties.getProperty("storeFile"))
                storePassword = keyProperties.getProperty("storePassword")
                keyAlias = keyProperties.getProperty("keyAlias")
                keyPassword = keyProperties.getProperty("keyPassword")
            }
        }
    }

    buildTypes {
        release {
            // Debug signing is only reachable through the dev build opt in above
            signingConfig = signingConfigs.findByName("release")
                ?: signingConfigs.getByName("debug")
        }
    }
}

flutter {
    source = "../.."
}

dependencies {
    // Reads HEIF orientation unavailable from framework ExifInterface
    implementation("androidx.exifinterface:exifinterface:1.3.7")
}
