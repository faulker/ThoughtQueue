package com.thoughtqueue.app.update

import java.io.File
import java.io.IOException
import java.net.HttpURLConnection
import java.net.URI
import java.security.MessageDigest

/**
 * Downloads a GitHub release without the GitHub API. The version check is a HEAD against
 * `/releases/latest`; the APK is hashed while it is written and kept only when the hash matches
 * `checksums-sha256.txt`. Redirects are followed by hand because a HEAD through
 * `HttpURLConnection` does not reliably expose the final tag URL.
 */
class UpdateClient {
    /**
     * Version name of the newest published release, from the redirect off [UpdateCheck.latestReleaseUrl].
     * Throws [UpdateError] or [IOException].
     */
    fun latestVersion(): String {
        val opened = connect(UpdateCheck.latestReleaseUrl(), "HEAD")
        opened.conn.disconnect()
        return UpdateCheck.parseVersion(opened.url) ?: throw UpdateError.UnreadableVersion()
    }

    /**
     * Downloads [release]'s signed APK to [dest] after checking it against the published checksum.
     * Deletes [dest] if the hash does not match or the transfer fails.
     */
    fun downloadVerifiedApk(release: UpdateCheck.Release, dest: File) {
        val name = release.apkFilename
        val expected = UpdateCheck.expectedSha256(name, downloadText(release.checksumsUrl))
            ?: throw UpdateError.ChecksumMissing(name)
        dest.parentFile?.mkdirs()
        try {
            val actual = downloadFile(release.apkUrl, dest)
            if (!actual.equals(expected, ignoreCase = true)) {
                throw UpdateError.ChecksumMismatch(expected, actual)
            }
        } catch (e: Exception) {
            dest.delete()
            throw e
        }
    }

    /** GET [url] and return the body as UTF-8 text. */
    private fun downloadText(url: String): String {
        val opened = connect(url, "GET")
        try {
            return opened.conn.inputStream.bufferedReader().use { it.readText() }
        } finally {
            opened.conn.disconnect()
        }
    }

    /** GET [url] into [dest], returning the lowercase hex SHA-256 of the bytes written. */
    private fun downloadFile(url: String, dest: File): String {
        val opened = connect(url, "GET")
        try {
            val digest = MessageDigest.getInstance("SHA-256")
            dest.outputStream().use { out ->
                opened.conn.inputStream.use { input ->
                    val buf = ByteArray(8192)
                    while (true) {
                        val n = input.read(buf)
                        if (n < 0) break
                        digest.update(buf, 0, n)
                        out.write(buf, 0, n)
                    }
                }
            }
            return UpdateCheck.toHex(digest.digest())
        } finally {
            opened.conn.disconnect()
        }
    }

    /** One response after redirects, still open so the caller can read the body. */
    private class Opened(val url: String, val conn: HttpURLConnection)

    /**
     * Opens [start] and follows up to [MAX_REDIRECTS] `Location` headers. The returned connection
     * is the first non-redirect response, and [Opened.url] is the URL that produced it.
     */
    private fun connect(start: String, method: String): Opened {
        var current = start
        repeat(MAX_REDIRECTS) {
            val conn = open(current, method)
            val code = try {
                conn.responseCode
            } catch (e: IOException) {
                conn.disconnect()
                throw e
            }
            if (code in 300..399) {
                val next = conn.getHeaderField("Location")
                conn.disconnect()
                if (next.isNullOrBlank()) throw UpdateError.BadResponse()
                current = resolve(current, next)
                return@repeat
            }
            if (code !in 200..299) {
                conn.disconnect()
                throw UpdateError.BadResponse()
            }
            return Opened(current, conn)
        }
        throw UpdateError.BadResponse()
    }

    /** A connection that does not follow redirects itself, so [connect] can record each hop. */
    private fun open(url: String, method: String): HttpURLConnection {
        val conn = (URI(url).toURL().openConnection() as HttpURLConnection)
        conn.requestMethod = method
        conn.instanceFollowRedirects = false
        conn.useCaches = false
        conn.connectTimeout = 20_000
        conn.readTimeout = if (method == "HEAD") 20_000 else 120_000
        conn.setRequestProperty("User-Agent", USER_AGENT)
        conn.setRequestProperty("Accept-Encoding", "identity")
        return conn
    }

    /** Turns a relative `Location` into an absolute URL. Absolute locations pass through. */
    private fun resolve(base: String, location: String): String {
        if (location.startsWith("https://") || location.startsWith("http://")) return location
        return URI(base).resolve(location).toString()
    }

    private companion object {
        const val USER_AGENT = "ThoughtQueue"
        const val MAX_REDIRECTS = 5
    }
}
