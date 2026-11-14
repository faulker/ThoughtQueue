package com.thoughtqueue.app.ui

import android.annotation.SuppressLint
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.Search
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.produceState
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.unit.dp
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.style.TextOverflow
import com.thoughtqueue.app.store.NoteStore
import com.thoughtqueue.app.ui.theme.LocalPalette
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

/**
 * Run a store query off the main thread and re-run it whenever the store signals a change (the
 * `.notesDidChange` equivalent). Returns [initial] until the first result arrives.
 * The lint suppression covers a false positive: `value` is assigned inside the producer.
 */
@SuppressLint("ProduceStateDoesNotAssignValue")
@Composable
fun <T> storeQuery(store: NoteStore, initial: T, block: NoteStore.() -> T): T {
    val version by store.changes.collectAsState()
    val state = produceState(initial, store, version) {
        value = withContext(Dispatchers.IO) { store.block() }
    }
    return state.value
}

/** A back arrow icon button for top bars. */
@Composable
fun BackButton(onBack: () -> Unit) {
    IconButton(onClick = onBack) {
        Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = "Back")
    }
}

/** A flat pill-shaped search input styled from the active palette. */
@Composable
fun SearchField(value: String, onValueChange: (String) -> Unit, modifier: Modifier = Modifier, hint: String = "Search") {
    val palette = LocalPalette.current
    Row(
        modifier = modifier
            .fillMaxWidth()
            .background(palette.fieldBackground, RoundedCornerShape(24.dp))
            .padding(horizontal = 14.dp, vertical = 10.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        Icon(Icons.Default.Search, contentDescription = null, tint = palette.iconStroke)
        Box(Modifier.weight(1f)) {
            if (value.isEmpty()) Text(hint, color = palette.textSecondary, style = MaterialTheme.typography.bodyLarge)
            BasicTextField(
                value = value,
                onValueChange = onValueChange,
                singleLine = true,
                textStyle = MaterialTheme.typography.bodyLarge.copy(color = palette.textPrimary),
                cursorBrush = SolidColor(palette.accent),
                modifier = Modifier.fillMaxWidth(),
            )
        }
    }
}

/** A small rounded category label tinted by the palette's rotating category tints. */
@Composable
fun CategoryPill(name: String, tintIndex: Int, modifier: Modifier = Modifier) {
    val tints = LocalPalette.current.categoryTints
    val tint = tints[Math.floorMod(tintIndex, tints.size)]
    Text(
        name,
        modifier = modifier
            .background(tint.background, RoundedCornerShape(10.dp))
            .padding(horizontal = 8.dp, vertical = 2.dp),
        color = tint.foreground,
        style = MaterialTheme.typography.labelSmall,
        maxLines = 1,
        overflow = TextOverflow.Ellipsis,
    )
}

/** Stable tint index for a category name, so a category keeps its color across screens. */
fun tintIndex(category: String?): Int = (category ?: "").hashCode()

/** Default screen padding. */
val ScreenPadding = PaddingValues(horizontal = 16.dp)

/** Transparent color shorthand. */
val Clear = Color.Transparent
