package com.thoughtqueue.app.ui

import android.net.Uri
import androidx.compose.runtime.Composable
import androidx.navigation.NavType
import androidx.navigation.compose.NavHost
import androidx.navigation.compose.composable
import androidx.navigation.compose.rememberNavController
import androidx.navigation.navArgument
import com.thoughtqueue.app.TqApp

/** Navigation graph: notes list, note, navigator, category manager, settings and sync conflicts. */
@Composable
fun AppNav(app: TqApp) {
    val nav = rememberNavController()

    /** Route for a note by its store-relative path. */
    fun noteRoute(path: String) = "note/" + Uri.encode(path)

    NavHost(nav, startDestination = "list") {
        composable("list") {
            NotesListScreen(
                app,
                onOpenNote = { nav.navigate(noteRoute(it)) },
                onNavigator = { nav.navigate("navigator") },
                onCategories = { nav.navigate("categories") },
                onSettings = { nav.navigate("settings") },
                onConflicts = { nav.navigate("conflicts") },
            )
        }
        composable("note/{path}", arguments = listOf(navArgument("path") { type = NavType.StringType })) {
            val path = Uri.decode(it.arguments?.getString("path").orEmpty())
            NoteScreen(app, path, onBack = { nav.popBackStack() }, onNavigator = { nav.navigate("navigator") })
        }
        composable("navigator") {
            NavigatorScreen(
                app,
                onBack = { nav.popBackStack() },
                onOpenNote = { path ->
                    // Replace any open note so back returns to where the navigator was opened from.
                    nav.navigate(noteRoute(path)) { popUpTo("navigator") { inclusive = true } }
                },
            )
        }
        composable("categories") { CategoryManagerScreen(app, onBack = { nav.popBackStack() }) }
        composable("settings") { SettingsScreen(app, onBack = { nav.popBackStack() }, onConflicts = { nav.navigate("conflicts") }) }
        composable("conflicts") { ConflictsScreen(app, onBack = { nav.popBackStack() }) }
    }
}
