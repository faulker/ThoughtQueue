package com.thoughtqueue.app.ui

import androidx.compose.ui.graphics.Color
import com.thoughtqueue.app.ui.theme.ThemeAppearance
import com.thoughtqueue.app.ui.theme.ThemeDecodeException
import com.thoughtqueue.app.ui.theme.ThemeLibrary
import com.thoughtqueue.app.ui.theme.ThemePalette
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test
import java.nio.file.Files

/** Theme decoding per docs/themes.md, and the library's folder handling. */
class ThemePaletteTest {
    @Test fun builtInsMatchDesktopValues() {
        assertEquals(listOf("organic-light", "porcelain", "organic-dark", "midnight"), ThemePalette.builtIns.map { it.id })
        assertEquals(Color(0xFF7A8A5E), ThemePalette.organicLight.accent)
        assertEquals(Color(0xFF5FB3A8), ThemePalette.midnight.accent)
        assertEquals(ThemeAppearance.DARK, ThemePalette.organicDark.appearance)
    }

    @Test fun parseHexIsStrict() {
        assertEquals(Color(0xFF112233), ThemePalette.parseHex("#112233"))
        assertEquals(Color(0x80112233), ThemePalette.parseHex("#11223380"))
        assertNull(ThemePalette.parseHex("112233"))
        assertNull(ThemePalette.parseHex("#12345"))
        assertNull(ThemePalette.parseHex("#gggggg"))
    }

    @Test fun minimalThemeInheritsFromOrganic() {
        val p = ThemePalette.decode("""{ "name": "Plum", "appearance": "dark", "colors": { "accent": "#b07cc6" } }""", "custom:plum")
        assertEquals(Color(0xFFB07CC6), p.accent)
        assertEquals(ThemePalette.organicDark.surface, p.surface)
        assertEquals("custom:plum", p.id)
        assertTrue(!p.isBuiltIn)
    }

    @Test fun docsExampleDecodes() {
        val doc = java.io.File("../../docs/themes.md")
        if (!doc.exists()) return // the repo docs are only reachable from a full checkout
        val json = doc.readText().substringAfter("```json\n").substringBefore("\n```")
        val p = ThemePalette.decode(json, "custom:ember")
        assertEquals("Ember", p.name)
        assertEquals(4, p.categoryTints.size)
        assertEquals(Color(0xFFE07A4F), p.accent)
    }

    @Test fun malformedThemesReportReadableErrors() {
        fun message(json: String): String = try {
            ThemePalette.decode(json, "x"); fail("expected failure"); ""
        } catch (e: ThemeDecodeException) { e.message!! }
        assertEquals("file is not a JSON object", message("[1]"))
        assertEquals("missing \"name\"", message("""{"appearance":"dark"}"""))
        assertEquals("missing \"appearance\"", message("""{"name":"a"}"""))
        assertTrue(message("""{"name":"a","appearance":"blue"}""").contains("must be"))
        assertEquals("unknown color \"nope\"", message("""{"name":"a","appearance":"dark","colors":{"nope":"#000000"}}"""))
        assertTrue(message("""{"name":"a","appearance":"dark","colors":{"accent":"red"}}""").contains("is not a #RRGGBB"))
        assertTrue(message("""{"name":"a","appearance":"dark","categoryTints":[]}""").contains("categoryTints"))
    }

    @Test fun libraryLoadsImportsAndReportsFailures() {
        val dir = Files.createTempDirectory("tq-themes").toFile().resolve("themes")
        val lib = ThemeLibrary(dir)
        lib.reload()
        assertEquals(4, lib.themes.value.size)
        val imported = lib.importTheme("Plum.json", """{"name":"Plum","appearance":"light"}""")
        assertEquals("custom:Plum", imported.id)
        assertEquals(5, lib.themes.value.size)
        assertEquals("Plum", lib.resolve("custom:Plum", ThemeAppearance.LIGHT).name)
        assertEquals("Organic Dark", lib.resolve("custom:Plum", ThemeAppearance.DARK).name)
        java.io.File(dir, "bad.json").writeText("{")
        lib.reload()
        assertEquals("bad.json", lib.failures.value.single().fileName)
        try {
            lib.importTheme("x.json", "{}")
            fail("expected invalid theme")
        } catch (e: ThemeDecodeException) {
            assertTrue(!java.io.File(dir, "x.json").exists())
        }
        dir.parentFile.deleteRecursively()
    }
}
