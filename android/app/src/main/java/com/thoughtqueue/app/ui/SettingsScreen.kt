package com.thoughtqueue.app.ui

import android.content.Context
import android.net.Uri
import android.provider.OpenableColumns
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.consumeWindowInsets
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.ArrowDropDown
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Scaffold
import androidx.compose.material3.SegmentedButton
import androidx.compose.material3.SegmentedButtonDefaults
import androidx.compose.material3.SingleChoiceSegmentedButtonRow
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import com.thoughtqueue.app.TqApp
import com.thoughtqueue.app.prefs.EditMode
import com.thoughtqueue.app.prefs.ThemeMode
import com.thoughtqueue.app.ui.theme.LocalPalette
import com.thoughtqueue.app.ui.theme.ThemeAppearance
import com.thoughtqueue.app.ui.theme.ThemeDecodeException
import com.thoughtqueue.app.ui.theme.ThemePalette
import java.io.IOException

/** Read a picked document's text and display name through the content resolver. */
private fun readPicked(context: Context, uri: Uri): Pair<String, String> {
    val name = context.contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)?.use {
        if (it.moveToFirst()) it.getString(0) else null
    } ?: "theme.json"
    val text = context.contentResolver.openInputStream(uri)?.use { it.readBytes().toString(Charsets.UTF_8) }
        ?: throw IOException("Could not open the file")
    return name to text
}

/**
 * Settings: appearance mode, light and dark theme pickers, theme import (document picker copies
 * the JSON into the app's themes folder), the default edit mode, Storage & Sync, and updates.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun SettingsScreen(app: TqApp, onBack: () -> Unit, onConflicts: () -> Unit) {
    val context = LocalContext.current
    val prefs = app.prefs
    val mode by prefs.themeMode.collectAsState()
    val lightId by prefs.lightThemeId.collectAsState()
    val darkId by prefs.darkThemeId.collectAsState()
    val editMode by prefs.editMode.collectAsState()
    val themes by app.themes.themes.collectAsState()
    val failures by app.themes.failures.collectAsState()
    var importMessage by remember { mutableStateOf<String?>(null) }
    val palette = LocalPalette.current

    val picker = rememberLauncherForActivityResult(ActivityResultContracts.OpenDocument()) { uri ->
        if (uri != null) {
            importMessage = try {
                val (name, text) = readPicked(context, uri)
                val theme = app.themes.importTheme(name, text)
                if (theme.appearance == ThemeAppearance.DARK) prefs.setDarkThemeId(theme.id) else prefs.setLightThemeId(theme.id)
                "Imported ${theme.name}"
            } catch (e: ThemeDecodeException) {
                "Invalid theme: ${e.message}"
            } catch (e: IOException) {
                "Import failed: ${e.message}"
            }
        }
    }

    Scaffold(topBar = { TopAppBar(title = { Text("Settings") }, navigationIcon = { BackButton(onBack) }) }) { padding ->
        Column(
            Modifier.padding(padding).consumeWindowInsets(padding).imePadding().fillMaxSize().verticalScroll(rememberScrollState()).padding(16.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            Text("Appearance", style = MaterialTheme.typography.titleMedium, color = palette.accentBorder)
            SingleChoiceSegmentedButtonRow(Modifier.fillMaxWidth()) {
                ThemeMode.entries.forEachIndexed { i, m ->
                    SegmentedButton(
                        selected = mode == m,
                        onClick = { prefs.setThemeMode(m) },
                        shape = SegmentedButtonDefaults.itemShape(i, ThemeMode.entries.size),
                    ) { Text(m.name.lowercase().replaceFirstChar { it.uppercase() }) }
                }
            }
            ThemePicker("Light theme", themes.filter { it.appearance == ThemeAppearance.LIGHT }, lightId ?: "organic-light") {
                prefs.setLightThemeId(it)
            }
            ThemePicker("Dark theme", themes.filter { it.appearance == ThemeAppearance.DARK }, darkId ?: "organic-dark") {
                prefs.setDarkThemeId(it)
            }
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                OutlinedButton(onClick = { picker.launch(arrayOf("application/json", "text/plain", "*/*")) }) {
                    Text("Import theme")
                }
                TextButton(onClick = { app.themes.reload() }) { Text("Reload") }
            }
            importMessage?.let { Text(it, style = MaterialTheme.typography.bodyMedium) }
            for (f in failures) {
                Text("${f.fileName}: ${f.reason}", color = palette.danger, style = MaterialTheme.typography.bodySmall)
            }

            HorizontalDivider(color = palette.divider)
            Text("Editing", style = MaterialTheme.typography.titleMedium, color = palette.accentBorder)
            Text("Open markdown notes in", style = MaterialTheme.typography.bodyMedium)
            SingleChoiceSegmentedButtonRow(Modifier.fillMaxWidth()) {
                EditMode.entries.forEachIndexed { i, m ->
                    SegmentedButton(
                        selected = editMode == m,
                        onClick = { prefs.setEditMode(m) },
                        shape = SegmentedButtonDefaults.itemShape(i, EditMode.entries.size),
                    ) { Text(if (m == EditMode.RENDERED) "Rendered" else "Raw") }
                }
            }

            HorizontalDivider(color = palette.divider)
            SyncSettingsSection(app, onConflicts)

            HorizontalDivider(color = palette.divider)
            UpdateSettingsSection(app)
        }
    }
}

/** A labelled dropdown choosing one theme from [options]; [selectedId] is shown as the current value. */
@Composable
private fun ThemePicker(label: String, options: List<ThemePalette>, selectedId: String, onSelect: (String) -> Unit) {
    var open by remember { mutableStateOf(false) }
    val current = options.firstOrNull { it.id == selectedId } ?: options.firstOrNull()
    Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
        Text(label, Modifier.padding(top = 12.dp))
        Column {
            TextButton(onClick = { open = true }) {
                Text(current?.name ?: "Default")
                Icon(Icons.Default.ArrowDropDown, null)
            }
            DropdownMenu(expanded = open, onDismissRequest = { open = false }) {
                for (t in options) {
                    DropdownMenuItem(text = { Text(t.name) }, onClick = { open = false; onSelect(t.id) })
                }
            }
        }
    }
}
