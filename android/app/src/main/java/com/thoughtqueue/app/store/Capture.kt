package com.thoughtqueue.app.store

/** The outcome of saving shared text, for feedback and tests. */
sealed class CaptureResult {
    /** Whitespace-only text; nothing was saved. */
    object Empty : CaptureResult()

    /** Text was appended to the working document with this title. */
    data class Appended(val title: String) : CaptureResult()

    /** A new note was created. */
    data class Created(val note: Note) : CaptureResult()

    /** Saving failed. */
    object Failed : CaptureResult()
}

/**
 * Save shared or captured [text] using the working-document sink rules, mirroring the desktop
 * `CaptureService.persistCapture`: never save blank text; append (after a blank line) to the
 * working document when one is set and still exists; otherwise clear the stale setting and create
 * a markdown note in Uncategorized.
 */
fun persistCapture(store: NoteStore, text: String): CaptureResult {
    if (text.isBlank()) return CaptureResult.Empty

    if (store.workingDocumentPath != null) {
        val note = store.workingDocumentNote()
        if (note != null && store.append(note, text)) return CaptureResult.Appended(note.title)
        store.clearWorkingDocument()
    }

    val created = store.createNote("", text, null, NoteDocType.MARKDOWN)
    return if (created != null) CaptureResult.Created(created) else CaptureResult.Failed
}
