# Design system

Hana looks clean, minimal and Mac-native: near-monochrome grays, one near-black anchor, translucent black for states, and large concentric corners. The visual reference is [Anish's lab](https://lab.anishfn.ink/); the palette is [Vercel Geist's colors](https://vercel.com/geist/colors).

The system has two layers. Geist's scales are the only raw palette. Views use named **roles**, each pointing to one Geist step or to a value Geist does not have. Code never uses a raw color or a Geist step directly; to change how something looks, change or add a role.

Typography, spacing, radius, elevation, motion and iconography are not written yet. Until they are, [`BarStyle`](../Sources/Hana/BarStyle.swift) remains the source for the Search bar's geometry, type and motion.

## Color

Code: [`HanaColor.swift`](../Sources/Hana/HanaColor.swift). `Geist` holds the palette and `HanaColor` the roles; the role `text.primary` is `HanaColor.Text.primary`.

### Palette

Geist gives each step a fixed job, and roles follow it:

| Steps | Job |
| --- | --- |
| 100–300 | Component backgrounds: default, hover, active |
| 400–600 | Borders: default, hover, active |
| 700–800 | High-contrast backgrounds |
| 900 | Secondary text and icons |
| 1000 | Primary text and icons |

`background-100` and `background-200` are the two page backgrounds. The gray-alpha scale is black at fixed opacities, for anything drawn over another surface.

Values were read from Geist's live page on 2026-10-15. Grays are sRGB. Chromatic steps are Display P3, which Geist specifies and Mac displays show; the values are rounded to 8 bits.

| Step | gray | gray-alpha |
| --- | --- | --- |
| 100 | `#f2f2f2` | 5% |
| 200 | `#ebebeb` | 8% |
| 300 | `#e6e6e6` | 10% |
| 400 | `#ebebeb` | 8% |
| 500 | `#c9c9c9` | 21% |
| 600 | `#a8a8a8` | 34% |
| 700 | `#8f8f8f` | 44% |
| 800 | `#7d7d7d` | 51% |
| 900 | `#4d4d4d` | 70% |
| 1000 | `#171717` | 91% |

Only the chromatic steps a role uses are in code: red-900 `#c62128`, amber-900 `#9e5200` and green-900 `#397c3b`. Add others from Geist's page when a role needs them.

### Roles

| Role | Geist step | Use |
| --- | --- | --- |
| **Surfaces** | | |
| `surface.window` | background-200 | Main window and Note window backgrounds |
| `surface.card` | background-100 | The Search bar's card; the selected segment of a segmented control |
| `surface.group` | gray-100 | Grouped lists in working windows |
| `surface.groupHover` | gray-300 | A row hovered inside a group |
| `bezel.tint` | white 35% (not Geist) | Tint over the Search bar's behind-window material |
| **Controls and rows** | | |
| `control.fill` | gray-200 | Segmented controls, search fields, chips |
| `control.hover` | gray-300 | A hovered control |
| `row.hover` | gray-alpha-100 | A row under the pointer |
| `row.selected` | gray-alpha-200 | The selected row, such as the Search bar's selected result |
| `fill.primary` | gray-1000 | The one primary button in a view |
| `scroll.thumb` | gray-alpha-500 | Scroll thumbs |
| **Text and icons** | | |
| `text.primary` | gray-1000 | Typed text, names, titles; the insertion point |
| `text.secondary` | gray-900 | Paths, mode labels, notices, supporting text |
| `text.tertiary` | gray-800 | Type labels, counts, dates, section labels |
| `text.placeholder` | gray-800 | Empty-input hints |
| `text.faint` | gray-500 | Separators and unchecked task circles |
| `text.onPrimary` | background-100 | Text on `fill.primary` |
| `icon.primary` | gray-1000 | Mode icons and active icons |
| `icon.secondary` | gray-800 | Symbol icons in rows |
| **Lines and states** | | |
| `border.hairline` | gray-alpha-400 | Dividers and outlines |
| `focus.ring` | gray-1000 | Keyboard focus |
| `status.error` | red-900 | A failure the user must act on |
| `status.warning` | amber-900 | A risk the user should notice |
| `status.success` | green-900 | Confirmation that needs a color |

### Rules

- **Monochrome first.** Hana has no accent color. Focus, selection and the primary button are near-black. Color appears only for status, and for Note and Task tints if those are ever added as roles.
- **Translucent black for states.** Hover and selection use gray-alpha so they work on any surface, white or gray.
- **Text and icons share steps.** Secondary text and icons sit next to each other, so they take adjacent or equal steps.
- **Light only.** The Search bar forces the light appearance (see the [technical design](technical-design.md)), and working windows follow until dark mode is decided. Geist defines dark values for every step, so adding dark mode changes role values, not views.

### History

PR #17's original colors, before the move to Geist: text `#171717`, secondary text and placeholder `#666666`, icons `#777777`, selected result 6% black, scroll thumb 16% black.
