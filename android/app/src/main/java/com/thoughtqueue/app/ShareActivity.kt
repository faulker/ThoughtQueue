package com.thoughtqueue.app

import android.app.Activity
import android.content.Intent
import android.os.Bundle
import android.widget.Toast
import com.thoughtqueue.app.store.CaptureResult
import com.thoughtqueue.app.store.persistCapture

/**
 * Receives ACTION_SEND text/plain and saves it through [persistCapture] as a new note in
 * Uncategorized. Shows a toast and finishes.
 */
class ShareActivity : Activity() {

    /** Handle the share intent immediately; there is no UI. */
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val text = intent?.takeIf { it.action == Intent.ACTION_SEND }
            ?.getStringExtra(Intent.EXTRA_TEXT)
        val message = if (text == null) {
            "Nothing to save"
        } else {
            when (persistCapture((application as TqApp).store, text)) {
                CaptureResult.Empty -> "No text to save"
                is CaptureResult.Created -> "Captured!"
                CaptureResult.Failed -> "Failed to save"
            }
        }
        Toast.makeText(this, message, Toast.LENGTH_SHORT).show()
        finish()
    }
}
