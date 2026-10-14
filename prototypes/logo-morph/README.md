# Logo → Search morph

A browser prototype for tuning Search's mode icon: the Hana logo while the query is empty, morphing into a magnifying glass once it has text. Open `index.html` directly in a browser; it has no dependencies.

Its defaults are the settings shipped in [`Sources/Hana/ModeIcon.swift`](../../Sources/Hana/ModeIcon.swift). Tweaks are remembered per browser; **Reset** returns to the shipped values.

## Shipped settings

`variant: centre · spring(duration: 0.24, bounce: 0.4) · stroke: 2 · searchScale: 1.2`

Chosen by Beam on 2026-10-14. Reduce Motion replaces the morph with a 150 ms crossfade.

The app has no mid-morph blur. A 0.5-point blur was tried, but its Core Image layer filter nudged the icon toward the bottom left when it was removed at the end of each morph, so Beam dropped it. Keep `midBlur` at 0 unless a blur can be added without that shift.

## Bringing a tweak back to the app

Copy the settings line from the Tuning panel, then update both places so they stay in step:

| Setting | Swift (`SearchIconMorph`) | Prototype (`DEFAULTS`) |
| --- | --- | --- |
| `spring(duration, bounce)` | `spring` | `duration` (ms), `bounce` |
| `stroke` | `stroke` | `stroke` |
| `searchScale` | `searchScale` | `searchScale` |

The app implements only the `centre` variant. Choosing another variant, or `twist`, means porting its geometry from `geometry()` in `index.html` to `SearchIconMorph.shape(at:)`. The two share the same 28-point coordinates and progress windows. Then update the end-state expectations in `Tests/HanaTests/ModeIconTests.swift`.
