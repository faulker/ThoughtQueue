import XCTest
@testable import ThoughtQueue

/// Covers the S3 backend pieces that need no network: SigV4 against AWS's published S3
/// example, ListObjectsV2 and error XML parsing, URL building, the Keychain wrapper, and the
/// in-memory `ObjectStore` fake the sync engine tests rely on.
final class S3BackendTests: XCTestCase {

    // MARK: - SigV4 (AWS "Signature Calculations for the Authorization Header", S3 examples)

    private let accessKey = "AKIAIOSFODNN7EXAMPLE"
    private let secretKey = "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY"
    /// 20130524T000000Z
    private let exampleDate = Date(timeIntervalSince1970: 1_369_353_600)

    func testDateFormatting() {
        XCTAssertEqual(SigV4.amzDateString(exampleDate), "20130524T000000Z")
        XCTAssertEqual(SigV4.dateStamp(exampleDate), "20130524")
    }

    func testGetObjectExampleIntermediateSteps() {
        let url = URL(string: "https://examplebucket.s3.amazonaws.com/test.txt")!
        let headers = [
            "Host": "examplebucket.s3.amazonaws.com",
            "Range": "bytes=0-9",
            "x-amz-content-sha256": SigV4.emptyPayloadHash,
            "x-amz-date": "20130524T000000Z",
        ]
        let request = SigV4.Request(method: "GET", url: url, headers: headers, payloadHash: SigV4.emptyPayloadHash)
        let canonical = SigV4.canonicalRequest(request)
        XCTAssertEqual(canonical, """
        GET
        /test.txt

        host:examplebucket.s3.amazonaws.com
        range:bytes=0-9
        x-amz-content-sha256:e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855
        x-amz-date:20130524T000000Z

        host;range;x-amz-content-sha256;x-amz-date
        e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855
        """)

        let scope = SigV4.credentialScope(date: exampleDate, region: "us-east-1", service: "s3")
        XCTAssertEqual(scope, "20130524/us-east-1/s3/aws4_request")
        let toSign = SigV4.stringToSign(canonicalRequest: canonical, amzDate: "20130524T000000Z", scope: scope)
        XCTAssertEqual(toSign, """
        AWS4-HMAC-SHA256
        20130524T000000Z
        20130524/us-east-1/s3/aws4_request
        7344ae5b7ee6c3e7e6b0fe0640412a37625d1fbfff95c48bbb2dc43964946972
        """)

        let signature = SigV4.signature(stringToSign: toSign, secretKey: secretKey, date: exampleDate,
                                        region: "us-east-1", service: "s3")
        XCTAssertEqual(signature, "f0e8bdb87c964420e857bd35b5d6ed310bd44f0170aba48dd91039c6036bdb41")
    }

    func testGetObjectExampleFullSign() {
        let url = URL(string: "https://examplebucket.s3.amazonaws.com/test.txt")!
        let signed = SigV4.sign(method: "GET", url: url, headers: ["Range": "bytes=0-9"],
                                payloadHash: SigV4.emptyPayloadHash, accessKey: accessKey, secretKey: secretKey,
                                region: "us-east-1", date: exampleDate)
        XCTAssertEqual(signed["Authorization"],
                       "AWS4-HMAC-SHA256 Credential=AKIAIOSFODNN7EXAMPLE/20130524/us-east-1/s3/aws4_request,"
                       + "SignedHeaders=host;range;x-amz-content-sha256;x-amz-date,"
                       + "Signature=f0e8bdb87c964420e857bd35b5d6ed310bd44f0170aba48dd91039c6036bdb41")
        XCTAssertEqual(signed["x-amz-date"], "20130524T000000Z")
        XCTAssertEqual(signed["x-amz-content-sha256"], SigV4.emptyPayloadHash)
    }

    func testCanonicalQuerySortsAndEncodes() {
        let url = URL(string: "https://h/b?prefix=a%20b/c&list-type=2&continuation-token=x%2By%3D")!
        XCTAssertEqual(SigV4.canonicalQueryString(url), "continuation-token=x%2By%3D&list-type=2&prefix=a%20b%2Fc")
    }

    func testCanonicalURIEncodesSegmentsOnceAndKeepsSlashes() {
        let url = URL(string: "https://h/bucket/My%20Notes/caf%C3%A9+x.md")!
        XCTAssertEqual(SigV4.canonicalURI(url), "/bucket/My%20Notes/caf%C3%A9%2Bx.md")
        XCTAssertEqual(SigV4.canonicalURI(URL(string: "https://h")!), "/")
    }

    func testHostHeaderKeepsNonDefaultPort() {
        XCTAssertEqual(SigV4.hostHeader(for: URL(string: "http://localhost:9000/b")!), "localhost:9000")
        XCTAssertEqual(SigV4.hostHeader(for: URL(string: "https://s3.amazonaws.com:443/b")!), "s3.amazonaws.com")
    }

    // MARK: - URL building

    private func config(pathStyle: Bool, prefix: String = "notes") -> S3Config {
        S3Config(endpoint: URL(string: "https://s3.example.com")!, region: "us-east-1", bucket: "mybucket",
                 keyPrefix: prefix, usePathStyle: pathStyle, accessKeyID: "AK")
    }

    func testPathStyleObjectURLHonorsPrefix() {
        let url = config(pathStyle: true).objectURL(forKey: "Work/My Note.md")
        XCTAssertEqual(url?.absoluteString, "https://s3.example.com/mybucket/notes/Work/My%20Note.md")
    }

