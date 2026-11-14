package com.thoughtqueue.app.sync

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.cancel
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.sync.Semaphore
import kotlinx.coroutines.sync.withPermit
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.fail
import org.junit.Assume.assumeTrue
import org.junit.Before
import org.junit.Test
import java.io.File
import java.net.URI
import java.nio.file.Files
import java.util.UUID

/**
 * Opt-in tests against a real S3-compatible server (MinIO, RustFS, AWS, R2), mirroring the
 * desktop's `S3IntegrationTests.swift`. Skipped unless `TQ_S3_ENDPOINT`, `TQ_S3_BUCKET`,
 * `TQ_S3_ACCESS_KEY` and `TQ_S3_SECRET_KEY` are set. Optional: `TQ_S3_REGION` (default
 * us-east-1), `TQ_S3_PATH_STYLE` (default true) and `TQ_S3_PAGINATION=1`. Every object is
 * written under a unique `tq-it-<UUID>/` prefix and removed in tearDown.
 */
class S3IntegrationTest {
    private var client: S3Client? = null
    private lateinit var config: S3Config
    private lateinit var root: File
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)

    @Before fun setUp() {
        val env = System.getenv()
        val endpoint = env["TQ_S3_ENDPOINT"]
        val bucket = env["TQ_S3_BUCKET"]
        val access = env["TQ_S3_ACCESS_KEY"]
        val secret = env["TQ_S3_SECRET_KEY"]
        assumeTrue(
            "Set TQ_S3_ENDPOINT, TQ_S3_BUCKET, TQ_S3_ACCESS_KEY, TQ_S3_SECRET_KEY to run S3 integration tests.",
            endpoint != null && bucket != null && access != null && secret != null,
        )
        val pathStyle = (env["TQ_S3_PATH_STYLE"] ?: "true").lowercase() != "false"
        config = S3Config(
            URI(endpoint!!), env["TQ_S3_REGION"] ?: "us-east-1", bucket!!,
            "tq-it-${UUID.randomUUID()}/", pathStyle, access!!,
        )
        client = S3Client(config, secret!!)
        root = Files.createTempDirectory("tq-it").toFile()
    }

    @After fun tearDown() = runBlocking {
        client?.let { c ->
            for (obj in c.list("")) c.delete(obj.key)
            root.deleteRecursively()
        }
        scope.cancel()
    }

    /** put/list/get/delete with spaces, a category folder and unicode in the key. */
    @Test fun clientRoundTrip() = runBlocking {
        val c = client!!
        c.testConnection()
        val keys = listOf("Work/My Note.md", "plain.md", "Idées/café ☕.md")
        for (key in keys) assertFalse(c.put(key, "body of $key".toByteArray()).isEmpty())

        assertEquals(keys.toSet(), c.list("").map { it.key }.toSet())
        assertEquals(listOf("Work/My Note.md"), c.list("Work/").map { it.key })
        for (key in keys) assertEquals("body of $key", String(c.get(key).data))

        c.delete("Work/My Note.md")
        c.delete("Work/My Note.md") // deleting a missing key succeeds
        try {
            c.get("Work/My Note.md")
            fail("expected NoSuchKey")
        } catch (e: S3ClientError.Service) {
            assertEquals("NoSuchKey", e.code)
        }
    }

    /** Lists more than one page (servers cap a page at 1000 keys). Slow, so opt-in. */
    @Test fun listPagination() = runBlocking {
        assumeTrue("Set TQ_S3_PAGINATION=1 to upload about 1000 objects.", System.getenv("TQ_S3_PAGINATION") == "1")
        val c = client!!
        val total = 1005
        val gate = Semaphore(16)
        (0 until total).map { i ->
            async(Dispatchers.IO) { gate.withPermit { c.put("page/n%04d.md".format(i), "x".toByteArray()) } }
        }.awaitAll()
        val listed = c.list("page/")
        assertEquals(total, listed.size)
        assertEquals(total, listed.map { it.key }.toSet().size)
    }

    /** Upload, remote edit down, delete propagation both ways, then a conflict, on a real server. */
    @Test fun engineAgainstRealStore() = runBlocking {
        val c = client!!
        val context = SyncContext(c, root, SyncState.identity(config))
        val engine = SyncEngine(scope, contextProvider = { context })

        fun writeLocal(key: String, text: String) = File(root, key).also { it.parentFile!!.mkdirs() }.writeText(text)
        fun readLocal(key: String) = File(root, key).takeIf { it.exists() }?.readText()
        suspend fun readRemote(key: String) = SyncEngine.getIfExists(key, c)?.data?.let { String(it) }

        // Upload, including a category folder, a space and unicode.
        writeLocal("Work/My Note.md", "v1")
        writeLocal("café ☕.md", "latte")
        assertEquals(setOf("Work/My Note.md", "café ☕.md"), engine.run(context).uploaded.toSet())
        assertEquals("v1", readRemote("Work/My Note.md"))

        // Remote edit comes down.
        c.put("Work/My Note.md", "v2".toByteArray())
        assertEquals(listOf("Work/My Note.md"), engine.run(context).downloaded)
        assertEquals("v2", readLocal("Work/My Note.md"))

        // Local delete propagates up, remote delete propagates down.
        File(root, "café ☕.md").delete()
        assertEquals(listOf("café ☕.md"), engine.run(context).deletedRemote)
        assertNull(readRemote("café ☕.md"))
        c.delete("Work/My Note.md")
        assertEquals(listOf("Work/My Note.md"), engine.run(context).deletedLocal)
        assertNull(readLocal("Work/My Note.md"))

        // Conflict: both sides edit after a clean sync.
        writeLocal("note.md", "base")
        engine.run(context)
        writeLocal("note.md", "local edit")
        c.put("note.md", "remote edit".toByteArray())
        assertEquals(listOf("note.md"), engine.run(context).newConflicts)
        assertEquals("local edit", readLocal("note.md"))

        engine.resolveConflict("note.md", ConflictResolution.KEEP_REMOTE, context)
        assertEquals("remote edit", readLocal("note.md"))
        assertEquals(SyncReport(), engine.run(context))
    }
}
