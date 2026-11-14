package com.thoughtqueue.app.sync

import com.thoughtqueue.app.prefs.StorageMode
import com.thoughtqueue.app.prefs.SyncSettings
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test
import java.io.File
import java.net.ConnectException
import java.net.UnknownHostException
import java.net.UnknownServiceException
import java.nio.file.Files
import java.time.Instant

/** The small pieces around the engine: state file shape, error messages, storage modes, the fake store. */
class SyncSupportTest {

    // MARK: SyncState

    @Test fun stateEncodesInSwiftShapeAndRoundTrips() {
        val state = SyncState(
            "http://localhost:9000|bkt|",
            mapOf("b.md" to SyncState.Entry("hb", "eb"), "Work/a.md" to SyncState.Entry("ha", "ea")),
            listOf(SyncState.Conflict("note.md", Instant.parse("2026-11-13T10:00:00Z"))),
        )
        val expected = """
        {
          "configIdentity" : "http:\/\/localhost:9000|bkt|",
          "conflicts" : [
            {
              "detectedAt" : "2026-11-13T10:00:00Z",
              "key" : "note.md"
            }
          ],
          "entries" : {
            "Work\/a.md" : {
              "localHash" : "ha",
              "remoteETag" : "ea"
            },
            "b.md" : {
              "localHash" : "hb",
              "remoteETag" : "eb"
            }
          }
        }
        """.trimIndent()
        assertEquals(expected, state.encode())
        assertEquals(state, SyncState.decode(expected))
    }

    @Test fun emptyStateEncodesEmptyCollectionsLikeFoundation() {
        assertEquals(
            "{\n  \"configIdentity\" : \"x\",\n  \"conflicts\" : [\n\n  ],\n  \"entries\" : {\n\n  }\n}",
            SyncState("x").encode(),
        )
    }

    @Test fun loadScopesByIdentityAndRejectsGarbage() {
        val root = Files.createTempDirectory("tq-state").toFile()
        try {
            SyncState("A", mapOf("a.md" to SyncState.Entry("h", "e"))).save(root)
            assertEquals(1, SyncState.load(root, "A").entries.size)
            assertTrue(SyncState.load(root, "B").entries.isEmpty())
            SyncState.fileOf(root).writeText("not json")
            try {
                SyncState.load(root, "A")
                fail("an unreadable state must throw, not reset the base")
            } catch (e: IllegalArgumentException) {
                // expected
            }
        } finally {
            root.deleteRecursively()
        }
    }

    // MARK: SyncErrorMessage

    @Test fun errorMessagesAreReadable() {
        assertEquals("S3 request failed with HTTP 403.", SyncErrorMessage.describe(S3ClientError.Http(403)))
        assertTrue(SyncErrorMessage.describe(UnknownHostException("minio.lan")).contains("minio.lan"))
        assertTrue(SyncErrorMessage.describe(ConnectException("refused")).startsWith("Could not connect"))
        assertEquals(
            SyncErrorMessage.CLEARTEXT_BLOCKED,
            SyncErrorMessage.describe(UnknownServiceException("CLEARTEXT communication to 10.0.2.2 not permitted")),
        )
        assertEquals(SyncEngineError.NotConfigured.message, SyncErrorMessage.describe(SyncEngineError.NotConfigured))
    }

    // MARK: Storage mode and settings

    @Test fun storageModeMapsToRoots() {
        val files = File("/data/files")
        assertEquals(File(files, "notes"), StorageMode.LOCAL.storeRoot(files))
        assertEquals(File(files, "s3cache"), StorageMode.S3.storeRoot(files))
        assertEquals(File(files, "notes"), StorageMode.BOTH.storeRoot(files))
        assertEquals(listOf(false, true, true), StorageMode.entries.map { it.syncs })
        assertEquals(StorageMode.BOTH, StorageMode.fromRaw("both"))
        assertEquals(StorageMode.LOCAL, StorageMode.fromRaw("nonsense"))
        assertEquals(StorageMode.LOCAL, StorageMode.fromRaw(null))
    }

    @Test fun syncSettingsDefaultsAndConfig() {
        val d = SyncSettings()
        assertTrue(d.pathStyle && d.syncAtLaunch && d.syncOnChange && d.syncOnInterval)
        assertEquals(15, d.intervalMinutes)
        assertNull(d.s3Config())
        val cfg = d.copy(endpoint = "http://10.0.2.2:9000", bucket = "b", accessKeyId = "AK").s3Config()
        assertNotNull(cfg)
        assertEquals("us-east-1", cfg!!.region)
    }

    // MARK: Fake store (mirrors testInMemoryObjectStoreBehavesLikeS3)

    @Test fun inMemoryObjectStoreBehavesLikeS3() = runBlocking {
        val store = InMemoryObjectStore()
        val etag = store.put("a/x.md", "hello".toByteArray())
        assertEquals("5d41402abc4b2a76b9719d911017c592", etag)
        store.put("b.md", ByteArray(0))
        assertEquals(listOf("a/x.md"), store.list("a/").map { it.key })
        assertEquals(ObjectContent("hello".toByteArray(), etag), store.get("a/x.md"))
        store.delete("a/x.md")
        store.delete("missing")
        try {
            store.get("a/x.md")
            fail("expected NoSuchKey")
        } catch (e: S3ClientError.Service) {
            assertEquals(404, e.status)
        }
    }
}
