# S3 sync

Optional bi-directional sync between the notes folder and an S3-compatible bucket (AWS S3, [RustFS](https://github.com/rustfs/rustfs), [MinIO](https://min.io)). Code lives in `ThoughtQueue/Sync/`; the engine is `SyncEngine`, the decision table is `SyncPlanner`.

The Android app (`android/app/src/main/java/com/thoughtqueue/app/sync/`) implements this same format and these same rules, so the macOS and Android apps can share a bucket. Any change to the sync format has to land in both.

## Storage modes

`PreferencesManager.storageMode`:

- **local** (default): notes live in the chosen folder, no network.
- **s3**: notes live in a hidden cache at `~/Library/Application Support/ThoughtQueue/S3Cache` and sync to the bucket.
- **both**: notes live in the chosen folder and sync to the bucket.

`PreferencesManager.effectiveStoreRoot` picks the root; `NoteStore.rootURL` follows it.

## What is synced

Every non-hidden `.md` file at any depth (categories are subfolders), plus two sidecars: `.thoughtqueue/metadata.json` (doc types, archive flags) and `.thoughtqueue/settings.plist`. Everything else under hidden folders (including `sync-state.json` and `conflicts/`) is never uploaded, and a remote key with a hidden, empty, `.` or `..` component is rejected (`SyncEngine.isSyncedKey`).

## Base state

`.thoughtqueue/sync-state.json` stores, per key, the local SHA256 and the remote ETag from the last time both sides agreed (the "base"). A key with no base entry has never synced, so a missing file is never read as a deletion. The file is scoped to a config identity (endpoint + bucket + prefix); switching bucket starts from an empty base.

## Planner rules

`local changed` means the hash differs from base, `remote changed` means the ETag differs.

| Local | Remote | Base | Action |
|---|---|---|---|
| present | missing | none | upload |
| missing | present | none | download |
| present | present | none | conflict (unless bytes are equal) |
| present | present | same/same | nothing |
| present | present | local changed | upload |
| present | present | remote changed | download |
| present | present | both changed | conflict (unless bytes are equal) |
| missing | present | remote unchanged | delete remote |
| missing | present | remote changed | conflict |
| present | missing | local unchanged | delete local |
| present | missing | local changed | conflict |
| missing | missing | any | forget base entry |

Keys with an open conflict are skipped until resolved.

## Conflicts

On a real conflict the local file is left alone and the remote bytes are parked at `.thoughtqueue/conflicts/<key>`. The key is recorded in `sync-state.json`, `.syncConflictsDetected` is posted, and `SyncConflictWindowController` offers:

- **Keep local**: upload local over remote.
- **Keep remote**: replace local with the remote copy.
- **Keep both**: local stays, the remote copy is saved beside it as `Name (remote).md` and both are synced.

## Triggers

Launch, a debounced local change, an interval timer (default 5 minutes), and Sync Now. Each is a Preferences toggle. Runs are serialized; a trigger during a run schedules one follow-up. Automatic triggers do nothing when sync is not configured.

## Credentials

Endpoint, region, bucket, prefix, path-style flag and access key ID are in UserDefaults. The secret key is in the Keychain (service `com.thoughtqueue.app.s3`, account `s3-secret-key`).

## Path-style vs virtual-host

Path-style (`https://host/bucket/key`) is the default, and what RustFS and MinIO expect. Virtual-host style (`https://bucket.host/key`) is AWS's preferred form; untick path-style for it.

## Known limitations

- Syncing to a server on your LAN needs the Local Network permission (System Settings > Privacy & Security > Local Network); without it requests fail with "Local network prohibited".
- Single PUT per object, no multipart upload (fine for notes, not for huge files).
- File I/O runs on the main actor (notes are small; network calls suspend).
- No clock-skew handling: signing uses the local clock, so a badly wrong system time gets requests rejected.
- The secret key cannot be cleared from the UI once saved.
- Conflicts are detected by hash and ETag only; there is no merge.

## Integration test

`ThoughtQueueTests/S3IntegrationTests.swift` runs against a real server and is skipped unless the env vars below are set. It writes under a unique `tq-it-<UUID>/` prefix and deletes everything in tearDown. It covers the client round trip (spaces, a category folder, unicode), and a full engine run (upload, remote edit down, delete propagation, conflict). `TQ_S3_PAGINATION=1` adds a ~1000 object listing test.

`xcodebuild` forwards variables prefixed with `TEST_RUNNER_` to the test process with the prefix stripped. Example against a local MinIO (a RustFS container works the same, with its own credentials):

```bash
docker run -d --name tq-minio -p 9000:9000 -e MINIO_ROOT_USER=tqadmin -e MINIO_ROOT_PASSWORD=tqsecret123 minio/minio server /data
# create the bucket once (console at http://localhost:9000 or `mc mb`)

TEST_RUNNER_TQ_S3_ENDPOINT=http://localhost:9000 \
TEST_RUNNER_TQ_S3_BUCKET=thoughtqueue-test \
TEST_RUNNER_TQ_S3_ACCESS_KEY=tqadmin \
TEST_RUNNER_TQ_S3_SECRET_KEY=tqsecret123 \
xcodebuild -project ThoughtQueue.xcodeproj -scheme ThoughtQueueTests test -only-testing:ThoughtQueueTests/S3IntegrationTests
```

Optional: `TEST_RUNNER_TQ_S3_REGION`, `TEST_RUNNER_TQ_S3_PATH_STYLE=false`, `TEST_RUNNER_TQ_S3_PAGINATION=1`.

The Android equivalent is `S3IntegrationTest`. It reads the same `TQ_S3_*` variables, without the `TEST_RUNNER_` prefix, and runs with `cd android && ./gradlew testDebugUnitTest --tests '*S3IntegrationTest*'`.
