package com.thoughtqueue.app.ui.theme

import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import java.io.File
import java.io.IOException

/** A theme file that failed to load, with a readable reason for Settings to show. */
data class ThemeLoadFailure(val fileName: String, val reason: String)

/**
 * Owns the available themes: the four built-ins plus custom JSON files in [folder]. Custom files
 * are read on [reload], which runs at launch, after an import and from Settings. Pure Kotlin so it
 * is testable against a temp directory.
 */
class ThemeLibrary(val folder: File) {
    private val _themes = MutableStateFlow(ThemePalette.builtIns)
    private val _failures = MutableStateFlow<List<ThemeLoadFailure>>(emptyList())

    /** Every available theme, built-ins first, then custom themes sorted by name. */
    val themes: StateFlow<List<ThemePalette>> = _themes.asStateFlow()

    /** Custom theme files that failed to load. */
    val failures: StateFlow<List<ThemeLoadFailure>> = _failures.asStateFlow()

    /** Themes designed for one appearance, built-ins first. */
    fun themes(appearance: ThemeAppearance): List<ThemePalette> =
        _themes.value.filter { it.appearance == appearance }

    /**
     * The theme with [id] if it exists for that appearance, else that appearance's Organic
     * built-in, so a synced id for a theme missing on this device degrades gracefully.
     */
    fun resolve(id: String?, appearance: ThemeAppearance): ThemePalette =
        _themes.value.firstOrNull { it.id == id && it.appearance == appearance }
            ?: if (appearance == ThemeAppearance.DARK) ThemePalette.organicDark else ThemePalette.organicLight

    /** Re-scan the folder. A missing folder just means no custom themes. */
    fun reload() {
        val (custom, failures) = loadCustomThemes(folder)
        _themes.value = ThemePalette.builtIns + custom
        _failures.value = failures
    }

    /**
     * Validate [text] as a theme, save it as [fileName] in the folder (replacing a same-named
     * file) and reload. Returns the imported theme. Throws [ThemeDecodeException] for an invalid
     * theme and [IOException] when the copy fails.
     */
    fun importTheme(fileName: String, text: String): ThemePalette {
        val safeName = File(fileName).name.let { if (it.endsWith(".json", ignoreCase = true)) it else "$it.json" }
        val id = customId(safeName)
        ThemePalette.decode(text, id)
        if (!folder.isDirectory && !folder.mkdirs()) throw IOException("cannot create ${folder.path}")
        File(folder, safeName).writeText(text, Charsets.UTF_8)
        reload()
        return _themes.value.firstOrNull { it.id == id }
            ?: throw IOException("The theme did not load after copying.")
    }

    companion object {
        /** Preference id for a custom theme file: `custom:` plus the file name without extension. */
        fun customId(fileName: String): String = "custom:" + File(fileName).nameWithoutExtension

        /** Read every `*.json` in [folder], returning themes sorted by name and failures by file. */
        fun loadCustomThemes(folder: File): Pair<List<ThemePalette>, List<ThemeLoadFailure>> {
            val files = folder.listFiles() ?: return emptyList<ThemePalette>() to emptyList()
            val themes = ArrayList<ThemePalette>()
            val failures = ArrayList<ThemeLoadFailure>()
            for (file in files) {
                if (file.name.startsWith(".") || file.extension.lowercase() != "json") continue
                try {
                    themes.add(ThemePalette.decode(file.readText(Charsets.UTF_8), customId(file.name)))
                } catch (e: ThemeDecodeException) {
                    failures.add(ThemeLoadFailure(file.name, e.message ?: "invalid theme"))
                } catch (e: IOException) {
                    failures.add(ThemeLoadFailure(file.name, e.message ?: "unreadable"))
                }
            }
            themes.sortWith { a, b -> a.name.compareTo(b.name, ignoreCase = true) }
            failures.sortBy { it.fileName }
            return themes to failures
        }
    }
}
