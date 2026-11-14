package com.thoughtqueue.app.sync

import java.time.Instant

/** One object as reported by a listing. */
data class RemoteObject(
    /** Key relative to the store's configured prefix. */
    val key: String,
    /** ETag with surrounding quotes stripped. */
    val etag: String,
    val lastModified: Instant,
    val size: Long,
)

/** An object's body plus the ETag it was served with. Equality compares the bytes. */
class ObjectContent(val data: ByteArray, val etag: String) {
    /** Two contents are equal when their bytes and ETags are. */
    override fun equals(other: Any?): Boolean =
        other is ObjectContent && other.etag == etag && other.data.contentEquals(data)

    /** Hash consistent with [equals]. */
    override fun hashCode(): Int = 31 * data.contentHashCode() + etag.hashCode()

    /** Debug form showing the size, not the bytes. */
    override fun toString(): String = "ObjectContent(${data.size} bytes, etag=$etag)"
}

/** Failures from talking to an S3-compatible service. The message is user-readable. */
sealed class S3ClientError(message: String) : Exception(message) {
    /** The service answered with an error document (`<Error><Code>...<Message>...`). */
    data class Service(val status: Int, val code: String, val detail: String) :
        S3ClientError("S3 error $status $code: $detail")

    /** A non-2xx status with no parseable error body (HEAD responses never have one). */
    data class Http(val status: Int) : S3ClientError("S3 request failed with HTTP $status.")

    /** The configuration could not be turned into a request URL. */
    data object InvalidURL : S3ClientError("The S3 endpoint or bucket is not valid.")

    /** A success response lacked something required. */
    data class InvalidResponse(val detail: String) : S3ClientError("Unexpected S3 response: $detail")

    /** A response body was not the XML we expected. */
    data class MalformedXML(val detail: String) : S3ClientError("Could not read S3 response: $detail")
}

/**
 * A flat key/value object store. [S3Client] is the real implementation; the sync engine
 * depends only on this interface so it can be tested against an in-memory fake.
 *
 * Keys are relative to whatever prefix the store is configured with. A missing key on [get]
 * throws [S3ClientError.Service] with code `NoSuchKey` (status 404), for every implementation.
 */
interface ObjectStore {
    /** Lists every object whose key starts with [prefix], following pagination to the end. */
    suspend fun list(prefix: String): List<RemoteObject>

    /** Downloads an object. */
    suspend fun get(key: String): ObjectContent

    /** Uploads an object, replacing any existing one, and returns its new ETag. */
    suspend fun put(key: String, data: ByteArray): String

    /** Deletes an object. Deleting a missing key succeeds, as it does on S3. */
    suspend fun delete(key: String)

    /** Verifies that the bucket is reachable with the configured credentials. */
    suspend fun testConnection()
}
