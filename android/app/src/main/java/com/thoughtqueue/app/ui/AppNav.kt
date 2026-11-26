package com.thoughtqueue.app.ui

import android.net.Uri
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.key
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.runtime.mutableStateOf
import androidx.navigation.NavType
import androidx.navigation.compose.NavHost
import androidx.navigation.compose.composable
import androidx.navigation.compose.rememberNavController
import androidx.navigation.navArgument
import com.thoughtqueue.app.TqApp

/** Navigation graph: notes list, note, category manager, sync conflicts, and the settings pages. */
@Composable
fun AppNav(app: TqApp) {
    val nav = rememberNavController()
    // Lives here, not in the list screen, so a note's Home / hamburger buttons can pick the view.
    var listMode by rememberSaveable { mutableStateOf(ListMode.BY_CATEGORY) }

    /** Return to the notes list showing [mode]. */
    fun showList(mode: ListMode) {
        listMode = mode
        nav.popBackStack("list", inclusive = false)
    }

    /** Route for a note by its store-relative path. */
    fun noteRoute(path: String) = "note/" + Uri.encode(path)
    val back: () -> Unit = { nav.popBackStack() }

    // Screens that read the note store are rebuilt when the storage mode moves it to another
    // root. Only those are keyed: keying the whole graph would reset the back stack, which is
    // what used to throw the user out of Settings when they picked a storage mode.
    val store by app.storeFlow.collectAsState()

    NavHost(nav, startDestination = "list") {
        composable("list") {
            key(store) {
                NotesListScreen(
                    app,
                    mode = listMode,
                    onModeChange = { listMode = it },
                    onOpenNote = { nav.navigate(noteRoute(it)) },
                    onCategories = { nav.navigate("categories") },
                    onSettings = { nav.navigate("settings") },
                    onConflicts = { nav.navigate("conflicts") },
                )
            }
        }
        composable("note/{path}", arguments = listOf(navArgument("path") { type = NavType.StringType })) {
            val path = Uri.decode(it.arguments?.getString("path").orEmpty())
            key(store) {
                NoteScreen(
                    app, path,
                    onBack = { nav.popBackStack() },
                    onNotesList = { showList(ListMode.BY_CATEGORY) },
                    onHome = { showList(ListMode.RECENT) },
                )
            }
        }
        composable("categories") { key(store) { CategoryManagerScreen(app, onBack = back) } }
        composable("conflicts") { key(store) { ConflictsScreen(app, onBack = back) } }
        composable("settings") {
            SettingsScreen(
                app,
                onBack = back,
                onAppearance = { nav.navigate("settings/appearance") },
                onEditing = { nav.navigate("settings/editing") },
                onSync = { nav.navigate("settings/sync") },
                onUpdates = { nav.navigate("settings/updates") },
            )
        }
        composable("settings/appearance") { AppearanceSettingsScreen(app, onBack = back) }
        composable("settings/editing") { EditingSettingsScreen(app, onBack = back) }
        composable("settings/sync") {
            SyncSettingsScreen(
                app,
                onBack = back,
                onConflicts = { nav.navigate("conflicts") },
                onS3 = { nav.navigate("settings/sync/s3") },
            )
        }
        composable("settings/sync/s3") { S3SettingsScreen(app, onBack = back) }
        composable("settings/updates") { UpdateSettingsScreen(app, onBack = back) }
    }
}
