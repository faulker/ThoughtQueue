package com.thoughtqueue.app.sync

import java.io.ByteArrayOutputStream
import java.net.URI
import java.security.MessageDigest
import java.time.Instant
import java.time.ZoneOffset
import java.time.format.DateTimeFormatter
import java.util.Locale
import javax.crypto.Mac
import javax.crypto.spec.SecretKeySpec

/**
 * AWS Signature Version 4 signer for S3 requests, as pure functions so every step is testable.
 * A port of the desktop's `Sync/SigV4.swift`.
 *
 * The flow follows AWS's "Signature Calculations for the Authorization Header" document:
 * canonical request, then string to sign, then an HMAC-SHA256 chain that derives the signing
 * key from the secret, date, region and service. S3 differs from other services in that the
 * path is URI-encoded exactly once (each segment encoded, '/' kept) rather than twice.
 */
object SigV4 {
    const val ALGORITHM = "AWS4-HMAC-SHA256"

    /** SHA256 of an empty body, used for GET, HEAD and DELETE. */
    val EMPTY_PAYLOAD_HASH: String = sha256Hex(ByteArray(0))

    /**
     * The fields of a request that SigV4 canonicalizes. [headers] are the headers to sign;
     * [sign] adds `host`, `x-amz-date` and `x-amz-content-sha256` itself.
     */
    data class Request(
        val method: String,
        val url: URI,
        val headers: Map<String, String>,
        val payloadHash: String,
    )

    private val AMZ_DATE: DateTimeFormatter =
        DateTimeFormatter.ofPattern("yyyyMMdd'T'HHmmss'Z'", Locale.ROOT).withZone(ZoneOffset.UTC)
    private val DATE_STAMP: DateTimeFormatter =
        DateTimeFormatter.ofPattern("yyyyMMdd", Locale.ROOT).withZone(ZoneOffset.UTC)

    /**
     * Signs a request and returns the headers to add to it: `Authorization`, `x-amz-date` and
     * `x-amz-content-sha256`. The caller must also send every header it passed in [headers],
     * unchanged, or the server's signature will not match.
     */
    fun sign(
        method: String,
        url: URI,
        headers: Map<String, String>,
        payloadHash: String,
        accessKey: String,
        secretKey: String,
        region: String,
        service: String = "s3",
        date: Instant,
    ): Map<String, String> {
        val amzDate = amzDateString(date)
        val all = HashMap(headers)
        all["host"] = hostHeader(url)
        all["x-amz-date"] = amzDate
        all["x-amz-content-sha256"] = payloadHash
        val request = Request(method, url, all, payloadHash)

        val scope = credentialScope(date, region, service)
        val canonical = canonicalRequest(request)
        val toSign = stringToSign(canonical, amzDate, scope)
        val sig = signature(toSign, secretKey, date, region, service)
        val authorization = "$ALGORITHM Credential=$accessKey/$scope," +
            "SignedHeaders=${signedHeaders(request.headers)},Signature=$sig"

        return linkedMapOf(
            "Authorization" to authorization,
            "x-amz-date" to amzDate,
            "x-amz-content-sha256" to payloadHash,
        )
    }

    // MARK: Intermediate steps

    /**
     * Builds the canonical request: method, canonical URI, canonical query string, canonical
     * headers, signed header list and payload hash, joined by newlines.
     */
    fun canonicalRequest(request: Request): String = listOf(
        request.method.uppercase(Locale.ROOT),
        canonicalURI(request.url),
        canonicalQueryString(request.url),
        canonicalHeaders(request.headers),
        signedHeaders(request.headers),
        request.payloadHash,
    ).joinToString("\n")

    /** Builds the string to sign from the canonical request, timestamp and credential scope. */
    fun stringToSign(canonicalRequest: String, amzDate: String, scope: String): String = listOf(
        ALGORITHM,
        amzDate,
        scope,
        sha256Hex(canonicalRequest.toByteArray(Charsets.UTF_8)),
    ).joinToString("\n")

    /** Derives the signing key and returns the lowercase hex HMAC of the string to sign. */
    fun signature(stringToSign: String, secretKey: String, date: Instant, region: String, service: String): String {
        val key = signingKey(secretKey, date, region, service)
        return hex(hmac(key, stringToSign))
    }

    /** Derives the SigV4 signing key: HMAC chain over date, region, service and "aws4_request". */
    fun signingKey(secretKey: String, date: Instant, region: String, service: String): ByteArray {
        var key = "AWS4$secretKey".toByteArray(Charsets.UTF_8)
        for (part in listOf(dateStamp(date), region, service, "aws4_request")) {
            key = hmac(key, part)
        }
        return key
    }

    /** Returns the credential scope, `yyyyMMdd/region/service/aws4_request`. */
    fun credentialScope(date: Instant, region: String, service: String): String =
        "${dateStamp(date)}/$region/$service/aws4_request"

    /** Returns the URL path with each segment URI-encoded once and '/' kept. An empty path is "/". */
    fun canonicalURI(url: URI): String {
        val raw = url.rawPath.orEmpty()
        if (raw.isEmpty()) return "/"
        // Decode first so an already-encoded path is not double-encoded (S3 rule).
        return raw.split("/").joinToString("/") { uriEncode(percentDecode(it) ?: it) }
    }

