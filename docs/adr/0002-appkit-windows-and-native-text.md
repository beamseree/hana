---
status: accepted
---

# ADR 0002 — AppKit owns windows and text input; SwiftUI composes views

Selected on 2026-10-13 as an engineering decision within the authorized technical-design work. Use AppKit window controllers, a retained transforming `NSPanel`, and native `NSTextView` editors, with SwiftUI hosted for organizer views and controls, because focus, input composition, typed-versus-pasted prefixes and stable editor identity are central requirements. This favors explicit native control over a pure SwiftUI window/editor stack, while avoiding an all-AppKit organizer.

The app owns a collection rather than independent file documents, so note windows are keyed by note ID rather than backed by separate `NSDocument` files. Panel activation policy and full-screen behavior remain subject to [ADR 0005](0005-activation-policy-and-working-windows.md) and runtime validation; accepting the framework split is not proof of that behavior. See the [technical design](../technical-design.md).


Issue #10's [integrated validation](../evidence/issue-10/validation.md) retains the same native editor and PR #17 visuals while measuring live asynchronous Search. It fixes a measured synchronous metadata-fetch stall at the Search adapter boundary; it does not replace the editor or elevate the panel. Automated editing/geometry checks and physical input observations are reported separately. This ADR's accepted framework choice does not assert completion of the remaining native/performance acceptance gates.
