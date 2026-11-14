package com.thoughtqueue.app.sync

import java.security.MessageDigest
import java.time.Instant

/**
 * In-memory [ObjectStore] fake for sync tests, ported from the desktop's
 * `InMemoryObjectStore.swift`. ETags are the MD5 of the body, as S3 does for single-part
 * uploads, so identical content always yields the same ETag.
 */
class InMemoryObjectStore : ObjectStore {
    private class Stored(val data: ByteArray, val etag: String, val modified: Instant)

    private val objects = HashMap<String, Stored>()

    /** Number of `list` calls, so tests can count sync runs. */
    @Volatile var listCalls = 0

    /** Error thrown by [testConnection] when set, to simulate an unreachable bucket. */
    var connectionError: Exception? = null

    /** Returns every stored object whose key starts with [prefix], sorted by key like S3. */
    override suspend fun list(prefix: String): List<RemoteObject> = synchronized(this) {
        listCalls++
        objects.filterKeys { it.startsWith(prefix) }
            .map { (k, v) -> RemoteObject(k, v.etag, v.modified, v.data.size.toLong()) }
            .sortedBy { it.key }
    }

    /** Returns the stored body and ETag, or throws S3's NoSuchKey error. */
    override suspend fun get(key: String): ObjectContent = synchronized(this) {
        val obj = objects[key] ?: throw S3ClientError.Service(404, "NoSuchKey", "The specified key does not exist.")
        ObjectContent(obj.data.copyOf(), obj.etag)
    }

    /** Stores the body and returns its MD5 ETag. */
    override suspend fun put(key: String, data: ByteArray): String {
        val etag = MessageDigest.getInstance("MD5").digest(data).joinToString("") { "%02x".format(it) }
        synchronized(this) { objects[key] = Stored(data.copyOf(), etag, Instant.now()) }
        return etag
    }

    /** Removes the key; a missing key is not an error. */
    override suspend fun delete(key: String) {
        synchronized(this) { objects.remove(key) }
    }

    /** Throws [connectionError] when set. */
    override suspend fun testConnection() {
        connectionError?.let { throw it }
    }
}
