package com.thoughtqueue.app.store

/** The outcome of saving shared text, for feedback and tests. */
sealed class CaptureResult {
    /** Whitespace-only text; nothing was saved. */
    object Empty : CaptureResult()

    /** A new note was created. */
    data class Created(val note: Note) : CaptureResult()

    /** Saving failed. */
    object Failed : CaptureResult()
}

/**
 * Save shared [text] as a new markdown note in Uncategorized; blank text is never saved. Unlike the
 * desktop `CaptureService.persistCapture` there is no working document to append to on Android.
 */
fun persistCapture(store: NoteStore, text: String): CaptureResult {
    if (text.isBlank()) return CaptureResult.Empty

    val created = store.createNote("", text, null, NoteDocType.MARKDOWN)
    return if (created != null) CaptureResult.Created(created) else CaptureResult.Failed
}
