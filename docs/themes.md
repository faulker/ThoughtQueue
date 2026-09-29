# Custom themes

ThoughtQueue ships four built-in themes: **Organic Light** and **Porcelain** (light), **Organic Dark** and **Midnight** (dark). In Preferences > Appearance you pick one light theme and one dark theme. The Dark/Light/System toggle decides which of the two is showing.

You can add your own themes as JSON files.

## Where theme files live

`~/Library/Application Support/ThoughtQueue/Themes/`

Every `*.json` file in that folder is loaded at launch. In Preferences > Appearance:

- **Import Theme…** validates a file, copies it into the folder, and switches to it.
- **Open Themes Folder** reveals the folder in Finder (creating it if needed).
- **Reload** re-reads the folder after you edit a file by hand.

Files that fail to load are listed in red under those buttons with the reason, for example `"accent" is not a #RRGGBB or #RRGGBBAA color`.

## File format

| Field | Required | Notes |
| --- | --- | --- |
| `name` | yes | Shown in the theme pickers. |
| `appearance` | yes | `"light"` or `"dark"`. Decides which picker it appears in. |
| `colors` | no | Any subset of the color keys below. Missing keys use Organic Light or Organic Dark (matching `appearance`). |
| `categoryTints` | no | A non-empty list of `{ "background", "foreground" }` pairs, rotated across category pills. |

Colors are `#RRGGBB` or `#RRGGBBAA` (the last pair is alpha). Unknown color keys are an error, so typos get reported instead of silently ignored.

A minimal theme only needs a name and appearance plus whatever you want to change:

```
{ "name": "Plum", "appearance": "dark", "colors": { "accent": "#b07cc6" } }
```

## Color keys

| Key | Used for |
| --- | --- |
| `surface` | Window, popover, and panel backgrounds |
| `fieldBackground` | Search fields and pill controls |
| `fieldBorder` | Borders of fields |
| `hoverRow` | Row background on hover |
| `divider` | Hairline dividers and card borders (usually translucent) |
| `textPrimary` | Main text |
| `textSecondary` | Secondary and hint text |
| `iconStroke` | Icon color |
| `accent` | Primary buttons and highlights |
| `accentBorder` | Border of accent buttons, section headings |
| `accentText` | Text drawn on an `accent` fill |
| `accentSoftBackground` | Selected rows, checked boxes, pinned state |
| `accentSoftBorder` | Border for the soft accent wash |
| `accentSelectionBackground` | Subtle selected list row |
| `danger` | Delete prompts and errors |
| `iconHoverBackground` | Background behind a hovered icon button (usually translucent) |

## Complete example

Save this as `Ember.json` in the Themes folder and press Reload.

```json
{
  "name": "Ember",
  "appearance": "dark",
  "colors": {
    "surface": "#1c1714",
    "fieldBackground": "#2c2420",
    "fieldBorder": "#46382f",
    "hoverRow": "#241d19",
    "divider": "#ffffff1f",
    "textPrimary": "#f3e6dc",
    "textSecondary": "#a8958a",
    "iconStroke": "#bba699",
    "accent": "#e07a4f",
    "accentBorder": "#b35d3a",
    "accentText": "#2a1206",
    "accentSoftBackground": "#43281c",
    "accentSoftBorder": "#643a27",
    "accentSelectionBackground": "#30261f",
    "danger": "#ff6b6b",
    "iconHoverBackground": "#ffffff1a"
  },
  "categoryTints": [
    { "background": "#3d2a1f", "foreground": "#f0a878" },
    { "background": "#2e3222", "foreground": "#c5d49a" },
    { "background": "#3a2230", "foreground": "#e7a0c4" },
    { "background": "#1f3036", "foreground": "#8cc9d9" }
  ]
}
```
