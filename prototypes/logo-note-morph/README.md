# Logo → Note morph

A browser prototype for tuning the mode icon when `-` switches Search to Note: the Hana logo morphs into the Note icon, and back when Note returns to Search. Open `index.html` directly in a browser; it has no dependencies.

The end states come from the Figma frames "Line Logo" (32:60) and "Note Icon" (32:67) in [Test › Page 3](https://www.figma.com/design/ftWYdIiQtKnD3UGR9sHK9M/Test?node-id=31-58). Those frames pair layers by name for Smart Animate:

| Figma layer | Logo | Note |
| --- | --- | --- |
| Ellipse 13 | bloom outline | rounded square |
| Line 4 | top-left spoke | top text line |
| Line 2 | bottom-left spoke | bottom text line |
| Rectangle 26, Line 1, Line 3 | ring, right spokes | hidden |

Figma draws the logo at 15/14 the size of `HanaLogo.svg`. The prototype maps both frames into the app's 28-point space with `fig()`, so p = 0 is the logo that `SearchIconMorph` draws. **Figma overlay** in the inspector checks both end states against the Figma vectors.

## Variants

- **Fold flat**: the bloom fills out into the square, and each half of the centre straightens into one text line. Each half is two spokes plus the ring arc between them.
- **Swing** (default): the left spokes swing flat about their caps into the lines. The ring shrinks away and the right spokes retract into it. Mid-morph the lines pass through a `>` chevron.
- **Smart Animate**: the Figma pairing taken literally. Points travel in straight lines, and the hidden parts fade in place.
- **Crossfade** and **Instant**: baselines.

The outline is the same in every variant. The bloom's lobe tips already sit on the square's corners, so only the four notches move.

## Chosen settings

`variant: swing · spring(duration: 0.24, bounce: 0.4, outlineBounce: 0.3) · lag: 0 · stroke: 2`

Chosen by Beam on 2026-10-14 and shipped in [`Sources/Hana/ModeIcon.swift`](../../Sources/Hana/ModeIcon.swift) as `NoteIconMorph`. The outline runs on its own spring, with the same duration and a little less bounce than the centre, so the square settles while the lines still spring. The centre's spring and the stroke match the shipped logo → magnifier morph. Reduce Motion replaces the morph with a 150 ms crossfade, as the magnifier morph does.

## Bringing a tweak back to the app

`ModeIconView.setGlyph(.note, animated:)` runs the morph. Swing reuses the magnifier morph's layers: the outline, the ring and four spokes. The top-left and bottom-left spokes become the text lines. Update both places so they stay in step:

| Setting | Swift (`NoteIconMorph`) | Prototype (`DEFAULTS`) |
| --- | --- | --- |
| `spring(duration, bounce)` | `spring` | `duration` (ms), `bounce` |
| `outlineBounce` | `outlineSpring` | `outlineBounce` |
| `stroke` | `SearchIconMorph.stroke` (shared) | `stroke` |

The app implements only Swing with no lag. Choosing another variant, or adding lag, means porting its geometry from `morphParts()` in `index.html` to `NoteIconMorph.shape(at:outline:)`, then updating `Tests/HanaTests/ModeIconTests.swift`. Fold flat would also need its own layers: two 64-point line paths and the ring's two side arcs.

There is no designed morph between the Note icon and the magnifier, for example when Note returns to Search with text. The icon crossfades between them.
