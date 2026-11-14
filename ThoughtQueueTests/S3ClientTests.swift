import XCTest
@testable import ThoughtQueue

/// Serves canned responses to an injected `URLSession` and records the requests it saw.
private final class StubURLProtocol: URLProtocol {
    static var handler: ((URLRequest) -> (Int, [String: String], Data))?
    static var requests: [URLRequest] = []

    /// Accepts every request so the stub sees all traffic on its session.
    override class func canInit(with request: URLRequest) -> Bool { true }

    /// Returns the request unchanged.
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    /// Replies with whatever `handler` returns for the request.
    override func startLoading() {
        Self.requests.append(request)
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        let (status, headers, body) = handler(request)
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    /// Nothing to cancel; responses are delivered synchronously.
    override func stopLoading() {}
}

/// Exercises `S3Client`'s request flow against a stubbed session: pagination, prefix
/// handling, signing headers, ETag extraction and typed errors.
final class S3ClientTests: XCTestCase {
    private var client: S3Client!

    override func setUp() {
        super.setUp()
        StubURLProtocol.requests = []
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        let cfg = S3Config(endpoint: URL(string: "http://localhost:9000")!, region: "us-east-1", bucket: "bkt",
                           keyPrefix: "notes", usePathStyle: true, accessKeyID: "AK")
        client = S3Client(config: cfg, secretKey: "SK", session: URLSession(configuration: configuration))
    }

    override func tearDown() {
        StubURLProtocol.handler = nil
        super.tearDown()
    }

    func testListFollowsContinuationTokenAndStripsPrefix() async throws {
        StubURLProtocol.handler = { request in
            let query = request.url?.query ?? ""
            let body: String
            if query.contains("continuation-token") {
                body = """
                <ListBucketResult><IsTruncated>false</IsTruncated>
                <Contents><Key>notes/b.md</Key><LastModified>2024-01-01T00:00:00.000Z</LastModified><ETag>"2"</ETag><Size>2</Size></Contents>
                </ListBucketResult>
                """
            } else {
                body = """
                <ListBucketResult><IsTruncated>true</IsTruncated><NextContinuationToken>tok/1=</NextContinuationToken>
                <Contents><Key>notes/a.md</Key><LastModified>2024-01-01T00:00:00.000Z</LastModified><ETag>"1"</ETag><Size>1</Size></Contents>
                </ListBucketResult>
                """
            }
            return (200, [:], Data(body.utf8))
        }

        let objects = try await client.list(prefix: "")
        XCTAssertEqual(objects.map(\.key), ["a.md", "b.md"])
        XCTAssertEqual(objects.map(\.etag), ["1", "2"])
        XCTAssertEqual(StubURLProtocol.requests.count, 2)
        XCTAssertEqual(StubURLProtocol.requests[1].url?.absoluteString,
                       "http://localhost:9000/bkt/?list-type=2&prefix=notes%2F&continuation-token=tok%2F1%3D")
        let auth = StubURLProtocol.requests[0].value(forHTTPHeaderField: "Authorization") ?? ""
        XCTAssertTrue(auth.hasPrefix("AWS4-HMAC-SHA256 Credential=AK/"), auth)
        XCTAssertNotNil(StubURLProtocol.requests[0].value(forHTTPHeaderField: "x-amz-date"))
    }

    func testPutSignsPayloadAndReturnsETag() async throws {
        StubURLProtocol.handler = { _ in (200, ["ETag": "\"abc123\""], Data()) }
        let body = Data("hello".utf8)
        let etag = try await client.put(key: "Work/x y.md", data: body)
        XCTAssertEqual(etag, "abc123")
        let request = try XCTUnwrap(StubURLProtocol.requests.first)
        XCTAssertEqual(request.httpMethod, "PUT")
        XCTAssertEqual(request.url?.absoluteString, "http://localhost:9000/bkt/notes/Work/x%20y.md")
        XCTAssertEqual(request.value(forHTTPHeaderField: "x-amz-content-sha256"), SigV4.sha256Hex(body))
    }

    func testGetSurfacesServiceError() async {
        StubURLProtocol.handler = { _ in
            (404, [:], Data("<Error><Code>NoSuchKey</Code><Message>gone</Message></Error>".utf8))
        }
        do {
            _ = try await client.get(key: "a.md")
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error as? S3ClientError, .service(status: 404, code: "NoSuchKey", message: "gone"))
        }
    }

    func testConnectionFailureIsHTTPStatus() async {
        StubURLProtocol.handler = { _ in (403, [:], Data()) }
        do {
            try await client.testConnection()
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error as? S3ClientError, .http(status: 403))
            XCTAssertEqual(StubURLProtocol.requests.first?.httpMethod, "HEAD")
        }
    }
}
