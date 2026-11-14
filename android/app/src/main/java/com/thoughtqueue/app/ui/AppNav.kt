package com.thoughtqueue.app.ui

import android.net.Uri
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.runtime.mutableStateOf
import androidx.navigation.NavType
import androidx.navigation.compose.NavHost
import androidx.navigation.compose.composable
import androidx.navigation.compose.rememberNavController
import androidx.navigation.navArgument
import com.thoughtqueue.app.TqApp

/** Navigation graph: notes list, note, category manager, settings and sync conflicts. */
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

    NavHost(nav, startDestination = "list") {
        composable("list") {
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
        composable("note/{path}", arguments = listOf(navArgument("path") { type = NavType.StringType })) {
            val path = Uri.decode(it.arguments?.getString("path").orEmpty())
            NoteScreen(
                app, path,
                onBack = { nav.popBackStack() },
                onNotesList = { showList(ListMode.BY_CATEGORY) },
                onHome = { showList(ListMode.RECENT) },
            )
        }
        composable("categories") { CategoryManagerScreen(app, onBack = { nav.popBackStack() }) }
        composable("settings") { SettingsScreen(app, onBack = { nav.popBackStack() }, onConflicts = { nav.navigate("conflicts") }) }
        composable("conflicts") { ConflictsScreen(app, onBack = { nav.popBackStack() }) }
    }
}