    func testVirtualHostObjectURLHonorsPrefix() {
        let url = config(pathStyle: false).objectURL(forKey: "Work/My Note.md")
        XCTAssertEqual(url?.absoluteString, "https://mybucket.s3.example.com/notes/Work/My%20Note.md")
    }

    func testPrefixIsNormalizedAndOptional() {
        XCTAssertEqual(config(pathStyle: true, prefix: "/a/b/").normalizedPrefix, "a/b/")
        XCTAssertEqual(config(pathStyle: true, prefix: "").objectURL(forKey: "x.md")?.absoluteString,
                       "https://s3.example.com/mybucket/x.md")
        XCTAssertEqual(config(pathStyle: true).relativeKey(fromFullKey: "notes/x.md"), "x.md")
        XCTAssertNil(config(pathStyle: true).relativeKey(fromFullKey: "other/x.md"))
    }

    func testBucketURLWithPortAndQuery() {
        var cfg = config(pathStyle: true)
        cfg.endpoint = URL(string: "http://localhost:9000")!
        let url = cfg.bucketURL(queryItems: [URLQueryItem(name: "list-type", value: "2"),
                                             URLQueryItem(name: "prefix", value: "notes/")])
        XCTAssertEqual(url?.absoluteString, "http://localhost:9000/mybucket/?list-type=2&prefix=notes%2F")
        XCTAssertEqual(config(pathStyle: false).bucketURL()?.absoluteString, "https://mybucket.s3.example.com/")
    }

    // MARK: - XML parsing

    func testParseListPageWithContinuation() throws {
        let xml = """
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
        """
        let page = try S3Client.parseListPage(Data(xml.utf8))
        XCTAssertTrue(page.isTruncated)
        XCTAssertEqual(page.nextContinuationToken, "1ueGcxLPRx1Tr/XYExHnhbYLgveDs2J/wm36Hy4vbOwM=")
        XCTAssertEqual(page.objects.map(\.key), ["notes/a.md", "notes/Work/b & c.md"])
        XCTAssertEqual(page.objects.map(\.etag), ["fba9dede5f27731c9771645a39863328", "abc"])
        XCTAssertEqual(page.objects.map(\.size), [434234, 0])
        XCTAssertEqual(page.objects[0].lastModified.timeIntervalSince1970, 1_255_369_830, accuracy: 0.001)
        XCTAssertEqual(page.objects[1].lastModified.timeIntervalSince1970, 1_255_369_831, accuracy: 0.001)
    }

    func testParseFinalListPage() throws {
        let xml = """
        <ListBucketResult><IsTruncated>false</IsTruncated></ListBucketResult>
        """
        let page = try S3Client.parseListPage(Data(xml.utf8))
        XCTAssertFalse(page.isTruncated)
        XCTAssertNil(page.nextContinuationToken)
        XCTAssertTrue(page.objects.isEmpty)
    }

    func testParseListPageRejectsWrongDocument() {
        let xml = "<Error><Code>AccessDenied</Code><Message>Nope</Message></Error>"
        XCTAssertThrowsError(try S3Client.parseListPage(Data(xml.utf8)))
        XCTAssertThrowsError(try S3Client.parseListPage(Data("not xml".utf8)))
    }

    func testParseErrorDocument() {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <Error>
          <Code>NoSuchKey</Code>
          <Message>The specified key does not exist.</Message>
          <Key>notes/a.md</Key>
          <RequestId>4442587FB7D0A2F9</RequestId>
        </Error>
        """
        XCTAssertEqual(S3Client.error(status: 404, body: Data(xml.utf8)),
                       .service(status: 404, code: "NoSuchKey", message: "The specified key does not exist."))
    }

    func testErrorWithoutBodyFallsBackToHTTPStatus() {
        XCTAssertEqual(S3Client.error(status: 403, body: Data()), .http(status: 403))
        XCTAssertEqual(S3Client.error(status: 502, body: Data("<html>bad gateway</html>".utf8)), .http(status: 502))
    }

    // MARK: - Keychain

    func testKeychainRoundTrip() throws {
        let store = KeychainStore(service: "com.thoughtqueue.tests.\(UUID().uuidString)")
        let account = "test-account"
        defer { try? store.delete(account: account) }

        XCTAssertNil(try store.load(account: account))
        try store.save("first-secret", account: account)
        XCTAssertEqual(try store.load(account: account), "first-secret")
        try store.save("second-secret", account: account)
        XCTAssertEqual(try store.load(account: account), "second-secret")
        try store.delete(account: account)
        XCTAssertNil(try store.load(account: account))
        XCTAssertNoThrow(try store.delete(account: account))
    }

    // MARK: - In-memory store

    func testInMemoryObjectStoreBehavesLikeS3() async throws {
        let store = InMemoryObjectStore()
        let etag = try await store.put(key: "a/x.md", data: Data("hello".utf8))
        XCTAssertEqual(etag, "5d41402abc4b2a76b9719d911017c592")
        _ = try await store.put(key: "b.md", data: Data())

        let listed = try await store.list(prefix: "a/")
        XCTAssertEqual(listed.map(\.key), ["a/x.md"])
        XCTAssertEqual(listed.first?.etag, etag)

        let fetched = try await store.get(key: "a/x.md")
        XCTAssertEqual(fetched, ObjectContent(data: Data("hello".utf8), etag: etag))

        try await store.delete(key: "a/x.md")
        try await store.delete(key: "missing")
        do {
            _ = try await store.get(key: "a/x.md")
            XCTFail("expected NoSuchKey")
        } catch let error as S3ClientError {
            XCTAssertEqual(error, .service(status: 404, code: "NoSuchKey", message: "The specified key does not exist."))
        }
    }
}
