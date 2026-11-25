package com.thoughtqueue.app.update

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Ports of the desktop `UpdateService` tests: tag parsing, version order, checksum lookup,
 * and the asset URLs. The network call and the package install are not exercised here.
 */
class UpdateCheckTest {

    @Test fun parseVersionFromTagUrl() {
        val url = "https://github.com/faulker/ThoughtQueue/releases/tag/v1.2.3"
        assertEquals("1.2.3", UpdateCheck.parseVersion(url))
    }

    @Test fun parseVersionAcceptsBareTagWithoutVPrefix() {
        val url = "https://github.com/faulker/ThoughtQueue/releases/tag/1.2.3"
        assertEquals("1.2.3", UpdateCheck.parseVersion(url))
    }

    @Test fun parseVersionRejectsNonVersionUrls() {
        // GitHub redirects here when a repo has no releases at all.
        assertNull(UpdateCheck.parseVersion("https://github.com/faulker/ThoughtQueue/releases"))
        assertNull(UpdateCheck.parseVersion("https://github.com/faulker/ThoughtQueue/releases/tag/nightly"))
    }

    @Test fun isNewerComparesNumericallyNotLexically() {
        assertTrue(UpdateCheck.isNewer("1.10.0", "1.9.0"))
        assertFalse(UpdateCheck.isNewer("1.9.0", "1.10.0"))
    }

    @Test fun isNewerIsFalseForEqualVersions() {
        assertFalse(UpdateCheck.isNewer("1.0.0", "1.0.0"))
    }

    @Test fun isNewerIsFalseForOlderVersions() {
        assertFalse(UpdateCheck.isNewer("0.9.9", "1.0.0"))
    }

    @Test fun compareTreatsMissingComponentsAsZero() {
        assertEquals(0, UpdateCheck.compare("2.0", "2.0.0"))
        assertTrue(UpdateCheck.compare("2", "1.9.9") > 0)
    }

    @Test fun compareStripsPrereleaseAndBuildSuffixes() {
        assertEquals(0, UpdateCheck.compare("1.2.3-beta.1", "1.2.3"))
        assertEquals(0, UpdateCheck.compare("1.2.3+build9", "1.2.3"))
        assertTrue(UpdateCheck.isNewer("1.3.0-rc1", "1.2.3"))
    }

    /** The exact format the release workflow produces (shasum run from inside dist/). */
    private val checksums = """
        d975f870c534eeefb57710bfee3345a6fd8d87b25b6f8966d9d6d7d0f92f01ec  ./ThoughtQueue-1.0.0.dmg
        51be17b7a01e1e7abb1dc68faeafb466185902354e77b7216037a9cb8c9a1f0b  ./ThoughtQueue-1.0.0.zip
        """.trimIndent()

    @Test fun expectedSha256FindsAssetIgnoringDotSlashPrefix() {
        assertEquals(
            "51be17b7a01e1e7abb1dc68faeafb466185902354e77b7216037a9cb8c9a1f0b",
            UpdateCheck.expectedSha256("ThoughtQueue-1.0.0.zip", checksums),
        )
        assertEquals(
            "d975f870c534eeefb57710bfee3345a6fd8d87b25b6f8966d9d6d7d0f92f01ec",
            UpdateCheck.expectedSha256("ThoughtQueue-1.0.0.dmg", checksums),
        )
    }

    @Test fun expectedSha256ReturnsNullForUnlistedAsset() {
        assertNull(UpdateCheck.expectedSha256("ThoughtQueue-9.9.9.zip", checksums))
        assertNull(UpdateCheck.expectedSha256("ThoughtQueue-1.0.0.zip", ""))
    }

    @Test fun expectedSha256DoesNotPartialMatchFilenames() {
        // "Queue-1.0.0.zip" is a suffix of the listed name but is not the same asset.
        assertNull(UpdateCheck.expectedSha256("Queue-1.0.0.zip", checksums))
    }

    @Test fun expectedSha256HandlesBinaryMarkerAndSpacedNames() {
        val block = """
            aaaa1111  *ThoughtQueue-1.0.0.zip
            bbbb2222  ./My Build 1.0.0.zip
            """.trimIndent()
        assertEquals("aaaa1111", UpdateCheck.expectedSha256("ThoughtQueue-1.0.0.zip", block))
        assertEquals("bbbb2222", UpdateCheck.expectedSha256("My Build 1.0.0.zip", block))
    }

    @Test fun sha256MatchesKnownVector() {
        assertEquals(
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
            UpdateCheck.sha256Hex("abc".toByteArray()),
        )
    }

    @Test fun releaseUrlConstruction() {
        assertEquals(
            "https://github.com/faulker/ThoughtQueue/releases/latest",
            UpdateCheck.latestReleaseUrl(),
        )
        assertEquals(
            "https://github.com/faulker/ThoughtQueue/releases/download/v1.2.3/ThoughtQueue-1.2.3.apk",
            UpdateCheck.assetUrl("1.2.3", "ThoughtQueue-1.2.3.apk"),
        )
        assertEquals(
            "https://github.com/faulker/ThoughtQueue/releases/tag/v1.2.3",
            UpdateCheck.releasePageUrl("1.2.3"),
        )
    }

    @Test fun releasePointsAtTheSignedApk() {
        val release = UpdateCheck.Release("2.1.0")
        assertEquals("v2.1.0", release.tag)
        assertEquals("ThoughtQueue-2.1.0.apk", release.apkFilename)
        assertFalse(release.apkFilename.contains("unsigned"))
        assertTrue(release.apkUrl.endsWith("/v2.1.0/ThoughtQueue-2.1.0.apk"))
        assertTrue(release.checksumsUrl.endsWith("/v2.1.0/checksums-sha256.txt"))
        assertEquals(
            "https://github.com/faulker/ThoughtQueue/releases/tag/v2.1.0",
            release.pageUrl,
        )
    }
}
