package com.thoughtqueue.app.sync

import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import org.xml.sax.Attributes
import org.xml.sax.SAXException
import org.xml.sax.helpers.DefaultHandler
import java.io.ByteArrayInputStream
import java.io.IOException
import java.net.HttpURLConnection
import java.net.URI
import java.time.Instant
import java.time.format.DateTimeParseException
import javax.xml.parsers.ParserConfigurationException
import javax.xml.parsers.SAXParserFactory

/**
 * [ObjectStore] backed by an S3-compatible HTTP API, signed with SigV4. A port of the desktop's
 * `Sync/S3Client.swift`, on `HttpURLConnection` with no SDK. Every network call runs on
 * [Dispatchers.IO].
 */
class S3Client(
    val config: S3Config,
    private val secretKey: String,
    /** Signing clock; injectable for tests. */
    private val clock: () -> Instant = { Instant.now() },
) : ObjectStore {

    /** One page of a ListObjectsV2 response. Keys are full (prefix-included) bucket keys. */
    data class ListPage(
        val objects: List<RemoteObject>,
        val isTruncated: Boolean,
        val nextContinuationToken: String?,
    )

    /** A finished 2xx response: body plus the ETag header (quotes not yet stripped). */
    private class Response(val body: ByteArray, val etagHeader: String?)

    // MARK: ObjectStore

    /**
     * Lists objects under [prefix] (relative to the configured prefix) via ListObjectsV2,
     * following continuation tokens until the listing is complete.
     */
    override suspend fun list(prefix: String): List<RemoteObject> {
        val results = ArrayList<RemoteObject>()
        var token: String? = null
        do {
            val query = mutableListOf("list-type" to "2", "prefix" to config.fullKey(prefix))
            token?.let { query.add("continuation-token" to it) }
            val url = config.bucketURL(query) ?: throw S3ClientError.InvalidURL

            val page = parseListPage(send("GET", url).body)
            for (obj in page.objects) {
                val relative = config.relativeKey(obj.key) ?: continue
                results.add(obj.copy(key = relative))
            }
            if (page.isTruncated && page.nextContinuationToken == null) {
                throw S3ClientError.InvalidResponse("truncated listing without a continuation token")
            }
            token = if (page.isTruncated) page.nextContinuationToken else null
        } while (token != null)
        return results
    }

    /** Downloads an object and returns its body and ETag. */
    override suspend fun get(key: String): ObjectContent {
        val url = config.objectURL(key) ?: throw S3ClientError.InvalidURL
        val response = send("GET", url)
        val etag = response.etagHeader?.let(::stripQuotes)
            ?: throw S3ClientError.InvalidResponse("GET $key returned no ETag")
        return ObjectContent(response.body, etag)
    }

    /** Uploads an object and returns the ETag the service assigned. */
    override suspend fun put(key: String, data: ByteArray): String {
        val url = config.objectURL(key) ?: throw S3ClientError.InvalidURL
        val response = send("PUT", url, data)
        return response.etagHeader?.let(::stripQuotes)
            ?: throw S3ClientError.InvalidResponse("PUT $key returned no ETag")
    }

    /** Deletes an object. */
    override suspend fun delete(key: String) {
        val url = config.objectURL(key) ?: throw S3ClientError.InvalidURL
        send("DELETE", url)
    }

    /** Sends HeadBucket, which succeeds only if the bucket exists and the credentials can reach it. */
    override suspend fun testConnection() {
        val url = config.bucketURL() ?: throw S3ClientError.InvalidURL
        send("HEAD", url)
    }

    // MARK: Transport

    /**
     * Signs and sends one request on [Dispatchers.IO], returning the body and ETag for a 2xx
     * status and throwing a typed [S3ClientError] for anything else. Connection failures
     * surface as the underlying [IOException].
     */
    private suspend fun send(method: String, url: URI, body: ByteArray? = null): Response =
        withContext(Dispatchers.IO) {
            val payload = body ?: ByteArray(0)
            val signed = SigV4.sign(
                method = method, url = url, headers = emptyMap(),
                payloadHash = SigV4.sha256Hex(payload),
                accessKey = config.accessKeyId, secretKey = secretKey,
                region = config.region, date = clock(),
            )

            // The URI is fully percent-encoded ASCII, so URL does not re-encode it.
            val conn = url.toURL().openConnection() as HttpURLConnection
            try {
                conn.requestMethod = method
                conn.useCaches = false
                conn.instanceFollowRedirects = false
                conn.connectTimeout = TIMEOUT_MS
                conn.readTimeout = TIMEOUT_MS
                for ((name, value) in signed) conn.setRequestProperty(name, value)
                if (body != null) {
                    conn.doOutput = true
                    conn.setRequestProperty("Content-Type", "application/octet-stream")
                    conn.setFixedLengthStreamingMode(body.size)
                    conn.outputStream.use { it.write(body) }
                }

                val status = conn.responseCode
                val ok = status in 200..299
                val stream = if (ok) conn.inputStream else conn.errorStream
                val data = stream?.use { it.readBytes() } ?: ByteArray(0)
                if (!ok) throw error(status, data)
                Response(data, conn.getHeaderField("ETag"))
            } finally {
                conn.disconnect()
            }
        }

    companion object {
        private const val TIMEOUT_MS = 30_000

        // MARK: XML parsing (pure so it is testable without a network)

        /** Turns an error status and body into a typed error, using the S3 error document when present. */
        fun error(status: Int, body: ByteArray): S3ClientError {
            val parsed = parseErrorDocument(body)
            return if (parsed != null) S3ClientError.Service(status, parsed.first, parsed.second)
            else S3ClientError.Http(status)
        }

        /** Parses `<Error><Code>..</Code><Message>..</Message></Error>`, or null if the body is not one. */
        fun parseErrorDocument(data: ByteArray): Pair<String, String>? {
            if (data.isEmpty()) return null
            val collector = try {
                collect(data)
            } catch (e: Exception) {
                return null
            }
            if (collector.rootElement != "Error") return null
            val code = collector.errorCode ?: return null
            return code to (collector.errorMessage ?: "")
        }

        /** Parses one ListObjectsV2 result page. Keys are returned as full bucket keys. */
        fun parseListPage(data: ByteArray): ListPage {
            val collector = try {
                collect(data)
            } catch (e: SAXException) {
                throw S3ClientError.MalformedXML(e.message ?: "unknown parse error")
            } catch (e: IOException) {
                throw S3ClientError.MalformedXML(e.message ?: "unknown parse error")
            }
            if (collector.rootElement != "ListBucketResult") {
                throw S3ClientError.MalformedXML("expected ListBucketResult, got ${collector.rootElement ?: "nothing"}")
            }

            val objects = collector.contents.map { entry ->
                val key = entry["Key"] ?: throw S3ClientError.MalformedXML("object without Key")
                val modified = entry["LastModified"]?.let(::parseISO8601)
                    ?: throw S3ClientError.MalformedXML("bad LastModified for $key")
                val size = entry["Size"]?.toLongOrNull()
                    ?: throw S3ClientError.MalformedXML("bad Size for $key")
                RemoteObject(key, stripQuotes(entry["ETag"] ?: ""), modified, size)
            }
            val token = collector.nextContinuationToken?.ifEmpty { null }
            return ListPage(objects, collector.isTruncated == "true", token)
        }

        /**
         * Normalizes an ETag to its bare value: drops a weak `W/` prefix and surrounding quotes
         * and spaces. S3 returns `"abc"`, but a compressing proxy (Cloudflare gzips responses
         * and `HttpURLConnection` asks for gzip by default) serves GETs as `W/"abc"`. Without
         * this the GET ETag never matched the LIST ETag, so every downloaded note looked
         * remotely changed and deleting it was planned as a conflict.
         */
        fun stripQuotes(value: String): String {
            val trimmed = value.trim()
            val unweak = if (trimmed.startsWith("W/", ignoreCase = true)) trimmed.substring(2) else trimmed
            return unweak.trim { it == '"' || it == ' ' || it == '\t' }
        }

        /** Parses S3's ISO 8601 timestamps, with or without fractional seconds; null when invalid. */
        fun parseISO8601(text: String): Instant? = try {
            Instant.parse(text)
        } catch (e: DateTimeParseException) {
            null
        }

        /** Runs the SAX parser over [data] with DTDs disabled, returning what it collected. */
        private fun collect(data: ByteArray): XmlCollector {
            val factory = SAXParserFactory.newInstance()
            factory.isNamespaceAware = false
            // Best effort: not every platform parser recognizes these features.
            for (feature in listOf(
                "http://apache.org/xml/features/disallow-doctype-decl",
            )) {
                try {
                    factory.setFeature(feature, true)
                } catch (e: ParserConfigurationException) {
                    // Unsupported here; the parser still never fetches external entities for S3 bodies.
                } catch (e: SAXException) {
                    // Same as above.
                }
            }
            for (feature in listOf(
                "http://xml.org/sax/features/external-general-entities",
                "http://xml.org/sax/features/external-parameter-entities",
            )) {
                try {
                    factory.setFeature(feature, false)
                } catch (e: ParserConfigurationException) {
                    // Unsupported here.
                } catch (e: SAXException) {
                    // Unsupported here.
                }
            }
            val collector = XmlCollector()
            factory.newSAXParser().parse(ByteArrayInputStream(data), collector)
            return collector
        }
    }
}

