# Releasing your app

`mix release` builds a Baguette app for each platform through the steps in
`Baguette.Release`. Baguette signs nothing itself: it passes your signing
keys from the environment to the tools that sign (Tauri's bundler, Gradle,
Xcode). This page lists every variable each platform reads and gives a
GitHub Actions workflow to copy into your app.

## Release steps

Add the steps your platforms need to the release in `mix.exs`:

```elixir
def project do
  [
    # ...
    releases: [
      my_app: [
        steps: [
          :assemble,
          &Baguette.Release.package/1,
          &Baguette.Release.bundle/1,
          &Baguette.Release.android/1,
          &Baguette.Release.ios/1
        ],
        baguette: [identifier: "com.example.my_app"]
      ]
    ]
  ]
end
```

- `package/1` installs the host, `bin/my_app_app`. It's required.
- `bundle/1` builds desktop installers. It does nothing unless
  `BAGUETTE_BUNDLES` or the `bundles:` option is set.
- `android/1` does nothing unless `BAGUETTE_ANDROID` is set.
- `ios/1` does nothing unless `BAGUETTE_IOS` is set.

So one `mix release` configuration serves every platform, and each job of a
workflow chooses its platform with environment variables.

`identifier` is the app's ID: a reverse-DNS name. It must match your Apple
provisioning profiles and your Google Play listing.

## What each platform builds

| Platform | Variables | Output |
| --- | --- | --- |
| Linux | `BAGUETTE_BUNDLES=deb,appimage` | `_build/prod/bundle/deb/*.deb`, `_build/prod/bundle/appimage/*.AppImage` |
| macOS | `BAGUETTE_BUNDLES=dmg` | `_build/prod/bundle/dmg/*.dmg` (the `.app` is inside it) |
| Windows | `BAGUETTE_BUNDLES=nsis` or `msi` | `_build/prod/bundle/nsis/*.exe`, `_build/prod/bundle/msi/*.msi` |
| Android | `BAGUETTE_ANDROID=arm64` (or `x86_64`, or `arm64,x86_64`) | `_build/prod/android/my_app.apk`, plus `my_app.aab` when signed |
| iOS | `BAGUETTE_IOS=device` (or `sim`) | `_build/prod/ios/my_app.ipa` (device), `my_app.app` (simulator) |

- **Desktop:** the release uses the build machine's OTP. `mix release`
  downloads the precompiled host and the prebuilt BEAM for that OTP
  version, so a desktop build needs no Rust.
  - Building the host from source (`BAGUETTE_HOST_FEATURES`, or a platform
    with no precompiled host) needs Rust.
- **Mobile:** the host is always built from source, so Android and iOS need
  Rust with the target's toolchain. The BEAM for the device is still
  downloaded.
- **Bundles:** desktop bundles run the Tauri CLI through `npx`, so they
  need Node.
- **OTP version:** the prebuilt BEAMs exist only for the OTP versions
  pinned in Baguette's `priv/liberlang.sha256`. Use one of those, or build
  your own BEAM and set `BAGUETTE_LIBERLANG`.

## Signing variables

### macOS

These are read by Tauri's bundler, which `bundle/1` runs.

| Variable | What it is |
| --- | --- |
| `APPLE_CERTIFICATE` | A Developer ID Application certificate and key, exported as a `.p12` and base64-encoded. The bundler imports it into a temporary keychain. |
| `APPLE_CERTIFICATE_PASSWORD` | The `.p12`'s password. |
| `APPLE_SIGNING_IDENTITY` | The identity to sign with, e.g. `Developer ID Application: Example Ltd (TEAMID)`. |
| `APPLE_ID`, `APPLE_PASSWORD`, `APPLE_TEAM_ID` | Notarization with an Apple ID. `APPLE_PASSWORD` is an app-specific password. |
| `APPLE_API_ISSUER`, `APPLE_API_KEY`, `APPLE_API_KEY_PATH` | Notarization with an App Store Connect API key: the issuer ID, the key ID, and the path to the `.p8` file. Use this or the Apple ID variables. |

Without them, the app is ad hoc signed. It runs on the machine that built it.
Elsewhere, Gatekeeper blocks it until the user allows it.

### Windows

Tauri signs Windows bundles from its configuration, not from environment
variables. Pass that configuration in `TAURI_CONFIG`: a JSON string, or a
path to a JSON file. `bundle/1` merges it over Baguette's own configuration.

