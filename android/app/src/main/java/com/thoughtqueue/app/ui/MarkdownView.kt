package com.thoughtqueue.app.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Checkbox
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.LinkAnnotation
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.TextLinkStyles
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextDecoration
import androidx.compose.ui.text.withLink
import androidx.compose.ui.text.withStyle
import androidx.compose.ui.unit.dp
import com.thoughtqueue.app.ui.theme.LocalPalette

/** Build an AnnotatedString from inline markdown, styling code, emphasis and links from the palette. */
@Composable
fun inlineText(text: String): AnnotatedString {
    val palette = LocalPalette.current
    return buildAnnotatedString {
        for (span in MarkdownParser.inline(text)) {
            val style = SpanStyle(
                fontWeight = if (span.bold) FontWeight.Bold else null,
                fontStyle = if (span.italic) FontStyle.Italic else null,
                fontFamily = if (span.code) FontFamily.Monospace else null,
                background = if (span.code) palette.fieldBackground else androidx.compose.ui.graphics.Color.Unspecified,
                textDecoration = if (span.strike) TextDecoration.LineThrough else null,
            )
            if (span.url != null) {
                val link = LinkAnnotation.Url(
                    span.url,
                    TextLinkStyles(SpanStyle(color = palette.accentBorder, textDecoration = TextDecoration.Underline)),
                )
                withLink(link) { withStyle(style) { append(span.text) } }
            } else {
                withStyle(style) { append(span.text) }
            }
        }
    }
}

/**
 * Rendered markdown: headings, emphasis, code, lists, quotes, links and clickable task checkboxes.
 * [onToggleTask] receives the source line index, which [com.thoughtqueue.app.store.TaskList.toggle]
 * rewrites surgically.
 */
@Composable
fun MarkdownView(body: String, onToggleTask: (Int) -> Unit, modifier: Modifier = Modifier) {
    val palette = LocalPalette.current
    val type = MaterialTheme.typography
    val blocks = MarkdownParser.parse(body)
    Column(
        modifier.verticalScroll(rememberScrollState()).padding(horizontal = 16.dp, vertical = 8.dp),
        verticalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        for (block in blocks) {
            when (block) {
                is MdBlock.Heading -> Text(
                    inlineText(block.text),
                    style = when (block.level) {
                        1 -> type.headlineMedium
                        2 -> type.headlineSmall
                        3 -> type.titleLarge
                        else -> type.titleMedium
                    },
                    modifier = Modifier.padding(top = 4.dp),
                )
                is MdBlock.Code -> Text(
                    block.text,
                    fontFamily = FontFamily.Monospace,
                    style = type.bodyMedium,
                    modifier = Modifier.fillMaxWidth()
                        .background(palette.fieldBackground, RoundedCornerShape(8.dp)).padding(10.dp),
                )
                is MdBlock.Task -> Row(
                    Modifier.padding(start = (block.indent * 16).dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Checkbox(checked = block.checked, onCheckedChange = { onToggleTask(block.line) })
                    Text(
                        inlineText(block.text),
                        style = type.bodyLarge,
                        color = if (block.checked) palette.textSecondary else palette.textPrimary,
                        textDecoration = if (block.checked) TextDecoration.LineThrough else null,
                    )
                }
                is MdBlock.Bullet -> Row(Modifier.padding(start = (block.indent * 16 + 8).dp)) {
                    Text("•  ", style = type.bodyLarge)
                    Text(inlineText(block.text), style = type.bodyLarge)
                }
                is MdBlock.Ordered -> Row(Modifier.padding(start = (block.indent * 16 + 8).dp)) {
                    Text("${block.number}.  ", style = type.bodyLarge)
                    Text(inlineText(block.text), style = type.bodyLarge)
                }
                is MdBlock.Quote -> Row(Modifier.padding(start = 4.dp)) {
                    Text(
                        inlineText(block.text),
                        style = type.bodyLarge,
                        color = palette.textSecondary,
                        modifier = Modifier.background(palette.hoverRow).padding(8.dp).fillMaxWidth(),
                    )
                }
                MdBlock.Rule -> HorizontalDivider(Modifier.padding(vertical = 4.dp), color = palette.divider)
                is MdBlock.Paragraph -> Text(inlineText(block.text), style = type.bodyLarge)
            }
        }
        Column(Modifier.height(48.dp)) {}
    }
}
