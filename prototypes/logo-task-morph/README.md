# Logo → Task morph

A browser prototype for tuning the mode icon when `[` switches Search to Task: the Hana logo morphs into the Task icon, a circle with a checkmark, and back when Task returns to Search. Open `index.html` directly in a browser; it has no dependencies.

It is a sibling of the [logo → note prototype](../logo-note-morph/README.md), with the same driver, the same split springs and the same controls.

## The Task icon

There is no Figma frame for it, and it does not use `App/Resources/TaskIcon.svg`. It is drawn in the same 28-point space as the logo and the Note icon:

| Part | Logo | Task |
| --- | --- | --- |
| Outline | bloom | circle, radius 13.067: the bloom's and the Note square's extent |
| Top-left spoke | runs down-right | the check's short arm (4 points) |
| Top-right spoke | runs up-right | the check's long arm (8 points) |
| Ring, bottom spokes | centre | collapse into the check's corner |

The check's bounding box is centred on the icon, and **Check size** scales it. The arms run along the spoke diagonals, so the top spokes become the check by sliding and stretching, without rotating.

**Figma logo** in the inspector checks p = 0 against the Figma "Line Logo" vectors.

## Variants

- **Slide** (chosen): the top spokes slide down and stretch into the arms. The ring drops into the check's corner as it shrinks away, and the bottom spokes retract into it.
- **Fold**: the top half of the centre bends into the check. The top half is the two top spokes plus the ring arc between them, and the ring's top dips into the corner. The bottom half collapses into the corner.
- **Smart Animate**: the top spokes travel straight to the arms. The ring and bottom spokes fade in place.
- **Crossfade** and **Instant**: baselines.

The outline moves more than it does for Note. The bloom's notches push out by 2.5 points and its lobes pull in by 2.3 points to meet the circle.

## Chosen settings

`variant: slide · spring(duration: 0.24, bounce: 0.25, outlineBounce: 0.4) · lag: 0 · checkSize: 1 · stroke: 2`

Chosen by Beam on 2026-10-14 and shipped in [`Sources/Hana/ModeIcon.swift`](../../Sources/Hana/ModeIcon.swift) as `TaskIconMorph`. The bounce is the reverse of Note's: the outline springs more (0.4) as the bloom rounds into the circle, and the checkmark settles more firmly (0.25). The duration and stroke match the other mode-icon morphs. Reduce Motion replaces the morph with a 150 ms crossfade, as the other morphs do.

## Bringing a tweak back to the app

`ModeIconView.setGlyph(.task, animated:)` runs the morph. Slide reuses the magnifier morph's layers: the outline, the ring and four spokes. The top-left and top-right spokes become the check's arms. Update both places so they stay in step:

| Setting | Swift (`TaskIconMorph`) | Prototype (`DEFAULTS`) |
| --- | --- | --- |
| `spring(duration, bounce)` | `spring` | `duration` (ms), `bounce` |
| `outlineBounce` | `outlineSpring` | `outlineBounce` |
| `checkSize` | `check` (4- and 8-point arms at size 1) | `checkSize` |
| `stroke` | `SearchIconMorph.stroke` (shared) | `stroke` |

The app implements only Slide with no lag, at check size 1. Choosing another variant, adding lag or resizing the check means porting its geometry from `morphParts()` and `buildCheck()` in `index.html` to `TaskIconMorph`, then updating `Tests/HanaTests/ModeIconTests.swift`. Fold would also need its own layers: the check path, the bottom half and the ring's two side arcs.

There is no designed morph between the Task icon and the Note icon or the magnifier. The icon crossfades between them.
