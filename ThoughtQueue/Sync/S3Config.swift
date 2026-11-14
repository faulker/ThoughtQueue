import Foundation

/// Connection settings for an S3-compatible bucket (AWS S3, MinIO, RustFS, ...).
///
/// The secret key is deliberately not part of this struct; it lives in the Keychain
/// (`KeychainStore`) and is handed to `S3Client` separately.
struct S3Config: Equatable {
    /// Base service URL, e.g. `https://s3.us-east-1.amazonaws.com` or `http://localhost:9000`.
    var endpoint: URL
    var region: String
    var bucket: String
    /// Optional folder inside the bucket that all keys live under, e.g. `notes/`.
    var keyPrefix: String
    /// Path-style (`endpoint/bucket/key`) is what MinIO and RustFS expect by default;
    /// virtual-host style (`bucket.host/key`) is AWS's preferred form.
    var usePathStyle: Bool
    var accessKeyID: String

    /// The prefix with leading slashes removed and exactly one trailing slash, or "" when unset.
    var normalizedPrefix: String {
        let trimmed = keyPrefix.trimmingCharacters(in: CharacterSet(charactersIn: "/").union(.whitespaces))
        return trimmed.isEmpty ? "" : trimmed + "/"
    }

    /// Returns the full bucket key for a key relative to the prefix.
    func fullKey(for key: String) -> String {
        normalizedPrefix + key
    }

    /// Strips the configured prefix from a full bucket key, or returns nil if it is outside it.
    func relativeKey(fromFullKey fullKey: String) -> String? {
        let prefix = normalizedPrefix
        guard fullKey.hasPrefix(prefix) else { return nil }
        return String(fullKey.dropFirst(prefix.count))
    }

    /// Returns the URL of the bucket itself, with optional query items (used by ListObjectsV2
    /// and HeadBucket). Query values are encoded with SigV4's strict rules so the URL that is
    /// sent is exactly the one that was signed.
    func bucketURL(queryItems: [URLQueryItem] = []) -> URL? {
        url(encodedKeyPath: "", queryItems: queryItems)
    }

    /// Returns the URL of an object, given a key relative to the configured prefix.
    func objectURL(forKey key: String) -> URL? {
        let encoded = fullKey(for: key)
            .split(separator: "/", omittingEmptySubsequences: false)
            .map { SigV4.uriEncode(String($0)) }
            .joined(separator: "/")
        return url(encodedKeyPath: encoded, queryItems: [])
    }

    /// Assembles a path-style or virtual-host URL for an already-encoded key path ("" for the bucket).
    private func url(encodedKeyPath: String, queryItems: [URLQueryItem]) -> URL? {
        guard var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false),
              let host = components.host, !bucket.isEmpty else { return nil }
        var basePath = components.percentEncodedPath
        while basePath.hasSuffix("/") { basePath.removeLast() }

        if usePathStyle {
            let bucketPath = basePath + "/" + SigV4.uriEncode(bucket)
            components.percentEncodedPath = encodedKeyPath.isEmpty ? bucketPath + "/" : bucketPath + "/" + encodedKeyPath
        } else {
            components.host = "\(bucket).\(host)"
            components.percentEncodedPath = basePath + "/" + encodedKeyPath
        }

        if queryItems.isEmpty {
            components.percentEncodedQuery = nil
        } else {
            components.percentEncodedQuery = queryItems
                .map { "\(SigV4.uriEncode($0.name))=\(SigV4.uriEncode($0.value ?? ""))" }
                .joined(separator: "&")
        }
        return components.url
    }
}