| Variable | What it is |
| --- | --- |
| `TAURI_CONFIG` | Holds `bundle.windows`, using one of these signing methods. |

The two signing methods in `bundle.windows`:

- **A certificate in the Windows certificate store:**

  ```json
  {"bundle": {"windows": {
    "certificateThumbprint": "A1B2...",
    "digestAlgorithm": "sha256",
    "timestampUrl": "http://timestamp.digicert.com"
  }}}
  ```

- **A signing command,** for cloud HSMs such as Azure Trusted Signing.
  `%1` is the file to sign:

  ```json
  {"bundle": {"windows": {"signCommand": "trusted-signing-cli -e https://eus.codesigning.azure.net -a MyAccount -c MyProfile %1"}}}
  ```

Unsigned installers work, but SmartScreen warns about them.

### Linux

`.deb` and AppImage bundles are unsigned. Tauri can GPG-sign AppImages
(`SIGN=1`, `SIGN_KEY`, `APPIMAGETOOL_SIGN_PASSPHRASE`), but Baguette hasn't
tested that.

### Android

These are read by `android/1`.

| Variable | What it is |
| --- | --- |
| `BAGUETTE_ANDROID_KEYSTORE` | The path to the upload keystore (`.jks`). In CI, store it base64-encoded as a secret, then decode it to a file. |
| `BAGUETTE_ANDROID_KEYSTORE_PASSWORD` | The keystore's password. |
| `BAGUETTE_ANDROID_KEY_ALIAS` | The key's alias in the keystore. |
| `BAGUETTE_ANDROID_KEY_PASSWORD` | The key's password. |

With all four set, the build is an optimised release, signed with that key,
as an APK and an AAB. Upload the AAB to Google Play. Without them, the
output is a debug-signed APK.

To create a keystore:

```sh
keytool -genkeypair -keystore upload.jks -alias upload -keyalg RSA -keysize 2048 -validity 10000
base64 -w0 upload.jks   # the ANDROID_KEYSTORE secret (macOS: base64 -i upload.jks)
```

### iOS

These are read by `ios/1` and the Tauri CLI. They apply to device builds
only. Simulator builds are never signed.

| Variable | What it is |
| --- | --- |
| `APPLE_DEVELOPMENT_TEAM` | Your Apple team ID. Setting it turns signing on. Without it, the `.ipa` is unsigned. |
| `IOS_CERTIFICATE` | An Apple Distribution (or Development) certificate and key, as a base64 `.p12`. Without it, Xcode uses the keychain's identities. |
| `IOS_CERTIFICATE_PASSWORD` | The `.p12`'s password. |
| `IOS_MOBILE_PROVISION` | The provisioning profile, base64-encoded. Its app ID must match `identifier`. |
| `APPLE_API_KEY`, `APPLE_API_ISSUER`, `APPLE_API_KEY_PATH` | Optional: an App Store Connect API key, so Xcode can manage profiles itself. |
| `BAGUETTE_IOS_EXPORT_METHOD` | `app-store-connect` (App Store and TestFlight), `release-testing` (ad hoc) or `debugging` (development). |
| `BAGUETTE_IOS_PROFILE` | Optional: `release` (the device default) or `debug`. |

### Other variables

| Variable | What it does |
| --- | --- |
| `BAGUETTE_BUNDLES` | The desktop bundle formats, comma-separated. Overrides the release's `bundles:` option. |
| `BAGUETTE_HOST_FEATURES` | Extra Cargo features for the host. Setting it builds the host from source. |
| `BAGUETTE_LIBERLANG` | A directory with your own BEAM build, instead of the download. |
| `NDK_HOME` / `ANDROID_NDK_HOME` | The Android NDK. Required for Android. |

## A release workflow

The workflow below builds every platform when you push a `v*` tag. It then
attaches the results to a GitHub release. Copy it to
`.github/workflows/release.yml` in your app, set `APP` to your release's
name, and delete the jobs you don't ship. Each job reads only its own
platform's secrets. A job whose secrets are missing still builds, just
unsigned. Android is the exception: it builds a debug APK instead.

