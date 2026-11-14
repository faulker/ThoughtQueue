package com.thoughtqueue.app.sync

import kotlinx.coroutines.runBlocking
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Before
import org.junit.Test
import java.io.BufferedInputStream
import java.io.ByteArrayOutputStream
import java.net.InetAddress
import java.net.ServerSocket
import java.net.Socket
import kotlin.concurrent.thread
import java.net.URI

/**
 * Ports `S3ClientTests.swift` and the URL/XML parts of `S3BackendTests.swift`. Request flow is
 * exercised against a minimal local HTTP/1.1 server on a [ServerSocket] serving canned replies
 * (the JDK's `HttpServer` is not on the Android unit-test classpath).
 */
class S3ClientTest {
    /** One request the stub server saw. */
    private data class Seen(val method: String, val rawUri: String, val headers: Map<String, String>, val body: ByteArray)

    private lateinit var server: ServerSocket
    private val seen = mutableListOf<Seen>()

    /** Reply for each request: status, headers, body. */
    @Volatile
    private var handler: (Seen) -> Triple<Int, Map<String, String>, ByteArray> = { Triple(500, emptyMap(), ByteArray(0)) }
    private lateinit var client: S3Client

    @Before fun setUp() {
        server = ServerSocket(0, 50, InetAddress.getByName("127.0.0.1"))
        thread(isDaemon = true) {
            while (!server.isClosed) {
                val socket = try {
                    server.accept()
                } catch (e: java.io.IOException) {
                    break
                }
                socket.use { serve(it) }
            }
        }
        val cfg = S3Config(URI("http://127.0.0.1:${server.localPort}"), "us-east-1", "bkt", "notes", true, "AK")
        client = S3Client(cfg, "SK")
    }

    @After fun tearDown() {
        server.close()
    }

    /** Reads one request (line, headers, Content-Length body), records it, and writes the canned reply. */
    private fun serve(socket: Socket) {
        val input = BufferedInputStream(socket.getInputStream())

        /** Reads one CRLF-terminated line as Latin-1. */
        fun readLine(): String {
            val out = ByteArrayOutputStream()
            while (true) {
                val b = input.read()
                if (b < 0 || b == '\n'.code) break
                if (b != '\r'.code) out.write(b)
            }
            return out.toString("ISO-8859-1")
        }
        val requestLine = readLine().split(" ")
        val headers = HashMap<String, String>()
        while (true) {
            val line = readLine()
            if (line.isEmpty()) break
            val colon = line.indexOf(':')
            headers[line.substring(0, colon).trim().lowercase()] = line.substring(colon + 1).trim()
        }
        val length = headers["content-length"]?.toInt() ?: 0
        val body = ByteArray(length)
        var read = 0
        while (read < length) {
            val n = input.read(body, read, length - read)
            if (n < 0) break
            read += n
        }
        val req = Seen(requestLine[0], requestLine[1], headers, body)
        synchronized(seen) { seen.add(req) }

        val (status, replyHeaders, replyBody) = handler(req)
        val sb = StringBuilder("HTTP/1.1 $status X\r\n")
        replyHeaders.forEach { (k, v) -> sb.append("$k: $v\r\n") }
        sb.append("Content-Length: ${if (req.method == "HEAD") 0 else replyBody.size}\r\nConnection: close\r\n\r\n")
        val out = socket.getOutputStream()
        out.write(sb.toString().toByteArray(Charsets.ISO_8859_1))
        if (req.method != "HEAD") out.write(replyBody)
        out.flush()
    }

    @Test fun listFollowsContinuationTokenAndStripsPrefix() = runBlocking {
        handler = { req ->
            val body = if (req.rawUri.contains("continuation-token")) {
                """<ListBucketResult><IsTruncated>false</IsTruncated>
                <Contents><Key>notes/b.md</Key><LastModified>2024-01-01T00:00:00.000Z</LastModified><ETag>"2"</ETag><Size>2</Size></Contents>
                </ListBucketResult>"""
            } else {
                """<ListBucketResult><IsTruncated>true</IsTruncated><NextContinuationToken>tok/1=</NextContinuationToken>
                <Contents><Key>notes/a.md</Key><LastModified>2024-01-01T00:00:00.000Z</LastModified><ETag>"1"</ETag><Size>1</Size></Contents>
                </ListBucketResult>"""
            }
            Triple(200, emptyMap(), body.toByteArray())
        }
        val objects = client.list("")
        assertEquals(listOf("a.md", "b.md"), objects.map { it.key })
        assertEquals(listOf("1", "2"), objects.map { it.etag })
        assertEquals(2, seen.size)
        assertEquals("/bkt/?list-type=2&prefix=notes%2F&continuation-token=tok%2F1%3D", seen[1].rawUri)
        val auth = seen[0].headers["authorization"].orEmpty()
        assertTrue(auth, auth.startsWith("AWS4-HMAC-SHA256 Credential=AK/"))
        assertNotNull(seen[0].headers["x-amz-date"])
    }

