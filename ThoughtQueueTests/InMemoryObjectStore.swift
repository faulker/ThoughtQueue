import Foundation
import CryptoKit
@testable import ThoughtQueue

/// In-memory `ObjectStore` fake for sync tests. ETags are the MD5 of the body, as S3 does for
/// single-part uploads, so identical content always yields the same ETag.
final class InMemoryObjectStore: ObjectStore {
    private var objects: [String: (data: Data, etag: String, modified: Date)] = [:]
    private let lock = NSLock()

    /// Error thrown by `testConnection` when set, to simulate an unreachable bucket.
    var connectionError: Error?

    /// Returns every stored object whose key starts with `prefix`, sorted by key like S3.
    func list(prefix: String) async throws -> [RemoteObject] {
        lock.withLock {
            objects.filter { $0.key.hasPrefix(prefix) }
                .map { RemoteObject(key: $0.key, etag: $0.value.etag, lastModified: $0.value.modified, size: $0.value.data.count) }
                .sorted { $0.key < $1.key }
        }
    }

    /// Returns the stored body and ETag, or throws S3's NoSuchKey error.
    func get(key: String) async throws -> ObjectContent {
        try lock.withLock {
            guard let object = objects[key] else {
                throw S3ClientError.service(status: 404, code: "NoSuchKey", message: "The specified key does not exist.")
            }
            return ObjectContent(data: object.data, etag: object.etag)
        }
    }

    /// Stores the body and returns its MD5 ETag.
    func put(key: String, data: Data) async throws -> String {
        let etag = Insecure.MD5.hash(data: data).map { String(format: "%02x", $0) }.joined()
        lock.withLock { objects[key] = (data, etag, Date()) }
        return etag
    }

    /// Removes the key; a missing key is not an error.
    func delete(key: String) async throws {
        lock.withLock { _ = objects.removeValue(forKey: key) }
    }

    /// Throws `connectionError` when set.
    func testConnection() async throws {
        if let connectionError { throw connectionError }
    }
}
