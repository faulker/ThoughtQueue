import Foundation
import CryptoKit

/// AWS Signature Version 4 signer for S3 requests, as pure statics so every step is testable.
///
/// The flow follows AWS's "Signature Calculations for the Authorization Header" document:
/// canonical request, then string to sign, then an HMAC-SHA256 chain that derives the signing
/// key from the secret, date, region and service. S3 differs from other services in that the
/// path is URI-encoded exactly once (each segment encoded, '/' kept) rather than twice.
enum SigV4 {
    static let algorithm = "AWS4-HMAC-SHA256"

    /// SHA256 of an empty body, used for GET, HEAD and DELETE.
    static let emptyPayloadHash = sha256Hex(Data())

    /// The fields of a request that SigV4 canonicalizes, gathered once so the intermediate
    /// steps share one view of the request.
    struct Request {
        let method: String
        let url: URL
        /// Extra headers to sign (for example `Range`). `host`, `x-amz-date` and
        /// `x-amz-content-sha256` are added by the signer and must not be passed here.
        let headers: [String: String]
        let payloadHash: String
    }

    /// Signs a request and returns the headers to add to it: `Authorization`, `x-amz-date` and
    /// `x-amz-content-sha256`. The caller must also send every header it passed in `headers`,
    /// unchanged, or the server's signature will not match.
    static func sign(
        method: String,
        url: URL,
        headers: [String: String],
        payloadHash: String,
        accessKey: String,
        secretKey: String,
        region: String,
        service: String = "s3",
        date: Date
    ) -> [String: String] {
        let amzDate = amzDateString(date)
        var all = headers
        all["host"] = hostHeader(for: url)
        all["x-amz-date"] = amzDate
        all["x-amz-content-sha256"] = payloadHash
        let request = Request(method: method, url: url, headers: all, payloadHash: payloadHash)

        let scope = credentialScope(date: date, region: region, service: service)
        let canonical = canonicalRequest(request)
        let toSign = stringToSign(canonicalRequest: canonical, amzDate: amzDate, scope: scope)
        let sig = signature(stringToSign: toSign, secretKey: secretKey, date: date, region: region, service: service)
        let authorization = "\(algorithm) Credential=\(accessKey)/\(scope),"
            + "SignedHeaders=\(signedHeaders(request.headers)),Signature=\(sig)"

        return [
            "Authorization": authorization,
            "x-amz-date": amzDate,
            "x-amz-content-sha256": payloadHash,
        ]
    }

    // MARK: - Intermediate steps

    /// Builds the canonical request: method, canonical URI, canonical query string, canonical
    /// headers, signed header list and payload hash, joined by newlines.
    static func canonicalRequest(_ request: Request) -> String {
        [
            request.method.uppercased(),
            canonicalURI(request.url),
            canonicalQueryString(request.url),
            canonicalHeaders(request.headers),
            signedHeaders(request.headers),
            request.payloadHash,
        ].joined(separator: "\n")
    }

    /// Builds the string to sign from the canonical request, timestamp and credential scope.
    static func stringToSign(canonicalRequest: String, amzDate: String, scope: String) -> String {
        [
            algorithm,
            amzDate,
            scope,
            sha256Hex(Data(canonicalRequest.utf8)),
        ].joined(separator: "\n")
    }

    /// Derives the signing key and returns the lowercase hex HMAC of the string to sign.
    static func signature(stringToSign: String, secretKey: String, date: Date, region: String, service: String) -> String {
        let key = signingKey(secretKey: secretKey, date: date, region: region, service: service)
        let mac = HMAC<SHA256>.authenticationCode(for: Data(stringToSign.utf8), using: key)
        return hex(Data(mac))
    }

    /// Derives the SigV4 signing key: HMAC chain over date, region, service and "aws4_request".
    static func signingKey(secretKey: String, date: Date, region: String, service: String) -> SymmetricKey {
        var key = SymmetricKey(data: Data("AWS4\(secretKey)".utf8))
        for part in [dateStamp(date), region, service, "aws4_request"] {
            let mac = HMAC<SHA256>.authenticationCode(for: Data(part.utf8), using: key)
            key = SymmetricKey(data: Data(mac))
        }
        return key
    }

