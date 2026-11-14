import Foundation

/// One object as reported by a listing.
struct RemoteObject: Equatable {
    /// Key relative to the store's configured prefix.
    let key: String
    /// ETag with surrounding quotes stripped.
    let etag: String
    let lastModified: Date
    let size: Int
}

/// An object's body plus the ETag it was served with.
struct ObjectContent: Equatable {
    let data: Data
    let etag: String
}

/// A flat key/value object store. `S3Client` is the real implementation; the sync engine
/// depends only on this protocol so it can be tested against an in-memory fake.
///
/// Keys are relative to whatever prefix the store is configured with. A missing key on `get`
/// throws `S3ClientError.service` with code `NoSuchKey` (status 404), for every implementation.
protocol ObjectStore {
    /// Lists every object whose key starts with `prefix`, following pagination to the end.
    func list(prefix: String) async throws -> [RemoteObject]
    /// Downloads an object.
    func get(key: String) async throws -> ObjectContent
    /// Uploads an object, replacing any existing one, and returns its new ETag.
    func put(key: String, data: Data) async throws -> String
    /// Deletes an object. Deleting a missing key succeeds, as it does on S3.
    func delete(key: String) async throws
    /// Verifies that the bucket is reachable with the configured credentials.
    func testConnection() async throws
}
