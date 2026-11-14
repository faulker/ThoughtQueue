package com.thoughtqueue.app.sync

import android.content.Context
import androidx.work.Constraints
import androidx.work.CoroutineWorker
import androidx.work.ExistingPeriodicWorkPolicy
import androidx.work.NetworkType
import androidx.work.PeriodicWorkRequestBuilder
import androidx.work.WorkManager
import androidx.work.WorkerParameters
import com.thoughtqueue.app.TqApp
import java.util.concurrent.TimeUnit

/**
 * Periodic background sync. Runs a triggered sync through the app's engine and waits for it
 * (and any follow-up) to finish. A failed sync is reported through the engine's status, not by
 * failing the work, so WorkManager simply tries again next period.
 */
class SyncWorker(context: Context, params: WorkerParameters) : CoroutineWorker(context, params) {
    /** Requests an automatic sync; it is inert when sync is not configured. */
    override suspend fun doWork(): Result {
        val app = applicationContext as TqApp
        app.sync.requestSync(userInitiated = false)?.join()
        return Result.success()
    }
}

/** Schedules or cancels the periodic [SyncWorker] to match the preferences. */
object SyncScheduler {
    const val WORK_NAME = "thoughtqueue-periodic-sync"

    /** WorkManager's floor for periodic work, which is also the app's minimum interval. */
    const val MIN_INTERVAL_MINUTES = 15

    /**
     * Enqueues the periodic sync (network required) when [enabled], replacing any previous
     * schedule so a changed interval takes effect; cancels it otherwise.
     */
    fun apply(context: Context, enabled: Boolean, intervalMinutes: Int) {
        val wm = WorkManager.getInstance(context)
        if (!enabled) {
            wm.cancelUniqueWork(WORK_NAME)
            return
        }
        val minutes = intervalMinutes.coerceAtLeast(MIN_INTERVAL_MINUTES).toLong()
        val request = PeriodicWorkRequestBuilder<SyncWorker>(minutes, TimeUnit.MINUTES)
            .setConstraints(Constraints.Builder().setRequiredNetworkType(NetworkType.CONNECTED).build())
            .build()
        wm.enqueueUniquePeriodicWork(WORK_NAME, ExistingPeriodicWorkPolicy.UPDATE, request)
    }
}