    @Test fun putSignsPayloadAndReturnsETag() = runBlocking {
        handler = { Triple(200, mapOf("ETag" to "\"abc123\""), ByteArray(0)) }
        val body = "hello".toByteArray()
        assertEquals("abc123", client.put("Work/x y.md", body))
        val req = seen.single()
        assertEquals("PUT", req.method)
        assertEquals("/bkt/notes/Work/x%20y.md", req.rawUri)
        assertEquals(SigV4.sha256Hex(body), req.headers["x-amz-content-sha256"])
        assertEquals("hello", String(req.body))
    }

    /** A proxy that gzips the body (Cloudflare) serves a weak ETag; it must match the LIST ETag. */
    @Test fun getNormalizesWeakETag() = runBlocking {
        handler = { Triple(200, mapOf("ETag" to "W/\"abc123\""), "x".toByteArray()) }
        assertEquals("abc123", client.get("a.md").etag)
    }

    /** Strong, weak, padded and bare ETags all normalize to the same value. */
    @Test fun stripQuotesHandlesWeakAndStrongETags() {
        for (raw in listOf("\"abc\"", "W/\"abc\"", "w/\"abc\"", " W/\"abc\" ", "abc")) {
            assertEquals(raw, "abc", S3Client.stripQuotes(raw))
        }
    }

    @Test fun unicodeKeyIsSentEncodedAndSignatureHostMatches() = runBlocking {
        handler = { Triple(200, mapOf("ETag" to "\"e\""), "x".toByteArray()) }
        val got = client.get("Idées/café ☕.md")
        assertEquals("e", got.etag)
        assertEquals("/bkt/notes/Id%C3%A9es/caf%C3%A9%20%E2%98%95.md", seen.single().rawUri)
        assertEquals("127.0.0.1:${server.localPort}", seen.single().headers["host"])
    }

    @Test fun getSurfacesServiceError() = runBlocking {
        handler = { Triple(404, emptyMap(), "<Error><Code>NoSuchKey</Code><Message>gone</Message></Error>".toByteArray()) }
        try {
            client.get("a.md")
            fail("expected an error")
        } catch (e: S3ClientError) {
            assertEquals(S3ClientError.Service(404, "NoSuchKey", "gone"), e)
        }
        assertNull(SyncEngine.getIfExists("a.md", client))
    }

    @Test fun connectionFailureIsHTTPStatus() = runBlocking {
        handler = { Triple(403, emptyMap(), ByteArray(0)) }
        try {
            client.testConnection()
            fail("expected an error")
        } catch (e: S3ClientError) {
            assertEquals(S3ClientError.Http(403), e)
            assertEquals("HEAD", seen.first().method)
        }
    }

    // MARK: URL building (S3BackendTests.swift)

    private fun config(pathStyle: Boolean, prefix: String = "notes") =
        S3Config(URI("https://s3.example.com"), "us-east-1", "mybucket", prefix, pathStyle, "AK")

    @Test fun pathStyleObjectURLHonorsPrefix() {
        assertEquals("https://s3.example.com/mybucket/notes/Work/My%20Note.md", config(true).objectURL("Work/My Note.md").toString())
    }

    @Test fun virtualHostObjectURLHonorsPrefix() {
        assertEquals("https://mybucket.s3.example.com/notes/Work/My%20Note.md", config(false).objectURL("Work/My Note.md").toString())
    }

    @Test fun prefixIsNormalizedAndOptional() {
        assertEquals("a/b/", config(true, "/a/b/").normalizedPrefix)
        assertEquals("https://s3.example.com/mybucket/x.md", config(true, "").objectURL("x.md").toString())
        assertEquals("x.md", config(true).relativeKey("notes/x.md"))
        assertNull(config(true).relativeKey("other/x.md"))
    }

