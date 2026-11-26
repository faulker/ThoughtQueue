package com.thoughtqueue.app

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import com.thoughtqueue.app.ui.AppNav
import com.thoughtqueue.app.ui.theme.ThemeAppearance
import com.thoughtqueue.app.ui.theme.ThoughtQueueTheme

/** Single activity hosting the Compose navigation graph, themed from preferences. */
class MainActivity : ComponentActivity() {

    /** Set up edge-to-edge content with the user's chosen theme. */
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        val app = application as TqApp
        setContent {
            val mode by app.prefs.themeMode.collectAsState()
            val lightId by app.prefs.lightThemeId.collectAsState()
            val darkId by app.prefs.darkThemeId.collectAsState()
            val themes by app.themes.themes.collectAsState()
            val light = themes.let { app.themes.resolve(lightId, ThemeAppearance.LIGHT) }
            val dark = themes.let { app.themes.resolve(darkId, ThemeAppearance.DARK) }
            ThoughtQueueTheme(mode, light, dark) { AppNav(app) }
        }
    }
}