    /**
     * Returns the query parameters URI-encoded and sorted by name then value, joined with '&'.
     * A parameter without a value is emitted as `name=`.
     */
    fun canonicalQueryString(url: URI): String {
        val query = url.rawQuery ?: return ""
        if (query.isEmpty()) return ""
        val pairs = query.split("&").map { item ->
            val eq = item.indexOf('=')
            val name = if (eq < 0) item else item.substring(0, eq)
            val value = if (eq < 0) "" else item.substring(eq + 1)
            uriEncode(percentDecode(name) ?: name) to uriEncode(percentDecode(value) ?: value)
        }
        return pairs
            .sortedWith(compareBy<Pair<String, String>> { it.first }.thenBy { it.second })
            .joinToString("&") { "${it.first}=${it.second}" }
    }

    /**
     * Returns `name:value\n` lines for every header, names lowercased and sorted, values
     * trimmed with runs of spaces collapsed. Ends with a newline, as SigV4 requires.
     */
    fun canonicalHeaders(headers: Map<String, String>): String =
        normalizedHeaders(headers).joinToString("") { "${it.first}:${it.second}\n" }

    /** Returns the sorted, lowercased header names joined with ';'. */
    fun signedHeaders(headers: Map<String, String>): String =
        normalizedHeaders(headers).joinToString(";") { it.first }

    // MARK: Encoding and formatting

    /**
     * Percent-encodes everything except the RFC 3986 unreserved set (A-Z a-z 0-9 - . _ ~),
     * with uppercase hex, which is what SigV4 and S3 expect. Works on UTF-8 bytes.
     */
    fun uriEncode(string: String): String {
        val out = StringBuilder()
        for (b in string.toByteArray(Charsets.UTF_8)) {
            val byte = b.toInt() and 0xFF
            val unreserved = byte in 0x41..0x5A || byte in 0x61..0x7A || byte in 0x30..0x39 ||
                byte == 0x2D || byte == 0x2E || byte == 0x5F || byte == 0x7E
            if (unreserved) out.append(byte.toChar()) else out.append(String.format(Locale.ROOT, "%%%02X", byte))
        }
        return out.toString()
    }

    /**
     * Decodes `%XX` escapes as UTF-8, leaving '+' alone (unlike URLDecoder). Returns null for a
     * malformed escape or invalid UTF-8, matching Swift's `removingPercentEncoding`.
     */
    fun percentDecode(s: String): String? {
        if (!s.contains('%')) return s
        val out = ByteArrayOutputStream()
        var i = 0
        while (i < s.length) {
            val c = s[i]
            if (c == '%') {
                if (i + 2 >= s.length) return null
                val hi = Character.digit(s[i + 1], 16)
                val lo = Character.digit(s[i + 2], 16)
                if (hi < 0 || lo < 0) return null
                out.write(hi * 16 + lo)
                i += 3
            } else {
                out.write(c.toString().toByteArray(Charsets.UTF_8))
                i++
            }
        }
        val bytes = out.toByteArray()
        val decoder = Charsets.UTF_8.newDecoder()
        return try {
            decoder.decode(java.nio.ByteBuffer.wrap(bytes)).toString()
        } catch (e: java.nio.charset.CharacterCodingException) {
            null
        }
    }

    /** Returns the `Host` header value: the URL host plus the port when it is not the default. */
    fun hostHeader(url: URI): String {
        val host = url.host.orEmpty()
        val port = url.port
        if (port == -1) return host
        val isDefault = (url.scheme == "https" && port == 443) || (url.scheme == "http" && port == 80)
        return if (isDefault) host else "$host:$port"
    }

    /** Formats a date as `yyyyMMdd'T'HHmmss'Z'` in UTC. */
    fun amzDateString(date: Instant): String = AMZ_DATE.format(date)

    /** Formats a date as `yyyyMMdd` in UTC. */
    fun dateStamp(date: Instant): String = DATE_STAMP.format(date)

    /** Returns the lowercase hex SHA256 of the data. */
    fun sha256Hex(data: ByteArray): String = hex(MessageDigest.getInstance("SHA-256").digest(data))

    /** Lowercase hex encoding of raw bytes. */
    fun hex(data: ByteArray): String {
        val sb = StringBuilder(data.size * 2)
        for (b in data) sb.append(String.format(Locale.ROOT, "%02x", b.toInt() and 0xFF))
        return sb.toString()
    }

    /** HMAC-SHA256 of [message] (UTF-8) under [key]. */
    private fun hmac(key: ByteArray, message: String): ByteArray {
        val mac = Mac.getInstance("HmacSHA256")
        mac.init(SecretKeySpec(key, "HmacSHA256"))
        return mac.doFinal(message.toByteArray(Charsets.UTF_8))
    }

    /** Lowercases names, trims values, collapses repeated spaces, and sorts by name. */
    private fun normalizedHeaders(headers: Map<String, String>): List<Pair<String, String>> =
        headers.map { (name, value) ->
            val trimmed = value.trim(' ', '\t')
            val collapsed = trimmed.split(' ').filter { it.isNotEmpty() }.joinToString(" ")
            name.lowercase(Locale.ROOT) to collapsed
        }.sortedBy { it.first }
}
