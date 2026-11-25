package com.thoughtqueue.app.update

import android.content.Context
import com.thoughtqueue.app.prefs.Preferences
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.withContext
import java.io.File
import java.util.logging.Logger

/**
 * Checks GitHub for a newer signed APK and, after the user agrees, downloads and installs it.
 * Automatic checks are quiet: they only publish [status]. A user-initiated [check] returns the
 * release so Settings can ask before downloading.
 */
class UpdateController(
    private val app: Context,
    private val prefs: Preferences,
    private val scope: CoroutineScope,
    private val client: UpdateClient = UpdateClient(),
) {
    /** What the screens show. [Failed.version] is set when a download can be retried. */
    sealed class Status {
        /** Nothing has been checked in this process, or a check is not due yet. */
        data object Idle : Status()

        /** A version check is in flight. */
        data object Checking : Status()

        /** The running version is the newest published release. */
        data object UpToDate : Status()

        /** [version] is newer. Nothing has been downloaded yet. */
        data class Available(val version: String) : Status()

        /** The APK for [version] is downloading. */
        data class Downloading(val version: String) : Status()

        /** The system installer is waiting for the user to confirm [version]. */
        data class AwaitingConfirm(val version: String) : Status()

        /** [message] is safe to show. [version] is set when the same download can be retried. */
        data class Failed(val message: String, val version: String? = null) : Status()

        /** This build cannot install a release over itself. [message] says why. */
        data class NotUpdatable(val message: String) : Status()

        /** One line for Settings and the notes-list banner. */
        fun describe(): String = when (this) {
            Idle -> ""
            Checking -> "Checking..."
            UpToDate -> "You're up to date."
            is Available -> "Version $version is available."
            is Downloading -> "Downloading $version..."
            is AwaitingConfirm -> "Confirm the install to finish updating."
            is Failed -> message
            is NotUpdatable -> message
        }

        /** Version a "Download and install" action can still offer, if any. */
        fun offerVersion(): String? = when (this) {
            is Available -> version
            is AwaitingConfirm -> version
            is Failed -> version
            else -> null
        }
    }

    private val log = Logger.getLogger("UpdateController")
    private val gate = Mutex()
    private val _status = MutableStateFlow<Status>(Status.Idle)

    /** Latest check or install state. */
    val status: StateFlow<Status> = _status.asStateFlow()

    /** Marketing version of this install. */
    val runningVersion: String = UpdateInstaller.versionName(app)

    /**
     * Starts a check when this is an updatable install and the last success was more than a day
     * ago. Debug builds record [Status.NotUpdatable] and do not touch the network.
     */
    fun checkIfDue() {
        val reason = UpdateInstaller.notUpdatableReason(app)
        if (reason != null) {
            _status.value = Status.NotUpdatable(reason)
            return
        }
        val last = prefs.lastUpdateCheckAt()
        if (last != 0L && System.currentTimeMillis() - last < UpdateCheck.CHECK_INTERVAL_MILLIS) return
        scope.launch { check() }
    }

    /**
     * Asks GitHub which release is current. Returns it when it is newer than [runningVersion],
     * or null when this build is current, not updatable, or the check failed. [status] carries
     * the outcome either way.
     */
    suspend fun check(): UpdateCheck.Release? {
        val reason = UpdateInstaller.notUpdatableReason(app)
        if (reason != null) {
            _status.value = Status.NotUpdatable(reason)
            return null
        }
        if (!gate.tryLock()) {
            _status.value = Status.Failed("A check is already in progress.")
            return null
        }
        try {
            _status.value = Status.Checking
            val latest = withContext(Dispatchers.IO) { client.latestVersion() }
            prefs.setLastUpdateCheckAt(System.currentTimeMillis())
            log.info("Latest release $latest, running $runningVersion")
            return if (UpdateCheck.isNewer(latest, runningVersion)) {
                _status.value = Status.Available(latest)
                UpdateCheck.Release(latest)
            } else {
                _status.value = Status.UpToDate
                null
            }
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            log.warning("Update check failed: ${e.message}")
            _status.value = Status.Failed(e.message ?: "Update check failed")
            return null
        } finally {
            gate.unlock()
        }
    }

    /**
     * Downloads [version], checks its checksum and signing certificate, then opens the system
     * installer. Sends the user to the unknown-sources setting first when installs are not allowed.
     */
    fun install(version: String) {
        scope.launch {
            // Lock inside this coroutine. Mutex ownership cannot move to another coroutine.
            if (!gate.tryLock()) return@launch
            val dest = File(app.cacheDir, "updates/${UpdateCheck.Release(version).apkFilename}")
            try {
                val reason = UpdateInstaller.notUpdatableReason(app)
                if (reason != null) {
                    _status.value = Status.NotUpdatable(reason)
                    return@launch
                }
                if (!UpdateInstaller.canRequestInstalls(app)) {
                    UpdateInstaller.openUnknownSourcesSettings(app)
                    _status.value = Status.Failed(UpdateInstaller.INSTALL_NOT_ALLOWED, version)
                    return@launch
                }
                _status.value = Status.Downloading(version)
                val release = UpdateCheck.Release(version)
                withContext(Dispatchers.IO) {
                    client.downloadVerifiedApk(release, dest)
                    UpdateInstaller.assertSameCertificate(app, dest)
                }
                UpdateInstaller.commit(app, dest)
                _status.value = Status.AwaitingConfirm(version)
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                log.warning("Update install failed: ${e.message}")
                _status.value = Status.Failed(e.message ?: "Update failed", version)
            } finally {
                dest.delete()
                gate.unlock()
            }
        }
    }

    /**
     * Records the installer session result. [failure] is null on success. A self-update usually
     * kills this process before success is delivered.
     */
    fun onInstallResult(failure: String?) {
        val version = _status.value.offerVersion()
        _status.value = if (failure == null) {
            Status.UpToDate
        } else {
            Status.Failed(failure, version)
        }
    }
}
