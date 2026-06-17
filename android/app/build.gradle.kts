plugins {
    id("com.android.application")
    id("kotlin-android")
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "com.omjadhav.odoro"
    compileSdk = 35
    ndkVersion = "28.2.13676358"

    compileOptions {
        isCoreLibraryDesugaringEnabled = true
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }


    signingConfigs {
        create("release") {
            storeFile = file("E:/QPython/Day 28_Android/odoro/odoro-keystore.jks")
            storePassword = "sherlock26holmes"
            keyAlias = "odoro"
            keyPassword = "sherlock26holmes"
        }
    }

    kotlinOptions {
        jvmTarget = "17"
        // Keeps your compilation targeting clean
        freeCompilerArgs += listOf("-Xjvm-default=all")
    }

    defaultConfig {
        applicationId = "com.omjadhav.odoro"
        minSdk = flutter.minSdkVersion // Setting explicitly to 21 to natively support multiDex without issues
        targetSdk = 35
        versionCode = flutter.versionCode
        versionName = flutter.versionName
        multiDexEnabled = true
    }

    buildTypes {
        release {
            signingConfig = signingConfigs.getByName("release")
            isMinifyEnabled = false
            isShrinkResources = false
        }
    }
}

flutter {
    source = "../.."
}

dependencies {
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.0.4")
}
