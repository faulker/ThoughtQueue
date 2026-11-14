package com.thoughtqueue.app.sync

import java.net.URI
import java.net.URISyntaxException
import java.util.Locale

/**
 * Connection settings for an S3-compatible bucket (AWS S3, MinIO, RustFS, Cloudflare R2).
 * A port of the desktop's `Sync/S3Config.swift`.
 *
 * The secret key is deliberately not part of this class; it lives in the [SecretStore] and is
 * handed to [S3Client] separately.
 */
data class S3Config(
    /** Base service URL, e.g. `https://s3.us-east-1.amazonaws.com` or `http://localhost:9000`. */
    val endpoint: URI,
    val region: String,
    val bucket: String,
    /** Optional folder inside the bucket that all keys live under, e.g. `notes/`. */
    val keyPrefix: String,
    /**
     * Path-style (`endpoint/bucket/key`) is what MinIO and RustFS expect by default;
     * virtual-host style (`bucket.host/key`) is AWS's preferred form.
     */
    val usePathStyle: Boolean,
    val accessKeyId: String,
) {
    /** The prefix with leading slashes removed and exactly one trailing slash, or "" when unset. */
    val normalizedPrefix: String
        get() {
            val trimmed = keyPrefix.trim { it == '/' || it == ' ' || it == '\t' }
            return if (trimmed.isEmpty()) "" else "$trimmed/"
        }

    /** Returns the full bucket key for a key relative to the prefix. */
    fun fullKey(key: String): String = normalizedPrefix + key

    /** Strips the configured prefix from a full bucket key, or returns null if it is outside it. */
    fun relativeKey(fullKey: String): String? {
        val prefix = normalizedPrefix
        if (!fullKey.startsWith(prefix)) return null
        return fullKey.substring(prefix.length)
    }

    /**
     * Returns the URL of the bucket itself, with optional query items (used by ListObjectsV2
     * and HeadBucket). Query values are encoded with SigV4's strict rules so the URL that is
     * sent is exactly the one that was signed.
     */
    fun bucketURL(queryItems: List<Pair<String, String>> = emptyList()): URI? = url("", queryItems)

    /** Returns the URL of an object, given a key relative to the configured prefix. */
    fun objectURL(key: String): URI? {
        val encoded = fullKey(key).split("/").joinToString("/") { SigV4.uriEncode(it) }
        return url(encoded, emptyList())
    }

    /** Assembles a path-style or virtual-host URL for an already-encoded key path ("" for the bucket). */
    private fun url(encodedKeyPath: String, queryItems: List<Pair<String, String>>): URI? {
        val host = endpoint.host ?: return null
        val scheme = endpoint.scheme ?: return null
        if (bucket.isEmpty()) return null
        val basePath = endpoint.rawPath.orEmpty().trimEnd('/')

        val finalHost: String
        val path: String
        if (usePathStyle) {
            finalHost = host
            val bucketPath = basePath + "/" + SigV4.uriEncode(bucket)
            path = if (encodedKeyPath.isEmpty()) "$bucketPath/" else "$bucketPath/$encodedKeyPath"
        } else {
            finalHost = "$bucket.$host"
            path = "$basePath/$encodedKeyPath"
        }

        val sb = StringBuilder().append(scheme).append("://").append(finalHost)
        if (endpoint.port != -1) sb.append(':').append(endpoint.port)
        sb.append(path)
        if (queryItems.isNotEmpty()) {
            sb.append('?').append(
                queryItems.joinToString("&") { "${SigV4.uriEncode(it.first)}=${SigV4.uriEncode(it.second)}" },
            )
        }
        return try {
            URI(sb.toString())
        } catch (e: URISyntaxException) {
            null
        }
    }

    companion object {
        const val DEFAULT_REGION = "us-east-1"

        /**
         * Builds a config from raw field values, trimming whitespace, like the desktop's
         * `PreferencesManager.makeS3Config`. Returns null when the endpoint is not a valid
         * http(s) URL with a host, or the bucket or access key ID is empty. An empty region
         * means `us-east-1`.
         */
        fun make(
            endpoint: String,
            region: String,
            bucket: String,
            prefix: String,
            usePathStyle: Boolean,
            accessKeyId: String,
        ): S3Config? {
            val trimmedBucket = bucket.trim()
            val trimmedKeyId = accessKeyId.trim()
            val trimmedRegion = region.trim()
            val url = try {
                URI(endpoint.trim())
            } catch (e: URISyntaxException) {
                return null
            }
            val scheme = url.scheme?.lowercase(Locale.ROOT)
            if (scheme != "http" && scheme != "https") return null
            if (url.host == null || trimmedBucket.isEmpty() || trimmedKeyId.isEmpty()) return null
            return S3Config(
                endpoint = url,
                region = trimmedRegion.ifEmpty { DEFAULT_REGION },
                bucket = trimmedBucket,
                keyPrefix = prefix.trim(),
                usePathStyle = usePathStyle,
                accessKeyId = trimmedKeyId,
            )
        }
    }
}
