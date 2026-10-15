# Design system

Hana looks clean, minimal and Mac-native: near-monochrome grays, one near-black anchor, translucent black for states, and large concentric corners. The visual reference is [Anish's lab](https://lab.anishfn.ink/); the palette is [Vercel Geist's colors](https://vercel.com/geist/colors).

Each section defines named **roles**, and views use only roles: never a raw color, a Geist step or a font size. To change how something looks, change or add a role.

Motion and iconography are not written yet; until they are, [`BarStyle`](../Sources/Hana/BarStyle.swift) remains the source for the Search bar's motion. Spacing is deliberately not a section: each layout keeps its own numbers, as `BarStyle` does for the Search bar.

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

### Color history

PR #17's original colors, before the move to Geist: text `#171717`, secondary text and placeholder `#666666`, icons `#777777`, selected result 6% black, scroll thumb 16% black.

## Typography

Code: [`HanaFont.swift`](../Sources/Hana/HanaFont.swift). The role `bar.input` is `HanaFont.Bar.input`; `body` is `HanaFont.body`.

### Font

Hana uses the system font, SF Pro, through `NSFont.systemFont` and SwiftUI's `.system`. Nothing is bundled. SF Pro has no Thai letters, so macOS substitutes a system Thai font that is designed to sit beside it; a bundled Latin font such as Geist or Public Sans would get the same Thai font without that match. The system font also switches between its text and display designs by size on its own.

### Roles

| Role | Size / line height | Weight | Tracking | Use |
| --- | --- | --- | --- | --- |
| `bar.input` | 26 / 40 | Regular | −1% | Search query, Note and Task text, placeholder |
| `heading.window` | 20 / 26 | Medium | −1% | Main window list titles |
| `row.title` | 16 / 20 | Regular | −1% | Search bar result names |
| `note.body` | 15 / 22 | Regular | 0 | Writing in a Note window |
| `body` | 13 / 18 | Regular | 0 | List rows, task titles, controls, fields |
| `label` | 13 / 16 | Medium | 0 | Mode label, notices, buttons, the task destination selector |
| `heading.section` | 12 / 16 | Medium | 0 | Group labels in working windows |
| `detail` | 12 / 16 | Regular | 0 | Paths, type labels, the results status line |
| `caption` | 11 / 14 | Regular, tabular digits | 0 | Counts, dates, key hints, shortcuts |

Sizes and line heights are in points. Tracking is a fraction of the size; in AppKit it is the `.kern` attribute in points, so −1% of 26 is −0.26.

### Rules

- **Two weights.** Regular for reading, medium for labels and headings. No semibold or bold.
- **Tighten large text only.** −1% tracking from 16 points up; smaller text keeps the font's own spacing.
- **Hierarchy comes from color first.** Within a size, use `text.secondary` or `text.tertiary` before reaching for another size or weight.
- **Tabular digits for numbers that change.** Counts and dates use `caption` so lists do not shift as values change.
- **Line height is for wrapped text.** Single-line text sits in fixed geometry; the Search bar's editor height (`BarStyle.editorHeight`) equals `bar.input`'s 40-point line.

### Typography history

Before this section, the validation windows' title was 22-point semibold. The Search bar's sizes, weights and tracking are unchanged by it.

## Radius

Code: [`HanaRadius.swift`](../Sources/Hana/HanaRadius.swift). The role `radius.bar` is `HanaRadius.bar`.

### Base radii

For shapes that do not sit inside another rounded shape:

| Role | Radius | Use |
| --- | --- | --- |
| `radius.bar` | 26 | The Search bar's bezel |
| `radius.group` | 16 | Grouped lists in working windows |
| `radius.control` | 12 | Fields, segmented controls, buttons |
| `radius.chip` | 6 | Key hints and small tags |
| `radius.capsule` | Half the height | Scroll thumbs, task circles, pills |

### Concentric rule

A rounded shape inside another takes the outer radius minus the gap between them, never less than 0: `HanaRadius.nested(in:inset:)`. Nested radii are derived this way, never chosen:

| Shape | Derivation | Radius |
| --- | --- | --- |
| Search bar card | `radius.bar` − 4 inset | 22 |
| Search bar result row | card − 8 padding | 14 |
| Row inside a group | `radius.group` − 6 padding | 10 |
| Selected segment | `radius.control` − 3 padding | 9 |

### Windows

Main window and Note window corners belong to macOS. Hana uses the system window shape and never sets a window's radius.

## Elevation

Code: [`HanaShadow.swift`](../Sources/Hana/HanaShadow.swift). The role `shadow.raised` is `HanaShadow.raised`, applied in SwiftUI with `.elevation(_:cornerRadius:)`.

### Levels

| Level | Layers | Use |
| --- | --- | --- |
| Flat | None | The default: windows, groups, rows, controls |
| `shadow.raised` | 1-point outline at 6% black; 0 1 2 −1 at 6%; 0 2 4 0 at 4% | Small white pieces on gray: the selected segment, key hints, a white card on the window |
| `shadow.popover` | 1-point outline at 6% black; 0 4 8 −2 at 6%; 0 12 24 −4 at 8% | Floating panels Hana draws itself |
| System | Native window shadow | Main window, Note windows, the Search bar, native menus and popovers |

Drop layers read as x offset, y offset, blur and spread in points, as in CSS. The outline is a ring just outside the shape. Both levels come from [Anish's lab](https://lab.anishfn.ink/), where they are `shadow-surface` and `shadow-popover`.

### Rules

- **Flat first.** Separate things with fill (`surface.group` on `surface.window`) before reaching for a shadow.
- **Shadows go on opaque `surface.card` shapes.** The implementation casts each layer from a shape behind the view, so the view must cover it.
- **The shadow follows the shape's corners.** Pass the shape's radius, base or nested, to `.elevation`.
- **Native things keep native shadows.** Windows, the Search bar panel, menus and system popovers are never given a painted shadow; the [technical design](technical-design.md) explains why the bar's shadow must stay native.
- **No lift on hover.** Hover changes fill (`row.hover`, `surface.groupHover`), never elevation.
- **Light only.** The values are tuned for light surfaces; dark mode would need its own.

