---
status: accepted
---

# ADR 0004 — Direct installation for the personal macOS utility

Selected on 2026-10-13 as an engineering decision for the accepted Beam-first, local-Mac scope. Use a signed, directly installed app without App Sandbox because broad indexed file search without folder-selection setup and optional focused-window Accessibility integration fit that distribution model; a Mac App Store version would require revisiting permissions and potentially the experience. Hardened Runtime and any later Developer ID notarization are separate from sandboxing, and removing App Sandbox does not remove macOS privacy or filesystem restrictions.

Do not require Full Disk Access or input monitoring by default. Validate search/open coverage in the real signed app, request optional Accessibility access for focused-display placement, and preserve pointer-display fallback when unavailable. [Apple sandbox constraints](https://developer.apple.com/documentation/security/protecting-user-data-with-app-sandbox), [distribution requirements](https://developer.apple.com/documentation/xcode/preparing-your-app-for-distribution), [technical design](../technical-design.md).