    /// Returns the credential scope, `yyyyMMdd/region/service/aws4_request`.
    static func credentialScope(date: Date, region: String, service: String) -> String {
        "\(dateStamp(date))/\(region)/\(service)/aws4_request"
    }

    /// Returns the URL path with each segment URI-encoded once and '/' kept. An empty path is "/".
    static func canonicalURI(_ url: URL) -> String {
        let raw = URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedPath ?? ""
        if raw.isEmpty { return "/" }
        // Decode first so an already-encoded path is not double-encoded (S3 rule).
        return raw.split(separator: "/", omittingEmptySubsequences: false)
            .map { uriEncode(String($0).removingPercentEncoding ?? String($0)) }
            .joined(separator: "/")
    }

    /// Returns the query parameters URI-encoded and sorted by name then value, joined with '&'.
    /// A parameter without a value is emitted as `name=`.
    static func canonicalQueryString(_ url: URL) -> String {
        guard let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedQueryItems else {
            return ""
        }
        let pairs = items.map { item -> (String, String) in
            let name = item.name.removingPercentEncoding ?? item.name
            let value = item.value.map { $0.removingPercentEncoding ?? $0 } ?? ""
            return (uriEncode(name), uriEncode(value))
        }
        return pairs
            .sorted { $0.0 == $1.0 ? $0.1 < $1.1 : $0.0 < $1.0 }
            .map { "\($0.0)=\($0.1)" }
            .joined(separator: "&")
    }

    /// Returns `name:value\n` lines for every header, names lowercased and sorted, values
    /// trimmed with runs of spaces collapsed. Ends with a newline, as SigV4 requires.
    static func canonicalHeaders(_ headers: [String: String]) -> String {
        normalizedHeaders(headers)
            .map { "\($0.name):\($0.value)\n" }
            .joined()
    }

    /// Returns the sorted, lowercased header names joined with ';'.
    static func signedHeaders(_ headers: [String: String]) -> String {
        normalizedHeaders(headers).map(\.name).joined(separator: ";")
    }

    // MARK: - Encoding and formatting

    /// Percent-encodes everything except the RFC 3986 unreserved set (A-Z a-z 0-9 - . _ ~),
    /// with uppercase hex, which is what SigV4 and S3 expect.
    static func uriEncode(_ string: String) -> String {
        var out = ""
        for byte in Data(string.utf8) {
            let isUnreserved = (byte >= 0x41 && byte <= 0x5A) || (byte >= 0x61 && byte <= 0x7A)
                || (byte >= 0x30 && byte <= 0x39) || byte == 0x2D || byte == 0x2E || byte == 0x5F || byte == 0x7E
            if isUnreserved {
                out.append(Character(UnicodeScalar(byte)))
            } else {
                out += String(format: "%%%02X", byte)
            }
        }
        return out
    }

    /// Returns the `Host` header value: the URL host plus the port when it is not the default.
    static func hostHeader(for url: URL) -> String {
        let host = url.host ?? ""
        guard let port = url.port else { return host }
        let isDefault = (url.scheme == "https" && port == 443) || (url.scheme == "http" && port == 80)
        return isDefault ? host : "\(host):\(port)"
    }

    /// Formats a date as `yyyyMMdd'T'HHmmss'Z'` in UTC.
    static func amzDateString(_ date: Date) -> String {
        utcFormatter("yyyyMMdd'T'HHmmss'Z'").string(from: date)
    }

    /// Formats a date as `yyyyMMdd` in UTC.
    static func dateStamp(_ date: Date) -> String {
        utcFormatter("yyyyMMdd").string(from: date)
    }

    /// Returns the lowercase hex SHA256 of the data.
    static func sha256Hex(_ data: Data) -> String {
        hex(Data(SHA256.hash(data: data)))
    }

    /// Lowercase hex encoding of raw bytes.
    static func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }

    /// Lowercases names, trims values, collapses repeated spaces, and sorts by name.
    private static func normalizedHeaders(_ headers: [String: String]) -> [(name: String, value: String)] {
        headers.map { name, value in
            let trimmed = value.trimmingCharacters(in: .whitespaces)
            let collapsed = trimmed.split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
            return (name.lowercased(), collapsed)
        }
        .sorted { $0.name < $1.name }
    }

    /// Builds a POSIX, UTC, Gregorian formatter so output never depends on the user's locale.
    private static func utcFormatter(_ format: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = format
        return formatter
    }
}
