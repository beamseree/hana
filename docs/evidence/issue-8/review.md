# Two-axis review — issue #8

Fixed point, confirmed by Beam: `b6399e17bd60e6f27d6fd410dd36759900ecb341` (main including #6). Command: `git diff b6399e17bd60e6f27d6fd410dd36759900ecb341...HEAD`. Independent parallel Standards and Spec agents reviewed `6c6078d`, then rechecked the changes committed as `bde8da0`.

## Standards

No actionable Standards findings. The changes preserve AppKit ownership and retained editor identity, keep geometry within Mac Interaction, isolate optional Accessibility reads, and distinguish automated evidence from pending native acceptance. No baseline smell warrants a change. The final global-event change follows the documented outside-click rule, and the continuation fixture models cancellation-insensitive IPC accurately.

## Spec

One incomplete acceptance finding: issue #8 requires “Real checks cover editing and pointer placement on each available display with changing results.” These are explicitly pending. Keep the PR draft until coordinated native checks establish editing/paste/selection/undo/redo, context menus, owned controls, resizing, reinvocation, placement and outside-click typing. Record exact tested revision and installed identity, and label unavailable trusted Accessibility/display paths.

Review identified outside clicks during menu tracking as an essential native test target. Foreign-app mouse events now dismiss regardless of delayed menu-end notifications; local native-menu protection remains. The reviewer accepted that correction. Captured-pointer fallback, negative-coordinate conversion, visible-frame clamping, deadline fencing and retained-editor handling align with scope. No confirmed code defects or scope creep remain.

Standards: 0 findings, no worst issue. Spec: 1 incomplete acceptance finding, worst issue is pending native verification.
