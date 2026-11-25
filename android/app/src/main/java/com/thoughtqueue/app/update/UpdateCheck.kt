package com.thoughtqueue.app.update

import java.net.URI
import java.security.MessageDigest

/**
 * Pure decision-making for the GitHub release check: URLs, version ordering, and the
 * `checksums-sha256.txt` lookup. No Android or network calls, so the unit tests run on the JVM.
 * The rules match the desktop `UpdateService`.
 */
object UpdateCheck {
    /** Owner/repo the releases are published under. */
    const val REPO_SLUG = "faulker/ThoughtQueue"

    /** Package id a sideloaded release is installed as. Suffix builds are not updated. */
    const val PACKAGE_NAME = "com.thoughtqueue.app"

    /** Quiet launch checks run at most this often. */
    const val CHECK_INTERVAL_MILLIS = 24L * 60 * 60 * 1000

    /** Asset name of the checksum file on every release. */
    const val CHECKSUMS_FILENAME = "checksums-sha256.txt"

    /** A release newer than what is running, and the assets the installer downloads. */
    data class Release(val version: String) {
        /** Git tag, including the `v` prefix. */
        val tag: String get() = "v$version"

        /** Signed APK asset. The unsigned fallback is a different filename and is never used. */
        val apkFilename: String get() = "ThoughtQueue-$version.apk"

        /** Download URL for [apkFilename]. */
        val apkUrl: String get() = assetUrl(version, apkFilename)

        /** Download URL for the release checksum file. */
        val checksumsUrl: String get() = assetUrl(version, CHECKSUMS_FILENAME)

        /** Human page for this tag. */
        val pageUrl: String get() = releasePageUrl(version)
    }

    /** Public latest-release URL. A HEAD follows its redirect to the newest tag. */
    fun latestReleaseUrl(): String = "https://github.com/$REPO_SLUG/releases/latest"

    /** Release page for [version] (no `v` prefix). */
    fun releasePageUrl(version: String): String = "https://github.com/$REPO_SLUG/releases/tag/v$version"

    /** Direct download URL for one asset on the [version] release. */
    fun assetUrl(version: String, filename: String): String =
        "https://github.com/$REPO_SLUG/releases/download/v$version/$filename"

    /**
     * Pulls "1.2.3" out of a `.../releases/tag/v1.2.3` URL. Returns null when the last path
     * segment is not version-shaped, which is how a redirect to the releases index (no
     * releases published yet) is rejected.
     */
    fun parseVersion(tagUrl: String): String? {
        val path = try {
            URI(tagUrl).path
        } catch (e: Exception) {
            return null
        } ?: return null
        var component = path.trimEnd('/').substringAfterLast('/')
        if (component.startsWith("v") || component.startsWith("V")) component = component.drop(1)
        val first = component.split('.').firstOrNull() ?: return null
        if (first.isEmpty() || !first.all { it.isDigit() }) return null
        return component
    }

    /**
     * Compares dotted versions numerically, so 1.10.0 sorts above 1.9.0. Missing components
     * count as zero (2.0 == 2.0.0). A `-prerelease` or `+build` suffix is dropped first.
     * Negative means [lhs] is older, zero means equal, positive means [lhs] is newer.
     */
    fun compare(lhs: String, rhs: String): Int {
        val left = numericComponents(lhs)
        val right = numericComponents(rhs)
        for (index in 0 until maxOf(left.size, right.size)) {
            val l = left.getOrElse(index) { 0 }
            val r = right.getOrElse(index) { 0 }
            if (l < r) return -1
            if (l > r) return 1
        }
        return 0
    }

    /** True when [candidate] is a strictly newer version than [current]. */
    fun isNewer(candidate: String, than: String): Boolean = compare(candidate, than) > 0

    /**
     * Looks up [filename] in a `shasum -a 256` block. The release workflow runs shasum from
     * inside `dist/`, so paths may start with `./`, and binary mode adds a leading `*`.
     * Everything after the hash is the name, so a filename containing spaces still matches.
     */
    fun expectedSha256(filename: String, checksums: String): String? {
        for (line in checksums.split('\n')) {
            val trimmed = line.trim()
            val separator = trimmed.indexOfFirst { it == ' ' || it == '\t' }
            if (separator <= 0) continue
            val hash = trimmed.substring(0, separator)
            var name = trimmed.substring(separator).trim()
            if (name.startsWith("*")) name = name.drop(1)
            if (name.startsWith("./")) name = name.drop(2)
            if (name == filename && hash.isNotEmpty()) return hash.lowercase()
        }
        return null
    }

    /** Lowercase hex SHA-256 of [data]. */
    fun sha256Hex(data: ByteArray): String =
        toHex(MessageDigest.getInstance("SHA-256").digest(data))

    /** Lowercase hex of an already-computed digest. */
    fun toHex(digest: ByteArray): String = digest.joinToString("") { "%02x".format(it) }

    /** Numeric pieces of a version, ignoring a prerelease or build suffix and trailing junk. */
    private fun numericComponents(version: String): List<Int> {
        val core = version.takeWhile { it != '-' && it != '+' }
        return core.split('.').map { part -> part.takeWhile { it.isDigit() }.toIntOrNull() ?: 0 }
    }
}

/** A failure with a message safe to show in Settings. */
sealed class UpdateError(message: String) : Exception(message) {
    /** GitHub responded, but not with a release we can use. */
    class BadResponse : UpdateError("GitHub did not return a usable response.")

    /** The redirect target was not a version tag. */
    class UnreadableVersion : UpdateError("Could not read the latest version number from GitHub.")

    /** `checksums-sha256.txt` has no line for this asset (the signed APK was not published). */
    class ChecksumMissing(name: String) : UpdateError("The release has no published checksum for $name.")

    /** The downloaded bytes do not match the published hash. */
    class ChecksumMismatch(val expected: String, val got: String) : UpdateError(
        "The download did not match its published checksum.\nExpected $expected\nGot $got",
    )

    /** The APK's signer is not the certificate this install was signed with. */
    class CertificateMismatch : UpdateError(
        "The download is signed with a different certificate than this install.",
    )

    /** PackageManager did not return a certificate for the APK or for this install. */
    class CertificateUnreadable : UpdateError("Could not read the download's signing certificate.")
}
