package com.thoughtqueue.app.sync

import org.junit.Assert.assertEquals
import org.junit.Test

/** One test per row of the planner table in `docs/sync.md`, plus open-conflict skipping and ordering. */
class SyncPlannerTest {
    private val base = SyncState.Entry(localHash = "h0", remoteETag = "e0")

    /** Plans a single key "k" and returns its action. */
    private fun plan(local: String?, remote: String?, base: SyncState.Entry?, conflicts: Set<String> = emptySet()): List<SyncAction> =
        SyncPlanner.plan(
            local = local?.let { mapOf("k" to it) } ?: emptyMap(),
            remote = remote?.let { mapOf("k" to it) } ?: emptyMap(),
            base = base?.let { mapOf("k" to it) } ?: emptyMap(),
            openConflicts = conflicts,
        )

    @Test fun presentMissingNoBaseUploads() = assertEquals(listOf(SyncAction.Upload("k")), plan("h1", null, null))

    @Test fun missingPresentNoBaseDownloads() = assertEquals(listOf(SyncAction.Download("k")), plan(null, "e1", null))

    @Test fun presentPresentNoBaseIsConflict() = assertEquals(listOf(SyncAction.Conflict("k")), plan("h1", "e1", null))

    @Test fun presentPresentUnchangedIsNoop() = assertEquals(listOf(SyncAction.Noop("k")), plan("h0", "e0", base))

    @Test fun presentPresentLocalChangedUploads() = assertEquals(listOf(SyncAction.Upload("k")), plan("h1", "e0", base))

    @Test fun presentPresentRemoteChangedDownloads() = assertEquals(listOf(SyncAction.Download("k")), plan("h0", "e1", base))

    @Test fun presentPresentBothChangedIsConflict() = assertEquals(listOf(SyncAction.Conflict("k")), plan("h1", "e1", base))

    @Test fun missingPresentRemoteUnchangedDeletesRemote() =
        assertEquals(listOf(SyncAction.DeleteRemote("k")), plan(null, "e0", base))

    @Test fun missingPresentRemoteChangedIsConflict() = assertEquals(listOf(SyncAction.Conflict("k")), plan(null, "e1", base))

    @Test fun presentMissingLocalUnchangedDeletesLocal() =
        assertEquals(listOf(SyncAction.DeleteLocal("k")), plan("h0", null, base))

    @Test fun presentMissingLocalChangedIsConflict() = assertEquals(listOf(SyncAction.Conflict("k")), plan("h1", null, base))

    @Test fun missingMissingForgetsBase() = assertEquals(listOf(SyncAction.Forget("k")), plan(null, null, base))

    @Test fun openConflictKeysGetNoAction() = assertEquals(emptyList<SyncAction>(), plan("h1", "e1", base, setOf("k")))

    @Test fun actionsAreSortedByKeyAcrossAllSources() {
        val actions = SyncPlanner.plan(
            local = mapOf("b.md" to "x"),
            remote = mapOf("a.md" to "y"),
            base = mapOf("c.md" to base),
            openConflicts = emptySet(),
        )
        assertEquals(listOf("a.md", "b.md", "c.md"), actions.map { it.key })
    }
}