```yaml
name: Release

on:
  push:
    tags: ["v*"]
  workflow_dispatch:

env:
  APP: my_app            # the release's name in mix.exs
  OTP_VERSION: "29.1.2"  # an OTP version Baguette ships BEAMs for
  ELIXIR_VERSION: "1.20.4"
  MIX_ENV: prod

jobs:
  linux:
    runs-on: ubuntu-24.04
    steps:
      - uses: actions/checkout@v4
      - uses: erlef/setup-beam@v1
        with:
          otp-version: ${{ env.OTP_VERSION }}
          elixir-version: ${{ env.ELIXIR_VERSION }}
      - uses: actions/setup-node@v4
        with:
          node-version: 22
      - name: Bundler dependencies
        run: |
          sudo apt-get update
          sudo apt-get install -y libwebkit2gtk-4.1-dev libgtk-3-dev librsvg2-dev \
            libxdo-dev libssl-dev libfuse2t64 file
      - run: mix deps.get --only prod
      - run: mix release --overwrite
        env:
          BAGUETTE_BUNDLES: deb,appimage
      - uses: actions/upload-artifact@v4
        with:
          name: linux
          path: |
            _build/prod/bundle/deb/*.deb
            _build/prod/bundle/appimage/*.AppImage

  macos:
    strategy:
      matrix:
        runner: [macos-15, macos-15-intel]  # Apple silicon, Intel
    runs-on: ${{ matrix.runner }}
    steps:
      - uses: actions/checkout@v4
      - uses: erlef/setup-beam@v1
        with:
          otp-version: ${{ env.OTP_VERSION }}
          elixir-version: ${{ env.ELIXIR_VERSION }}
      - uses: actions/setup-node@v4
        with:
          node-version: 22
      - run: mix deps.get --only prod
      - run: mix release --overwrite
        env:
          BAGUETTE_BUNDLES: dmg
          APPLE_CERTIFICATE: ${{ secrets.APPLE_CERTIFICATE }}
          APPLE_CERTIFICATE_PASSWORD: ${{ secrets.APPLE_CERTIFICATE_PASSWORD }}
          APPLE_SIGNING_IDENTITY: ${{ secrets.APPLE_SIGNING_IDENTITY }}
          APPLE_ID: ${{ secrets.APPLE_ID }}
          APPLE_PASSWORD: ${{ secrets.APPLE_PASSWORD }}
          APPLE_TEAM_ID: ${{ secrets.APPLE_TEAM_ID }}
      - uses: actions/upload-artifact@v4
        with:
          name: macos-${{ matrix.runner }}
          path: _build/prod/bundle/dmg/*.dmg

  windows:
    runs-on: windows-2025
    defaults:
      run:
        shell: bash
    steps:
      - uses: actions/checkout@v4
      - uses: erlef/setup-beam@v1
        with:
          otp-version: ${{ env.OTP_VERSION }}
          elixir-version: ${{ env.ELIXIR_VERSION }}
      - uses: actions/setup-node@v4
        with:
          node-version: 22
      # Imports a .pfx into the certificate store, for certificateThumbprint.
      - name: Signing certificate
        shell: pwsh
        env:
          WINDOWS_CERTIFICATE: ${{ secrets.WINDOWS_CERTIFICATE }}
          WINDOWS_CERTIFICATE_PASSWORD: ${{ secrets.WINDOWS_CERTIFICATE_PASSWORD }}
        run: |
          if (-not $env:WINDOWS_CERTIFICATE) { exit 0 }
          $pfx = "$env:RUNNER_TEMP\cert.pfx"
          [IO.File]::WriteAllBytes($pfx, [Convert]::FromBase64String($env:WINDOWS_CERTIFICATE))
          $password = ConvertTo-SecureString $env:WINDOWS_CERTIFICATE_PASSWORD -AsPlainText -Force
          Import-PfxCertificate -FilePath $pfx -CertStoreLocation Cert:\CurrentUser\My -Password $password
      - run: mix deps.get --only prod
      - run: mix release --overwrite
        env:
          BAGUETTE_BUNDLES: nsis
          # e.g. {"bundle":{"windows":{"certificateThumbprint":"...","digestAlgorithm":"sha256","timestampUrl":"http://timestamp.digicert.com"}}}
          TAURI_CONFIG: ${{ secrets.WINDOWS_TAURI_CONFIG }}
      - uses: actions/upload-artifact@v4
        with:
          name: windows
          path: _build/prod/bundle/nsis/*.exe

  android:
    runs-on: ubuntu-24.04
    env:
      NDK_VERSION: 27.2.12479018
    steps:
      - uses: actions/checkout@v4
      - uses: erlef/setup-beam@v1
        with:
          otp-version: ${{ env.OTP_VERSION }}
          elixir-version: ${{ env.ELIXIR_VERSION }}
      - uses: dtolnay/rust-toolchain@stable
        with:
          targets: aarch64-linux-android
      - uses: actions/setup-java@v4
        with:
          distribution: temurin
          java-version: "17"
      - uses: actions/setup-node@v4
        with:
          node-version: 22
      - uses: android-actions/setup-android@v3
      - name: NDK
        run: |
          sdkmanager --install "ndk;$NDK_VERSION"
          echo "NDK_HOME=$ANDROID_HOME/ndk/$NDK_VERSION" >> "$GITHUB_ENV"
      - name: Signing key
        env:
          ANDROID_KEYSTORE: ${{ secrets.ANDROID_KEYSTORE }}
        run: |
          [ -n "$ANDROID_KEYSTORE" ] || exit 0
          echo "$ANDROID_KEYSTORE" | base64 -d > "$RUNNER_TEMP/upload.jks"
          echo "BAGUETTE_ANDROID_KEYSTORE=$RUNNER_TEMP/upload.jks" >> "$GITHUB_ENV"
      - run: mix deps.get --only prod
      - run: mix release --overwrite
        env:
          BAGUETTE_ANDROID: arm64
          BAGUETTE_ANDROID_KEYSTORE_PASSWORD: ${{ secrets.ANDROID_KEYSTORE_PASSWORD }}
          BAGUETTE_ANDROID_KEY_ALIAS: ${{ secrets.ANDROID_KEY_ALIAS }}
          BAGUETTE_ANDROID_KEY_PASSWORD: ${{ secrets.ANDROID_KEY_PASSWORD }}
      - uses: actions/upload-artifact@v4
        with:
          name: android
          path: |
            _build/prod/android/*.apk
            _build/prod/android/*.aab

  ios:
    runs-on: macos-15
    steps:
      - uses: actions/checkout@v4
      - uses: erlef/setup-beam@v1
        with:
          otp-version: ${{ env.OTP_VERSION }}
          elixir-version: ${{ env.ELIXIR_VERSION }}
      - uses: dtolnay/rust-toolchain@stable
        with:
          targets: aarch64-apple-ios
      - uses: actions/setup-node@v4
        with:
          node-version: 22
      - run: brew install xcodegen
      - run: mix deps.get --only prod
      - run: mix release --overwrite
        env:
          BAGUETTE_IOS: device
          APPLE_DEVELOPMENT_TEAM: ${{ secrets.APPLE_DEVELOPMENT_TEAM }}
          IOS_CERTIFICATE: ${{ secrets.IOS_CERTIFICATE }}
          IOS_CERTIFICATE_PASSWORD: ${{ secrets.IOS_CERTIFICATE_PASSWORD }}
          IOS_MOBILE_PROVISION: ${{ secrets.IOS_MOBILE_PROVISION }}
          BAGUETTE_IOS_EXPORT_METHOD: app-store-connect
      - uses: actions/upload-artifact@v4
        with:
          name: ios
          path: _build/prod/ios/*.ipa

  publish:
    if: startsWith(github.ref, 'refs/tags/')
    needs: [linux, macos, windows, android, ios]
    runs-on: ubuntu-24.04
    permissions:
      contents: write
    steps:
      - uses: actions/download-artifact@v4
        with:
          path: dist
          merge-multiple: true
      - uses: softprops/action-gh-release@v2
        with:
          files: dist/**/*
```

Notes:

- **Secrets:** add them under the repository's *Settings → Secrets and
  variables → Actions*. Use the secret names from the workflow; each job
  maps them to the variables Baguette and Tauri read.
- **Bundle names** carry the version and architecture (e.g.
  `my_app_0.1.0_aarch64.dmg`), so the two macOS builds don't collide.
- **Notarization:** the job above uses an Apple ID. To use an API key
  instead, write the `.p8` to a file and set `APPLE_API_ISSUER`,
  `APPLE_API_KEY` and `APPLE_API_KEY_PATH` in place of the `APPLE_ID`
  variables.
- **Signing on Windows:** with `signCommand`, skip the certificate step.
  Install your signing tool instead, and put the command in
  `WINDOWS_TAURI_CONFIG`.
- **Store uploads** (App Store Connect, Google Play) aren't covered here.
  Tools such as `fastlane`, `xcrun altool` or
  `r0adkll/upload-google-play` take the `.ipa` and `.aab` from the
  artifacts.
- **Local builds** use the same variables:
  `BAGUETTE_BUNDLES=dmg MIX_ENV=prod mix release` on a Mac, for example.
