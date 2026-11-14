package com.thoughtqueue.app.ui.theme

import androidx.compose.ui.graphics.Color
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive

/** Which system appearance a palette is designed for. */
enum class ThemeAppearance { LIGHT, DARK }

/** A category pill tint pair. */
data class Tint(val background: Color, val foreground: Color)

/** A theme file failed validation. The message is shown to the user as is. */
class ThemeDecodeException(message: String) : Exception(message)

/**
 * One complete set of color tokens for a single appearance (port of the desktop `ThemePalette`).
 * Custom themes are JSON files (see `docs/themes.md`); any color a file leaves out falls back to
 * the built-in Organic palette of the same appearance.
 */
data class ThemePalette(
    /** Stable id stored in prefs. Built-ins use a bare slug, custom files use `custom:<name>`. */
    val id: String,
    val name: String,
    val appearance: ThemeAppearance,
    val isBuiltIn: Boolean,
    val surface: Color,
    val fieldBackground: Color,
    val fieldBorder: Color,
    val hoverRow: Color,
    val divider: Color,
    val textPrimary: Color,
    val textSecondary: Color,
    val iconStroke: Color,
    val accent: Color,
    val accentBorder: Color,
    val accentText: Color,
    val accentSoftBackground: Color,
    val accentSoftBorder: Color,
    val accentSelectionBackground: Color,
    val danger: Color,
    val iconHoverBackground: Color,
    val categoryTints: List<Tint>,
) {
    /** Copy with the color token named [key] replaced; false-y keys are rejected by the caller. */
    private fun withColor(key: String, c: Color): ThemePalette = when (key) {
        "surface" -> copy(surface = c)
        "fieldBackground" -> copy(fieldBackground = c)
        "fieldBorder" -> copy(fieldBorder = c)
        "hoverRow" -> copy(hoverRow = c)
        "divider" -> copy(divider = c)
        "textPrimary" -> copy(textPrimary = c)
        "textSecondary" -> copy(textSecondary = c)
        "iconStroke" -> copy(iconStroke = c)
        "accent" -> copy(accent = c)
        "accentBorder" -> copy(accentBorder = c)
        "accentText" -> copy(accentText = c)
        "accentSoftBackground" -> copy(accentSoftBackground = c)
        "accentSoftBorder" -> copy(accentSoftBorder = c)
        "accentSelectionBackground" -> copy(accentSelectionBackground = c)
        "danger" -> copy(danger = c)
        "iconHoverBackground" -> copy(iconHoverBackground = c)
        else -> throw ThemeDecodeException("unknown color \"$key\"")
    }

    companion object {
        /** JSON key of every color token, in the order the docs list them. */
        val colorKeys = listOf(
            "surface", "fieldBackground", "fieldBorder", "hoverRow", "divider", "textPrimary",
            "textSecondary", "iconStroke", "accent", "accentBorder", "accentText",
            "accentSoftBackground", "accentSoftBorder", "accentSelectionBackground", "danger",
            "iconHoverBackground",
        )

        /** Strict `#RRGGBB` / `#RRGGBBAA` parser (the last pair is alpha). Null on anything else. */
        fun parseHex(string: String): Color? {
            val s = string.trim()
            if (!s.startsWith("#")) return null
            val digits = s.substring(1)
            if (digits.length != 6 && digits.length != 8) return null
            if (!digits.all { it in '0'..'9' || it in 'a'..'f' || it in 'A'..'F' }) return null
            val r = digits.substring(0, 2).toInt(16)
            val g = digits.substring(2, 4).toInt(16)
            val b = digits.substring(4, 6).toInt(16)
            val a = if (digits.length == 8) digits.substring(6, 8).toInt(16) else 255
            return Color(r, g, b, a)
        }

        /**
         * Decode a theme file. Missing colors inherit from the Organic palette of the file's
         * appearance. Anything malformed throws [ThemeDecodeException] with a readable reason.
         */
        fun decode(text: String, id: String): ThemePalette {
            val root = try {
                Json.parseToJsonElement(text) as? JsonObject
            } catch (e: Exception) {
                null
            } ?: throw ThemeDecodeException("file is not a JSON object")

            val name = (root["name"] as? JsonPrimitive)?.content?.trim()
            if (name.isNullOrEmpty()) throw ThemeDecodeException("missing \"name\"")
            val appearanceRaw = (root["appearance"] as? JsonPrimitive)?.content
                ?: throw ThemeDecodeException("missing \"appearance\"")
            val appearance = when (appearanceRaw.lowercase()) {
                "light" -> ThemeAppearance.LIGHT
                "dark" -> ThemeAppearance.DARK
                else -> throw ThemeDecodeException(
                    "appearance must be \"light\" or \"dark\", got \"$appearanceRaw\"",
                )
            }

            var palette = (if (appearance == ThemeAppearance.DARK) organicDark else organicLight)
                .copy(id = id, name = name, isBuiltIn = false)

            (root["colors"] as? JsonObject)?.forEach { (key, value) ->
                if (key !in colorKeys) throw ThemeDecodeException("unknown color \"$key\"")
                val hex = (value as? JsonPrimitive)?.takeIf { it.isString }?.content
                val color = hex?.let(::parseHex)
                    ?: throw ThemeDecodeException(
                        "\"$key\" is not a #RRGGBB or #RRGGBBAA color: \"${(value as? JsonPrimitive)?.content ?: value}\"",
                    )
                palette = palette.withColor(key, color)
            }

            root["categoryTints"]?.let { raw ->
                val invalid = "categoryTints must be a non-empty list of {background, foreground} colors"
                val list = raw as? JsonArray
                if (list == null || list.isEmpty()) throw ThemeDecodeException(invalid)
                palette = palette.copy(categoryTints = list.map { entry ->
                    val obj = try { entry.jsonObject } catch (e: Exception) { throw ThemeDecodeException(invalid) }
                    val bg = obj["background"]?.jsonPrimitive?.content?.let(::parseHex)
                    val fg = obj["foreground"]?.jsonPrimitive?.content?.let(::parseHex)
                    if (bg == null || fg == null) throw ThemeDecodeException(invalid)
                    Tint(bg, fg)
                })
            }
            return palette
        }

        private fun hex(s: String): Color = parseHex(s)!!
        private fun black(alpha: Float) = Color.Black.copy(alpha = alpha)
        private fun white(alpha: Float) = Color.White.copy(alpha = alpha)

        /** The four built-in palettes, in picker order. */
        val builtIns: List<ThemePalette> by lazy { listOf(organicLight, porcelain, organicDark, midnight) }

        /** The original warm cream and sage light palette. */
        val organicLight = ThemePalette(
            id = "organic-light", name = "Organic Light", appearance = ThemeAppearance.LIGHT, isBuiltIn = true,
            surface = hex("#f9f4ed"),
            fieldBackground = hex("#ebddc5"),
            fieldBorder = hex("#c0b6a5"),
            hoverRow = hex("#f2ead9"),
            divider = hex("#201e1d").copy(alpha = 0.12f),
            textPrimary = hex("#201e1d"),
            textSecondary = hex("#82796a"),
            iconStroke = hex("#645c50"),
            accent = hex("#7a8a5e"),
            accentBorder = hex("#56633f"),
            accentText = hex("#f0fae1"),
            accentSoftBackground = hex("#ccdbb2"),
            accentSoftBorder = hex("#aebf92"),
            accentSelectionBackground = hex("#ebddc5"),
            danger = hex("#c0301b"),
            iconHoverBackground = black(0.06f),
            categoryTints = listOf(
                Tint(hex("#fff2eb"), hex("#8c491a")),
                Tint(hex("#f0fae1"), hex("#3d472b")),
                Tint(hex("#ffe1d0"), hex("#8c491a")),
                Tint(hex("#e1eecc"), hex("#3d472b")),
            ),
        )

        /** The warm dark counterpart to Organic Light. */
        val organicDark = ThemePalette(
            id = "organic-dark", name = "Organic Dark", appearance = ThemeAppearance.DARK, isBuiltIn = true,
            surface = hex("#211e19"),
            fieldBackground = hex("#34302a"),
            fieldBorder = hex("#4a453c"),
            hoverRow = hex("#2a261f"),
            divider = white(0.12f),
            textPrimary = hex("#f1e9db"),
            textSecondary = hex("#a89a86"),
            iconStroke = hex("#b3a693"),
            accent = hex("#8fa06d"),
            accentBorder = hex("#6b7a4f"),
            accentText = hex("#1c2410"),
            accentSoftBackground = hex("#333d24"),
            accentSoftBorder = hex("#4c5a37"),
            accentSelectionBackground = hex("#332f27"),
            danger = hex("#ff6b52"),
            iconHoverBackground = white(0.10f),
            categoryTints = listOf(
                Tint(hex("#3a2a1f"), hex("#e8a06a")),
                Tint(hex("#2c3322"), hex("#b9cf94")),
                Tint(hex("#402c1f"), hex("#eda876")),
                Tint(hex("#29331f"), hex("#c3d99e")),
            ),
        )

        /** A cool, crisp light theme with a slate-blue accent. */
        val porcelain = ThemePalette(
            id = "porcelain", name = "Porcelain", appearance = ThemeAppearance.LIGHT, isBuiltIn = true,
            surface = hex("#f7f8fa"),
            fieldBackground = hex("#e6eaf0"),
            fieldBorder = hex("#bcc4d0"),
            hoverRow = hex("#eef1f5"),
            divider = hex("#1b2330").copy(alpha = 0.12f),
            textPrimary = hex("#1b2330"),
            textSecondary = hex("#6a7485"),
            iconStroke = hex("#4f5a6b"),
            accent = hex("#4a6fa5"),
            accentBorder = hex("#35547f"),
            accentText = hex("#f4f8ff"),
            accentSoftBackground = hex("#cfdcf0"),
            accentSoftBorder = hex("#a9bee0"),
            accentSelectionBackground = hex("#e2e8f1"),
            danger = hex("#c62f3b"),
            iconHoverBackground = black(0.06f),
            categoryTints = listOf(
                Tint(hex("#e5edfa"), hex("#2f4f80")),
                Tint(hex("#e3f4f1"), hex("#1f5d55")),
                Tint(hex("#efe8fa"), hex("#553a85")),
                Tint(hex("#fbeae6"), hex("#8a3b2b")),
            ),
        )

        /** A deep navy dark theme with a soft teal accent. */
        val midnight = ThemePalette(
            id = "midnight", name = "Midnight", appearance = ThemeAppearance.DARK, isBuiltIn = true,
            surface = hex("#161b26"),
            fieldBackground = hex("#232a38"),
            fieldBorder = hex("#343d4f"),
            hoverRow = hex("#1d2330"),
            divider = white(0.10f),
            textPrimary = hex("#e3e8f1"),
            textSecondary = hex("#8d97a8"),
            iconStroke = hex("#a3adbd"),
            accent = hex("#5fb3a8"),
            accentBorder = hex("#44867d"),
            accentText = hex("#0d1f1c"),
            accentSoftBackground = hex("#1f3a3a"),
            accentSoftBorder = hex("#2e5451"),
            accentSelectionBackground = hex("#262e3d"),
            danger = hex("#ff6b6b"),
            iconHoverBackground = white(0.10f),
            categoryTints = listOf(
                Tint(hex("#1e2c42"), hex("#8fb4ec")),
                Tint(hex("#1c3432"), hex("#86d1c6")),
                Tint(hex("#2c2442"), hex("#b9a2ec")),
                Tint(hex("#3a2628"), hex("#eea3a0")),
            ),
        )
    }
}
