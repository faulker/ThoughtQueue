package com.thoughtqueue.app.sync

import java.net.ConnectException
import java.net.SocketTimeoutException
import java.net.UnknownHostException
import java.net.UnknownServiceException
import javax.net.ssl.SSLException

/**
 * Turns sync and network errors into user-facing text. The desktop's `SyncErrorMessage.swift`
 * special-cases the macOS Local Network privacy failure; Android has no such permission, so
 * this maps the failures Android does produce instead: unknown host, refused connection,
 * timeouts, TLS problems and blocked cleartext HTTP.
 */
object SyncErrorMessage {
    const val CLEARTEXT_BLOCKED =
        "Plain HTTP to this server is blocked by Android's network security policy. Use https, or allow cleartext for the host."

    /** Returns a clear message for [error], falling back to its own message. */
    fun describe(error: Throwable): String = when (error) {
        is S3ClientError, is SyncEngineError -> error.message ?: error.javaClass.simpleName
        is UnknownHostException ->
            "Cannot find the server${error.message?.let { " \"$it\"" } ?: ""}. Check the endpoint and your connection."
        is ConnectException -> "Could not connect to the server: ${error.message ?: "connection refused"}."
        is SocketTimeoutException -> "The server did not respond in time."
        is UnknownServiceException ->
            if (error.message?.contains("CLEARTEXT", ignoreCase = true) == true) CLEARTEXT_BLOCKED
            else error.message ?: error.javaClass.simpleName
        is SSLException -> "Secure connection failed: ${error.message ?: "TLS error"}."
        else -> error.message ?: error.javaClass.simpleName
    }
}
