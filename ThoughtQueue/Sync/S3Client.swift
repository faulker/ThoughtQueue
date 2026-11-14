import Foundation

/// Failures from talking to an S3-compatible service.
enum S3ClientError: LocalizedError, Equatable {
    /// The service answered with an error document (`<Error><Code>...<Message>...`).
    case service(status: Int, code: String, message: String)
    /// A non-2xx status with no parseable error body (HEAD responses never have one).
    case http(status: Int)
    /// The configuration could not be turned into a request URL.
    case invalidURL
    /// The response was not HTTP, or a success response lacked something required.
    case invalidResponse(String)
    /// A response body was not the XML we expected.
    case malformedXML(String)

    var errorDescription: String? {
        switch self {
        case .service(let status, let code, let message):
            return "S3 error \(status) \(code): \(message)"
        case .http(let status):
            return "S3 request failed with HTTP \(status)."
        case .invalidURL:
            return "The S3 endpoint or bucket is not valid."
        case .invalidResponse(let detail):
            return "Unexpected S3 response: \(detail)"
        case .malformedXML(let detail):
            return "Could not read S3 response: \(detail)"
        }
    }
}

/// `ObjectStore` backed by an S3-compatible HTTP API, signed with SigV4.
final class S3Client: ObjectStore {
    let config: S3Config
    private let secretKey: String
    private let session: URLSession

    /// One page of a ListObjectsV2 response.
    struct ListPage: Equatable {
        /// Objects with their full (prefix-included) bucket keys.
        var objects: [RemoteObject]
        var isTruncated: Bool
        var nextContinuationToken: String?
    }

    /// Creates a client. The session is injectable so tests can stub the network.
    init(config: S3Config, secretKey: String, session: URLSession = .shared) {
        self.config = config
        self.secretKey = secretKey
        self.session = session
    }

    // MARK: - ObjectStore

    /// Lists objects under `prefix` (relative to the configured prefix) via ListObjectsV2,
    /// following continuation tokens until the listing is complete.
    func list(prefix: String) async throws -> [RemoteObject] {
        var results: [RemoteObject] = []
        var token: String?
        repeat {
            var query = [URLQueryItem(name: "list-type", value: "2"),
                         URLQueryItem(name: "prefix", value: config.fullKey(for: prefix))]
            if let token { query.append(URLQueryItem(name: "continuation-token", value: token)) }
            guard let url = config.bucketURL(queryItems: query) else { throw S3ClientError.invalidURL }

            let (data, _) = try await send(method: "GET", url: url)
            let page = try Self.parseListPage(data)
            for object in page.objects {
                guard let relative = config.relativeKey(fromFullKey: object.key) else { continue }
                results.append(RemoteObject(key: relative, etag: object.etag,
                                            lastModified: object.lastModified, size: object.size))
            }
            if page.isTruncated && page.nextContinuationToken == nil {
                throw S3ClientError.invalidResponse("truncated listing without a continuation token")
            }
            token = page.isTruncated ? page.nextContinuationToken : nil
        } while token != nil
        return results
    }

    /// Downloads an object and returns its body and ETag.
    func get(key: String) async throws -> ObjectContent {
        guard let url = config.objectURL(forKey: key) else { throw S3ClientError.invalidURL }
        let (data, response) = try await send(method: "GET", url: url)
        guard let etag = Self.etag(from: response) else {
            throw S3ClientError.invalidResponse("GET \(key) returned no ETag")
        }
        return ObjectContent(data: data, etag: etag)
    }

    /// Uploads an object and returns the ETag the service assigned.
    func put(key: String, data: Data) async throws -> String {
        guard let url = config.objectURL(forKey: key) else { throw S3ClientError.invalidURL }
        let (_, response) = try await send(method: "PUT", url: url, body: data)
        guard let etag = Self.etag(from: response) else {
            throw S3ClientError.invalidResponse("PUT \(key) returned no ETag")
        }
        return etag
    }

    /// Deletes an object.
    func delete(key: String) async throws {
        guard let url = config.objectURL(forKey: key) else { throw S3ClientError.invalidURL }
        _ = try await send(method: "DELETE", url: url)
    }

    /// Sends HeadBucket, which succeeds only if the bucket exists and the credentials can reach it.
    func testConnection() async throws {
        guard let url = config.bucketURL() else { throw S3ClientError.invalidURL }
        _ = try await send(method: "HEAD", url: url)
    }

    // MARK: - Transport

    /// Signs and sends one request, returning the body and response for a 2xx status and
    /// throwing a typed `S3ClientError` for anything else.
    private func send(method: String, url: URL, body: Data? = nil) async throws -> (Data, HTTPURLResponse) {
        let payload = body ?? Data()
        let signed = SigV4.sign(method: method, url: url, headers: [:],
                                payloadHash: SigV4.sha256Hex(payload),
                                accessKey: config.accessKeyID, secretKey: secretKey,
                                region: config.region, date: Date())

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.cachePolicy = .reloadIgnoringLocalCacheData
        for (name, value) in signed { request.setValue(value, forHTTPHeaderField: name) }
        if let body {
            request.httpBody = body
            request.setValue(String(body.count), forHTTPHeaderField: "Content-Length")
        }

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw S3ClientError.invalidResponse("not an HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw Self.error(status: http.statusCode, body: data)
        }
        return (data, http)
    }

