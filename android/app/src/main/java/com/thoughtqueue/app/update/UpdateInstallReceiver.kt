package com.thoughtqueue.app.update

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.pm.PackageInstaller
import android.os.Build
import com.thoughtqueue.app.TqApp

/**
 * Receives the [PackageInstaller] session result. A pending user action is the system
 * confirmation screen, which has to be started from here. Success usually replaces this
 * process before the broadcast arrives.
 */
class UpdateInstallReceiver : BroadcastReceiver() {
    /** Routes the session status to the confirmation screen or back to [TqApp.updates]. */
    override fun onReceive(context: Context, intent: Intent?) {
        if (intent == null) return
        val status = intent.getIntExtra(PackageInstaller.EXTRA_STATUS, PackageInstaller.STATUS_FAILURE)
        if (status == PackageInstaller.STATUS_PENDING_USER_ACTION) {
            val confirm = confirmation(intent) ?: return
            confirm.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            context.startActivity(confirm)
            return
        }
        val app = context.applicationContext as? TqApp ?: return
        if (status == PackageInstaller.STATUS_SUCCESS) {
            app.updates.onInstallResult(null)
            return
        }
        val message = intent.getStringExtra(PackageInstaller.EXTRA_STATUS_MESSAGE)
            ?: "The update could not be installed."
        app.updates.onInstallResult(message)
    }

    /** The system-supplied confirmation activity, when this session still needs the user. */
    private fun confirmation(intent: Intent): Intent? =
        if (Build.VERSION.SDK_INT >= 33) {
            intent.getParcelableExtra(Intent.EXTRA_INTENT, Intent::class.java)
        } else {
            @Suppress("DEPRECATION")
            intent.getParcelableExtra(Intent.EXTRA_INTENT)
        }
}