    @Test fun bucketURLWithPortAndQuery() {
        val cfg = config(true).copy(endpoint = URI("http://localhost:9000"))
        assertEquals(
            "http://localhost:9000/mybucket/?list-type=2&prefix=notes%2F",
            cfg.bucketURL(listOf("list-type" to "2", "prefix" to "notes/")).toString(),
        )
        assertEquals("https://mybucket.s3.example.com/", config(false).bucketURL().toString())
    }

    @Test fun makeConfigValidatesAndDefaultsRegion() {
        val ok = S3Config.make(" http://localhost:9000 ", "", " bkt ", " p ", true, " AK ")!!
        assertEquals("us-east-1", ok.region)
        assertEquals("bkt", ok.bucket)
        assertEquals("AK", ok.accessKeyId)
        assertEquals("http://localhost:9000|bkt|p/", SyncState.identity(ok))
        assertNull(S3Config.make("ftp://h", "", "b", "", true, "AK"))
        assertNull(S3Config.make("http://h", "", "", "", true, "AK"))
        assertNull(S3Config.make("http://h", "", "b", "", true, ""))
        assertNull(S3Config.make("not a url", "", "b", "", true, "AK"))
    }

    // MARK: XML parsing (S3BackendTests.swift)

    @Test fun parseListPageWithContinuation() {
        val xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <ListBucketResult xmlns="http://s3.amazonaws.com/doc/2006-03-01/">
          <Name>mybucket</Name>
          <Prefix>notes/</Prefix>
          <KeyCount>2</KeyCount>
          <MaxKeys>2</MaxKeys>
          <IsTruncated>true</IsTruncated>
          <NextContinuationToken>1ueGcxLPRx1Tr/XYExHnhbYLgveDs2J/wm36Hy4vbOwM=</NextContinuationToken>
          <Contents>
            <Key>notes/a.md</Key>
            <LastModified>2009-10-12T17:50:30.000Z</LastModified>
            <ETag>&quot;fba9dede5f27731c9771645a39863328&quot;</ETag>
            <Size>434234</Size>
            <StorageClass>STANDARD</StorageClass>
          </Contents>
          <Contents>
            <Key>notes/Work/b &amp; c.md</Key>
            <LastModified>2009-10-12T17:50:31Z</LastModified>
            <ETag>"abc"</ETag>
            <Size>0</Size>
            <Owner><ID>owner</ID></Owner>
          </Contents>
        </ListBucketResult>
        """.trimIndent()
        val page = S3Client.parseListPage(xml.toByteArray())
        assertTrue(page.isTruncated)
        assertEquals("1ueGcxLPRx1Tr/XYExHnhbYLgveDs2J/wm36Hy4vbOwM=", page.nextContinuationToken)
        assertEquals(listOf("notes/a.md", "notes/Work/b & c.md"), page.objects.map { it.key })
        assertEquals(listOf("fba9dede5f27731c9771645a39863328", "abc"), page.objects.map { it.etag })
        assertEquals(listOf(434234L, 0L), page.objects.map { it.size })
        assertEquals(1_255_369_830L, page.objects[0].lastModified.epochSecond)
        assertEquals(1_255_369_831L, page.objects[1].lastModified.epochSecond)
    }

    @Test fun parseFinalListPage() {
        val page = S3Client.parseListPage("<ListBucketResult><IsTruncated>false</IsTruncated></ListBucketResult>".toByteArray())
        assertFalse(page.isTruncated)
        assertNull(page.nextContinuationToken)
        assertTrue(page.objects.isEmpty())
    }

    @Test fun parseListPageRejectsWrongDocument() {
        for (bad in listOf("<Error><Code>AccessDenied</Code><Message>Nope</Message></Error>", "not xml")) {
            try {
                S3Client.parseListPage(bad.toByteArray())
                fail("expected MalformedXML for $bad")
            } catch (e: S3ClientError.MalformedXML) {
                // expected
            }
        }
    }

    @Test fun parseErrorDocument() {
        val xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <Error>
          <Code>NoSuchKey</Code>
          <Message>The specified key does not exist.</Message>
          <Key>notes/a.md</Key>
          <RequestId>4442587FB7D0A2F9</RequestId>
        </Error>
        """.trimIndent()
        assertEquals(
            S3ClientError.Service(404, "NoSuchKey", "The specified key does not exist."),
            S3Client.error(404, xml.toByteArray()),
        )
    }

    @Test fun errorWithoutBodyFallsBackToHTTPStatus() {
        assertEquals(S3ClientError.Http(403), S3Client.error(403, ByteArray(0)))
        assertEquals(S3ClientError.Http(502), S3Client.error(502, "<html>bad gateway</html>".toByteArray()))
    }
}