    /// Reads the ETag header, quotes stripped.
    private static func etag(from response: HTTPURLResponse) -> String? {
        guard let raw = response.value(forHTTPHeaderField: "ETag") else { return nil }
        return stripQuotes(raw)
    }

    // MARK: - XML parsing (static so it is testable without a network)

    /// Turns an error status and body into a typed error, using the S3 error document when present.
    static func error(status: Int, body: Data) -> S3ClientError {
        if let parsed = parseErrorDocument(body) {
            return .service(status: status, code: parsed.code, message: parsed.message)
        }
        return .http(status: status)
    }

    /// Parses `<Error><Code>..</Code><Message>..</Message></Error>`, or nil if the body is not one.
    static func parseErrorDocument(_ data: Data) -> (code: String, message: String)? {
        guard !data.isEmpty else { return nil }
        let collector = XMLCollector()
        let parser = XMLParser(data: data)
        parser.delegate = collector
        guard parser.parse(), collector.rootElement == "Error",
              let code = collector.errorCode else { return nil }
        return (code, collector.errorMessage ?? "")
    }

    /// Parses one ListObjectsV2 result page. Keys are returned as full bucket keys.
    static func parseListPage(_ data: Data) throws -> ListPage {
        let collector = XMLCollector()
        let parser = XMLParser(data: data)
        parser.delegate = collector
        guard parser.parse() else {
            throw S3ClientError.malformedXML(parser.parserError?.localizedDescription ?? "unknown parse error")
        }
        guard collector.rootElement == "ListBucketResult" else {
            throw S3ClientError.malformedXML("expected ListBucketResult, got \(collector.rootElement ?? "nothing")")
        }

        var objects: [RemoteObject] = []
        for entry in collector.contents {
            guard let key = entry["Key"] else { throw S3ClientError.malformedXML("object without Key") }
            guard let modifiedText = entry["LastModified"], let modified = parseISO8601(modifiedText) else {
                throw S3ClientError.malformedXML("bad LastModified for \(key)")
            }
            guard let sizeText = entry["Size"], let size = Int(sizeText) else {
                throw S3ClientError.malformedXML("bad Size for \(key)")
            }
            objects.append(RemoteObject(key: key, etag: stripQuotes(entry["ETag"] ?? ""),
                                        lastModified: modified, size: size))
        }
        let token = collector.nextContinuationToken.flatMap { $0.isEmpty ? nil : $0 }
        return ListPage(objects: objects, isTruncated: collector.isTruncated == "true",
                        nextContinuationToken: token)
    }

    /// Normalizes an ETag to its bare value: drops a weak `W/` prefix and surrounding quotes.
    /// S3 returns `"abc"` (sometimes `&quot;abc&quot;`), but a compressing proxy such as
    /// Cloudflare serves gzipped GETs as `W/"abc"`, which must still match the LIST ETag.
    static func stripQuotes(_ value: String) -> String {
        var trimmed = value.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("W/") || trimmed.hasPrefix("w/") { trimmed.removeFirst(2) }
        return trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "\"").union(.whitespaces))
    }

    /// Parses S3's ISO 8601 timestamps, with or without fractional seconds.
    static func parseISO8601(_ text: String) -> Date? {
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFraction.date(from: text) { return date }
        return ISO8601DateFormatter().date(from: text)
    }
}

/// `XMLParser` delegate that collects the handful of elements S3 responses carry.
/// It handles both ListBucketResult and Error documents, since both are shallow.
private final class XMLCollector: NSObject, XMLParserDelegate {
    var rootElement: String?
    var contents: [[String: String]] = []
    var isTruncated: String?
    var nextContinuationToken: String?
    var errorCode: String?
    var errorMessage: String?

    private var stack: [String] = []
    private var text = ""
    private var currentObject: [String: String]?

    /// Records the root element and starts a new object at each `<Contents>`.
    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        if rootElement == nil { rootElement = elementName }
        if elementName == "Contents" { currentObject = [:] }
        stack.append(elementName)
        text = ""
    }

    /// Accumulates character data; XMLParser may deliver one value in several chunks.
    func parser(_ parser: XMLParser, foundCharacters string: String) {
        text += string
    }

    /// Stores the finished element's text according to where it sits in the document.
    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?) {
        stack.removeLast()
        let parent = stack.last
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)

        if elementName == "Contents", let object = currentObject {
            contents.append(object)
            currentObject = nil
        } else if parent == "Contents" {
            currentObject?[elementName] = value
        } else if parent == "ListBucketResult" && elementName == "IsTruncated" {
            isTruncated = value
        } else if parent == "ListBucketResult" && elementName == "NextContinuationToken" {
            nextContinuationToken = value
        } else if parent == "Error" && elementName == "Code" {
            errorCode = value
        } else if parent == "Error" && elementName == "Message" {
            errorMessage = value
        }
        text = ""
    }
}