/**
 * SAX handler that collects the handful of elements S3 responses carry. It handles both
 * ListBucketResult and Error documents, since both are shallow.
 */
private class XmlCollector : DefaultHandler() {
    var rootElement: String? = null
    val contents = ArrayList<Map<String, String>>()
    var isTruncated: String? = null
    var nextContinuationToken: String? = null
    var errorCode: String? = null
    var errorMessage: String? = null

    private val stack = ArrayList<String>()
    private val text = StringBuilder()
    private var currentObject: MutableMap<String, String>? = null

    /** Element name with any namespace prefix dropped. */
    private fun nameOf(localName: String?, qName: String?): String {
        val raw = if (!localName.isNullOrEmpty()) localName else qName.orEmpty()
        return raw.substringAfter(':')
    }

    /** Records the root element and starts a new object at each `<Contents>`. */
    override fun startElement(uri: String?, localName: String?, qName: String?, attributes: Attributes?) {
        val name = nameOf(localName, qName)
        if (rootElement == null) rootElement = name
        if (name == "Contents") currentObject = HashMap()
        stack.add(name)
        text.setLength(0)
    }

    /** Accumulates character data; the parser may deliver one value in several chunks. */
    override fun characters(ch: CharArray, start: Int, length: Int) {
        text.append(ch, start, length)
    }

    /** Stores the finished element's text according to where it sits in the document. */
    override fun endElement(uri: String?, localName: String?, qName: String?) {
        val name = nameOf(localName, qName)
        stack.removeAt(stack.size - 1)
        val parent = stack.lastOrNull()
        val value = text.toString().trim()

        val obj = currentObject
        when {
            name == "Contents" && obj != null -> {
                contents.add(obj)
                currentObject = null
            }
            parent == "Contents" -> obj?.put(name, value)
            parent == "ListBucketResult" && name == "IsTruncated" -> isTruncated = value
            parent == "ListBucketResult" && name == "NextContinuationToken" -> nextContinuationToken = value
            parent == "Error" && name == "Code" -> errorCode = value
            parent == "Error" && name == "Message" -> errorMessage = value
        }
        text.setLength(0)
    }
}
