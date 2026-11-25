# ThoughtQueue for Android

Android companion to the macOS ThoughtQueue app (Kotlin, Jetpack Compose, Material 3). This is the
app: local notes, checklists, categories, themes, a share target, and S3 sync that interoperates with
the desktop app.

## Setup

- JDK 17 and the Android SDK (platform 35). Put the SDK path in `local.properties` (gitignored):
  `sdk.dir=/path/to/Android/sdk`
- `export JAVA_HOME=/path/to/jdk17`

## Build and test

```bash
./gradlew assembleDebug testDebugUnitTest
```

The debug APK is at `app/build/outputs/apk/debug/app-debug.apk`. From the repo root, `./build.sh` builds the macOS app and this APK (Release with `./build.sh Release`) and prints the APK path.

## Layout

- `store/`: pure Kotlin ports of the desktop store (notes, metadata sidecar, task lists, fuzzy search). No Android imports, so the tests run on the JVM.
- `prefs/`: SharedPreferences settings.
- `ui/`, `ui/theme/`: Compose screens and the theme system (built-in and custom JSON themes, see `../docs/themes.md`).
- `sync/`: S3 sync, a port of the desktop's `ThoughtQueue/Sync/` (SigV4, S3 client, planner, state, engine).
  Everything except `SecretStore` and `SyncWorker` is plain JVM code, so the tests run without a device.

Notes live in `filesDir/notes` as plain `.md` files. Document type and archive flags are kept only in
`.thoughtqueue/metadata.json`, in the same shape the desktop writes.

## S3 sync

Same format and rules as the desktop (`../docs/sync.md`). A bucket written by either app syncs to the other.

- **What syncs**: every non-hidden `.md` file at any depth (categories are folders), plus
  `.thoughtqueue/metadata.json` (doc types, archive flags) and `.thoughtqueue/settings.plist`. The plist
  is treated as opaque bytes: Android never reads or rewrites it. `sync-state.json` and `conflicts/`
  stay on the device.
- **Storage mode** (`Preferences.storageMode`): `local` uses `filesDir/notes` with no network, `s3` uses
  `filesDir/s3cache`, `both` syncs `filesDir/notes`. Switching into `s3` copies existing notes into the
  cache (merge only).
- **Credentials**: endpoint, region, bucket, prefix, path-style and access key ID are in plain
  preferences. The secret key is in EncryptedSharedPreferences (Keystore-backed) and is excluded from backups.
- **Triggers**: launch, a debounced local edit (3 s), a WorkManager periodic job (15 minute minimum,
  needs network) and Sync Now (`TqApp.syncNow()`). Runs are serialized; a trigger during a run schedules
  one follow-up. Automatic triggers do nothing in `local` mode or without a full config.
- **Conflicts**: the remote copy is parked beside the sync state in `noBackupFilesDir/sync-state/`. A banner on the notes list
  opens a screen with each version's dates and text, and Keep device / Keep bucket / Keep both.
- **Cleartext HTTP is allowed** (`res/xml/network_security_config.xml`) so a MinIO or RustFS server on
  your LAN works over `http://`. Use `https://` for anything on the internet. From the emulator, the
  host machine is `http://10.0.2.2:9000`.

## Configuring sync

Open Settings, then "Storage & Sync".

1. Fill in the endpoint (`http://10.0.2.2:9000` from the emulator for a MinIO on your Mac), bucket, access key ID and, optionally, region and prefix. Path-style stays on for MinIO and RustFS; turn it off for AWS virtual-host style.
2. Type the secret key. It is write-only: the screen shows only "Saved" or "Not set", and "Clear secret" removes it (which also drops back to Local only). It is stored in EncryptedSharedPreferences, never in plain prefs.
3. "Test connection" uses the values in the fields, saved or not.
4. "Save" persists the fields and secret. The S3 only and Local + S3 options stay disabled until a valid config and a secret are saved.
5. Pick a storage mode. Switching changes the store root (`notes/` or `s3cache/`) and the notes list.
6. Triggers: launch, after changes, and an interval. Android enforces a 15 minute floor on the interval.

The same screen shows the last sync time, errors, a Sync now button and a link to open conflicts.

### Integration test

`S3IntegrationTest` runs against a real server and is skipped unless these are set. It writes under a
unique `tq-it-<UUID>/` prefix and deletes everything afterwards.

```bash
TQ_S3_ENDPOINT=http://localhost:9000 \
TQ_S3_BUCKET=thoughtqueue-test \
TQ_S3_ACCESS_KEY=tqadmin \
TQ_S3_SECRET_KEY=tqsecret123 \
./gradlew testDebugUnitTest --tests '*S3IntegrationTest*'
```

Optional: `TQ_S3_REGION` (default `us-east-1`), `TQ_S3_PATH_STYLE=false` for virtual-host addressing,
`TQ_S3_PAGINATION=1` to also list about 1000 objects. Gradle forwards these to the test JVM. See
`../docs/sync.md` for starting a local server; the same bucket can run the desktop's integration test too.

## Releasing

The Android app ships in the same GitHub release as the macOS app. `.github/workflows/release.yml`
(tag push `v*` or a manual run with a version bump, see the root README) has an `android` job that runs
the unit tests and builds a minified release APK and AAB. The release job then attaches
`ThoughtQueue-<version>.apk` and `ThoughtQueue-<version>.aab` next to the macOS DMG and zip, all covered
by one `checksums-sha256.txt`. versionName is the tag without `v`, versionCode is the run number.
If the Android build fails, nothing is released.

Upload the `.aab` to Play Console, not the APK.

Secrets (repository settings):

- `ANDROID_KEYSTORE_BASE64`: the keystore, base64 encoded
- `ANDROID_KEYSTORE_PASSWORD`, `ANDROID_KEY_ALIAS`, `ANDROID_KEY_PASSWORD`

Generate a keystore and its base64 (keep the file out of the repo, `*.jks` is gitignored):

```bash
keytool -genkeypair -keystore release.jks -alias thoughtqueue -keyalg RSA -keysize 2048 -validity 10000
base64 -i release.jks | pbcopy
```

Without the secrets the release is built unsigned (the APK is attached as
`ThoughtQueue-<version>-unsigned.apk`) rather than failing. Locally, the same applies unless you set
`TQ_ANDROID_KEYSTORE_PATH`, `TQ_ANDROID_KEYSTORE_PASSWORD`, `TQ_ANDROID_KEY_ALIAS` and
`TQ_ANDROID_KEY_PASSWORD` (env vars or `-P` properties). Override the version with
`-PversionName=1.2.3 -PversionCode=7`. To try a minified build next to the debug app, add
`-PappIdSuffix=.rel`.
