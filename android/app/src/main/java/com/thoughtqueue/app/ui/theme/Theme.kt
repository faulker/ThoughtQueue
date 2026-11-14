package com.thoughtqueue.app.ui.theme

import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.material3.Typography
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.staticCompositionLocalOf
import androidx.compose.ui.text.ExperimentalTextApi
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.Font
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.font.FontVariation
import com.thoughtqueue.app.R
import com.thoughtqueue.app.prefs.ThemeMode

/** The active palette, for code that needs tokens Material does not model (tints, soft accent). */
val LocalPalette = staticCompositionLocalOf { ThemePalette.organicLight }

/** Bundled Figtree variable font as the body face, with the named weights requested explicitly. */
@OptIn(ExperimentalTextApi::class)
val FigtreeFamily = FontFamily(
    Font(R.font.figtree, FontWeight.Normal, variationSettings = FontVariation.Settings(FontVariation.weight(400))),
    Font(R.font.figtree, FontWeight.Medium, variationSettings = FontVariation.Settings(FontVariation.weight(500))),
    Font(R.font.figtree, FontWeight.SemiBold, variationSettings = FontVariation.Settings(FontVariation.weight(600))),
    Font(R.font.figtree, FontWeight.Bold, variationSettings = FontVariation.Settings(FontVariation.weight(700))),
)

/** Georgia-style serif accent face used for headings, as on the desktop. */
val HeadingFamily = FontFamily.Serif

/** Material typography with Figtree everywhere and the serif accent on titles. */
private fun typography(): Typography {
    val base = Typography()
    fun TextStyle.body() = copy(fontFamily = FigtreeFamily)
    fun TextStyle.heading() = copy(fontFamily = HeadingFamily)
    return Typography(
        displayLarge = base.displayLarge.heading(), displayMedium = base.displayMedium.heading(),
        displaySmall = base.displaySmall.heading(),
        headlineLarge = base.headlineLarge.heading(), headlineMedium = base.headlineMedium.heading(),
        headlineSmall = base.headlineSmall.heading(),
        titleLarge = base.titleLarge.heading(), titleMedium = base.titleMedium.body(),
        titleSmall = base.titleSmall.body(),
        bodyLarge = base.bodyLarge.body(), bodyMedium = base.bodyMedium.body(),
        bodySmall = base.bodySmall.body(),
        labelLarge = base.labelLarge.body(), labelMedium = base.labelMedium.body(),
        labelSmall = base.labelSmall.body(),
    )
}

/** Map a palette onto a Material 3 color scheme. */
private fun ThemePalette.toScheme(): androidx.compose.material3.ColorScheme {
    val dark = appearance == ThemeAppearance.DARK
    val base = if (dark) darkColorScheme() else lightColorScheme()
    return base.copy(
        primary = accent, onPrimary = accentText,
        primaryContainer = accentSoftBackground, onPrimaryContainer = textPrimary,
        secondary = accentBorder, onSecondary = accentText,
        secondaryContainer = accentSelectionBackground, onSecondaryContainer = textPrimary,
        tertiary = accentBorder, onTertiary = accentText,
        background = surface, onBackground = textPrimary,
        surface = surface, onSurface = textPrimary,
        surfaceVariant = fieldBackground, onSurfaceVariant = textSecondary,
        surfaceContainer = hoverRow, surfaceContainerHigh = fieldBackground,
        surfaceContainerLow = surface, surfaceContainerHighest = fieldBackground,
        outline = fieldBorder, outlineVariant = divider,
        error = danger, onError = accentText,
    )
}

/**
 * App theme. [mode] picks between [light] and [dark] (SYSTEM follows the device), and the chosen
 * palette is exposed through [MaterialTheme] and [LocalPalette].
 */
@Composable
fun ThoughtQueueTheme(
    mode: ThemeMode,
    light: ThemePalette,
    dark: ThemePalette,
    content: @Composable () -> Unit,
) {
    val useDark = when (mode) {
        ThemeMode.SYSTEM -> isSystemInDarkTheme()
        ThemeMode.LIGHT -> false
        ThemeMode.DARK -> true
    }
    val palette = if (useDark) dark else light
    CompositionLocalProvider(LocalPalette provides palette) {
        MaterialTheme(colorScheme = palette.toScheme(), typography = typography(), content = content)
    }
}
