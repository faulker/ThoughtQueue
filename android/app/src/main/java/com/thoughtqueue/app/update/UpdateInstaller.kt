package com.thoughtqueue.app.update

import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.pm.ApplicationInfo
import android.content.pm.PackageInfo
import android.content.pm.PackageInstaller
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.provider.Settings
import java.io.File

/**
 * Hands a verified APK to the system installer. The session copies the file first, so the cache
 * copy can be deleted as soon as [commit] returns. The system still asks the user to confirm.
 */
object UpdateInstaller {
    /** Shown when this process is a debug build or a different application id. */
    const val NOT_UPDATABLE = "Debug build. Updates install only on a signed release of ${UpdateCheck.PACKAGE_NAME}."

    /** Shown when the user has not allowed this app to install packages. */
    const val INSTALL_NOT_ALLOWED = "Allow ThoughtQueue to install updates in system settings, then try again."

    /**
     * Why this install cannot update itself, or null when it is a signed
     * [UpdateCheck.PACKAGE_NAME] release. Debug and `applicationIdSuffix` builds are skipped.
     */
    fun notUpdatableReason(context: Context): String? {
        if (context.packageName != UpdateCheck.PACKAGE_NAME) return NOT_UPDATABLE
        val flags = applicationInfo(context).flags
        if (flags and ApplicationInfo.FLAG_DEBUGGABLE != 0) return NOT_UPDATABLE
        return null
    }

    /** Marketing version of the running app, for example "1.2.3". */
    fun versionName(context: Context): String = packageInfo(context, 0).versionName ?: "0.0.0"

    /** True when the user has allowed this app to request package installs. */
    fun canRequestInstalls(context: Context): Boolean =
        context.packageManager.canRequestPackageInstalls()

    /** Opens the system page where the user allows installs from this app. */
    fun openUnknownSourcesSettings(context: Context) {
        val intent = Intent(
            Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES,
            Uri.parse("package:${context.packageName}"),
        ).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        context.startActivity(intent)
    }

    /**
     * Refuses [apk] unless its signing certificate is the one this install was signed with.
     * An unreadable certificate is a refusal too: the installer must not guess.
     */
    fun assertSameCertificate(context: Context, apk: File) {
        val installed = certSet(installedCerts(context))
        val incoming = certSet(archiveCerts(context.packageManager, apk))
        if (installed.isEmpty() || incoming.isEmpty()) throw UpdateError.CertificateUnreadable()
        if (installed != incoming) throw UpdateError.CertificateMismatch()
    }

    /**
     * Copies [apk] into a [PackageInstaller] session and commits it. The status broadcast is
     * delivered to [UpdateInstallReceiver], which starts the system confirmation screen.
     */
    fun commit(context: Context, apk: File) {
        val installer = context.packageManager.packageInstaller
        val params = PackageInstaller.SessionParams(PackageInstaller.SessionParams.MODE_FULL_INSTALL)
        if (Build.VERSION.SDK_INT >= 31) {
            params.setRequireUserAction(PackageInstaller.SessionParams.USER_ACTION_REQUIRED)
        }
        val sessionId = installer.createSession(params)
        val session = installer.openSession(sessionId)
        try {
            session.openWrite("base.apk", 0, apk.length()).use { out ->
                apk.inputStream().use { input -> input.copyTo(out) }
                session.fsync(out)
            }
            val intent = Intent(context, UpdateInstallReceiver::class.java).setPackage(context.packageName)
            // The system writes EXTRA_STATUS back into this intent, so it has to be mutable.
            val pendingFlags = PendingIntent.FLAG_UPDATE_CURRENT or
                if (Build.VERSION.SDK_INT >= 31) PendingIntent.FLAG_MUTABLE else 0
            val pending = PendingIntent.getBroadcast(context, sessionId, intent, pendingFlags)
            session.commit(pending.intentSender)
        } catch (e: Exception) {
            session.abandon()
            throw e
        } finally {
            session.close()
        }
    }

    /** Lowercase hex of each certificate, so the sets compare by contents. */
    private fun certSet(certs: List<ByteArray>): Set<String> = certs.map { UpdateCheck.sha256Hex(it) }.toSet()

    /** Certificates of the running app. */
    private fun installedCerts(context: Context): List<ByteArray> =
        certificateBytes(packageInfo(context, signingFlags()))

    /** Certificates of an APK that is not installed. */
    private fun archiveCerts(pm: PackageManager, apk: File): List<ByteArray> {
        val flags = signingFlags()
        val info = if (Build.VERSION.SDK_INT >= 33) {
            pm.getPackageArchiveInfo(apk.absolutePath, PackageManager.PackageInfoFlags.of(flags.toLong()))
        } else {
            @Suppress("DEPRECATION")
            pm.getPackageArchiveInfo(apk.absolutePath, flags)
        } ?: return emptyList()
        return certificateBytes(info)
    }

    /** Signing certs on the package info. API 28+ uses [PackageInfo.signingInfo]; older uses signatures. */
    private fun certificateBytes(info: PackageInfo): List<ByteArray> {
        if (Build.VERSION.SDK_INT >= 28) {
            val signing = info.signingInfo ?: return emptyList()
            return signing.apkContentsSigners?.map { it.toByteArray() } ?: emptyList()
        }
        @Suppress("DEPRECATION")
        return info.signatures?.map { it.toByteArray() } ?: emptyList()
    }

    /** [PackageInfo] for this app. [flags] is zero for the version, or the signing flags. */
    private fun packageInfo(context: Context, flags: Int): PackageInfo {
        val pm = context.packageManager
        val name = context.packageName
        return if (Build.VERSION.SDK_INT >= 33) {
            pm.getPackageInfo(name, PackageManager.PackageInfoFlags.of(flags.toLong()))
        } else {
            @Suppress("DEPRECATION")
            pm.getPackageInfo(name, flags)
        }
    }

    /** [ApplicationInfo] for this app, used to spot a debuggable build. */
    private fun applicationInfo(context: Context): ApplicationInfo {
        val pm = context.packageManager
        val name = context.packageName
        return if (Build.VERSION.SDK_INT >= 33) {
            pm.getApplicationInfo(name, PackageManager.ApplicationInfoFlags.of(0))
        } else {
            @Suppress("DEPRECATION")
            pm.getApplicationInfo(name, 0)
        }
    }

    /** Flag that asks PackageManager for the signing certificate on this SDK. */
    private fun signingFlags(): Int =
        if (Build.VERSION.SDK_INT >= 28) PackageManager.GET_SIGNING_CERTIFICATES
        else @Suppress("DEPRECATION") PackageManager.GET_SIGNATURES
}
