package com.thoughtqueue.app.sync

import org.junit.Assert.assertEquals
import org.junit.Test
import java.net.URI
import java.time.Instant

/**
 * SigV4 against published vectors. Expected values come from two sources only:
 * the desktop's `ThoughtQueueTests/S3BackendTests.swift` (which uses AWS's S3 "GET Object"
 * example from "Signature Calculations for the Authorization Header"), and the AWS SigV4 test
 * suite (`get-vanilla`, `get-vanilla-query-order-key-case`, as shipped in awslabs/aws-c-auth
 * `tests/aws-signing-test-suite/v4`).
 */
class SigV4Test {
    private val accessKey = "AKIAIOSFODNN7EXAMPLE"
    private val secretKey = "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY"

    /** 20130524T000000Z */
    private val exampleDate = Instant.ofEpochSecond(1_369_353_600)

    @Test fun dateFormatting() {
        assertEquals("20130524T000000Z", SigV4.amzDateString(exampleDate))
        assertEquals("20130524", SigV4.dateStamp(exampleDate))
    }

    @Test fun getObjectExampleIntermediateSteps() {
        val url = URI("https://examplebucket.s3.amazonaws.com/test.txt")
        val headers = mapOf(
            "Host" to "examplebucket.s3.amazonaws.com",
            "Range" to "bytes=0-9",
            "x-amz-content-sha256" to SigV4.EMPTY_PAYLOAD_HASH,
            "x-amz-date" to "20130524T000000Z",
        )
        val canonical = SigV4.canonicalRequest(SigV4.Request("GET", url, headers, SigV4.EMPTY_PAYLOAD_HASH))
        assertEquals(
            """
            GET
            /test.txt

            host:examplebucket.s3.amazonaws.com
            range:bytes=0-9
            x-amz-content-sha256:e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855
            x-amz-date:20130524T000000Z

            host;range;x-amz-content-sha256;x-amz-date
            e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855
            """.trimIndent(),
            canonical,
        )

        val scope = SigV4.credentialScope(exampleDate, "us-east-1", "s3")
        assertEquals("20130524/us-east-1/s3/aws4_request", scope)
        val toSign = SigV4.stringToSign(canonical, "20130524T000000Z", scope)
        assertEquals(
            """
            AWS4-HMAC-SHA256
            20130524T000000Z
            20130524/us-east-1/s3/aws4_request
            7344ae5b7ee6c3e7e6b0fe0640412a37625d1fbfff95c48bbb2dc43964946972
            """.trimIndent(),
            toSign,
        )
        assertEquals(
            "f0e8bdb87c964420e857bd35b5d6ed310bd44f0170aba48dd91039c6036bdb41",
            SigV4.signature(toSign, secretKey, exampleDate, "us-east-1", "s3"),
        )
    }

    @Test fun getObjectExampleFullSign() {
        val signed = SigV4.sign(
            method = "GET", url = URI("https://examplebucket.s3.amazonaws.com/test.txt"),
            headers = mapOf("Range" to "bytes=0-9"), payloadHash = SigV4.EMPTY_PAYLOAD_HASH,
            accessKey = accessKey, secretKey = secretKey, region = "us-east-1", date = exampleDate,
        )
        assertEquals(
            "AWS4-HMAC-SHA256 Credential=AKIAIOSFODNN7EXAMPLE/20130524/us-east-1/s3/aws4_request," +
                "SignedHeaders=host;range;x-amz-content-sha256;x-amz-date," +
                "Signature=f0e8bdb87c964420e857bd35b5d6ed310bd44f0170aba48dd91039c6036bdb41",
            signed["Authorization"],
        )
        assertEquals("20130524T000000Z", signed["x-amz-date"])
        assertEquals(SigV4.EMPTY_PAYLOAD_HASH, signed["x-amz-content-sha256"])
    }

    // MARK: AWS SigV4 test suite (service "service", us-east-1, 20150830T123600Z)

    private val suiteSecret = "wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY"
    private val suiteDate = Instant.parse("2015-08-30T12:36:00Z")

    /** Signs a suite request through the intermediate steps, the way the suite's files lay them out. */
    private fun suiteSignature(url: String, expectedCanonical: String): String {
        val headers = mapOf("Host" to "example.amazonaws.com", "X-Amz-Date" to "20150830T123600Z")
        val canonical = SigV4.canonicalRequest(SigV4.Request("GET", URI(url), headers, SigV4.EMPTY_PAYLOAD_HASH))
        assertEquals(expectedCanonical, canonical)
        val scope = SigV4.credentialScope(suiteDate, "us-east-1", "service")
        val toSign = SigV4.stringToSign(canonical, "20150830T123600Z", scope)
        return SigV4.signature(toSign, suiteSecret, suiteDate, "us-east-1", "service")
    }

    @Test fun awsSuiteGetVanilla() {
        val sig = suiteSignature(
            "https://example.amazonaws.com/",
            """
            GET
            /

            host:example.amazonaws.com
            x-amz-date:20150830T123600Z

            host;x-amz-date
            e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855
            """.trimIndent(),
        )
        assertEquals("5fa00fa31553b73ebf1942676e86291e8372ff2a2260956d9b8aae1d763fbf31", sig)
    }

    @Test fun awsSuiteGetVanillaQueryOrderKeyCase() {
        val sig = suiteSignature(
            "https://example.amazonaws.com/?Param2=value2&Param1=value1",
            """
            GET
            /
            Param1=value1&Param2=value2
            host:example.amazonaws.com
            x-amz-date:20150830T123600Z

            host;x-amz-date
            e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855
            """.trimIndent(),
        )
        assertEquals("b97d918cfa904a5beff61c982a1b6f458b799221646efd99d3219ec94cdf2500", sig)
    }

    // MARK: Canonicalization details (Swift vectors)

    @Test fun canonicalQuerySortsAndEncodes() {
        val url = URI("https://h/b?prefix=a%20b/c&list-type=2&continuation-token=x%2By%3D")
        assertEquals("continuation-token=x%2By%3D&list-type=2&prefix=a%20b%2Fc", SigV4.canonicalQueryString(url))
    }

    @Test fun canonicalURIEncodesSegmentsOnceAndKeepsSlashes() {
        assertEquals("/bucket/My%20Notes/caf%C3%A9%2Bx.md", SigV4.canonicalURI(URI("https://h/bucket/My%20Notes/caf%C3%A9+x.md")))
        assertEquals("/", SigV4.canonicalURI(URI("https://h")))
    }

    @Test fun hostHeaderKeepsNonDefaultPort() {
        assertEquals("localhost:9000", SigV4.hostHeader(URI("http://localhost:9000/b")))
        assertEquals("s3.amazonaws.com", SigV4.hostHeader(URI("https://s3.amazonaws.com:443/b")))
    }

    @Test fun uriEncodeUsesUppercaseHexAndUtf8() {
        assertEquals("a%20b%2Fc~-._%E2%98%95", SigV4.uriEncode("a b/c~-._☕"))
        assertEquals("a+b", SigV4.percentDecode("a+b"))
        assertEquals(null, SigV4.percentDecode("bad%zz"))
    }

    @Test fun headerValuesAreTrimmedAndCollapsed() {
        assertEquals("a:x y\nb:z\n", SigV4.canonicalHeaders(mapOf("B" to "z", "A" to "  x   y ")))
        assertEquals("a;b", SigV4.signedHeaders(mapOf("B" to "z", "A" to "x")))
    }
}
