# Indexed timing follow-up — 2026-10-13

The live-index regression now measures **ready main-queue work's enqueue-to-execution delay**, with AppKit initialized. The 50 ms bound is unchanged. The previous `Task.sleep(5 ms)` excess remains a printed diagnostic, but no longer stands in for an input-queue stall. This is a narrower, explicitly corrected measurement, not a claim that every historical scheduling delay has been explained or eliminated.

No additional production change is retained. Search, AppKit window behavior and PR #17 styling remain exactly as at production revision `ac4138a52750c97bcec74803fb08fce566ba4a28`. The existing fix requesting metadata type attributes with the query remains. This follow-up starts from PR head `46fb1a703186873bb4418d43d0a7ac57fea359cb`; its final test/evidence revision is the commit containing this report. User-approved review base remains `20e67f87355d6c8d6c3d72adc8129b692e5be29d`.

## Diagnosis and retained change

The [old check still failed](continuation-red.txt) at 100.08 ms. Timestamped [diagnostic tracing](correlated-trace.txt) found one approximately 61 ms metadata copy overlapping a 75 ms sleep excess, plus other large sleep excesses without a matching long copy. Instrumentation adds overhead; this does not prove the largest old delay's sole cause. Experiments moving metadata lifecycle to a serial operation queue and using a ProcessInfo activity did not reliably pass the old bound ([queue](queue-green.txt), [queue plus activity](queue-active.txt), [activity](active-debug-1.txt)); all were reverted. The filename `queue-green.txt` is a historical experiment label: its test failed.

Initializing AppKit and observing independent dispatch callbacks separated two measurements that had been conflated. A [queue experiment with AppKit](appkit-control.txt) recorded 2.93 ms enqueue delay alongside 163.41 ms sleep excess. Restoring the [unchanged production adapter](original-input-control.txt) also passed the refined probe. This does not prove every old delay happened before enqueue; it establishes that the old metric cannot alone diagnose main-queue unavailability. The actual app initializes AppKit, whereas the original isolated SwiftPM probe did not.

The retained test initializes `NSApplication`, temporarily adopts accessory policy, and restores its previous policy. A separate serial dispatch timer produces callbacks every nominal 5 ms and timestamps them immediately before dispatching to the main queue. Cancellation drains already submitted callbacks before asserting. The test also requires real indexed file results. It exercises five successive one-second broad `Hana` queries with zero debounce and conventional application roots. OS/index caches are not flushed; these are warm live-index stress checks, not cold-start timing measurements.

The new metric excludes timer wake-up delay and upstream producer scheduling. It includes contention after enqueue. It does not measure physical keyboard events, text rendering, every possible stall, or causally attribute all delay to Hana. The old sleep diagnostic remains visible and still exceeds 50 ms. Neither an API capability nor a passing test is physical focus evidence.

## Automated results

One run is approximately five seconds. Values are observed maxima, not p95.

| Production source / run | Queue callbacks | Maximum enqueue delay | Maximum sleep excess | Queue bound |
| --- | ---: | ---: | ---: | --- |
| Current, [comparison 1](old-input-1.txt) | 1001 | 32.92 ms | 95.62 ms | pass |
| Current, [comparison 2](old-input-2.txt) | 996 | 33.97 ms | 78.06 ms | pass |
| Current, [comparison 3](old-input-3.txt) | 1002 | 34.13 ms | 64.20 ms | pass |
| Original type-fetch defect restored from `696a992`, [sensitivity control](probe-sensitivity-red.txt) | 1010 | **351.37 ms** | 349.99 ms | **fail** |
| Restored current source, [final debug](refined-debug.txt) | 1002 | 30.72 ms | 110.80 ms | pass |
| Restored current source, [final optimized](refined-release.txt) | 1001 | 31.26 ms | 132.70 ms | pass |
| Current source, [complete optional suite](refined-full-suite.txt) | 1001 | 42.01 ms | 65.40 ms | pass |

The sensitivity control temporarily restored only the pre-fix Spotlight adapter; it was reverted before final checks. The refined probe still detects the known production defect at the same 50 ms threshold. No queue rewrite, smaller-copy workaround, activity override, helper, window-level change or animation suppression remains.

Final all-options sequential suite: **49 tests passed, zero skips, 17.651 seconds**. This includes deterministic behavior, four live-index fixture checks and the timing probe. Command:

```sh
HANA_PERFORMANCE_CHECK=1 \
HANA_BOUNDED_FIXTURE="$HOME/Hana Issue 7 Validation/[Hana7*].txt" \
HANA_INDEXED_FIXTURE="$HOME/Hana Mixed Search Validation/TextEdit Hana [*] บันทึก.txt" \
xcrun swift test --no-parallel
```

Focused commands: `HANA_PERFORMANCE_CHECK=1 xcrun swift test --filter SearchResponsivenessTests` and the same command with `-c release`. Real AppKit suites must run sequentially in the shared native slot. Reuse existing synthetic indexed fixtures; missing index coverage is not a timing pass.

## Build, identity and environment

The [release build](timing-followup-build.txt), plist lint and strict signature verification passed. The newly rebuilt executable SHA-256 is `3157f9e7d5d1c7174bc4bf1000e524e249387dc97bc61da87a96898e9bf04d7c`. It was **not installed**. Source equality does not establish bytewise reproducibility or transfer human observations to a different artifact.

The installed human-tested app is unchanged: `~/Applications/Hana.app`, `com.beamseree.hana`, 0.1.0/build 1; SHA-256 `cc19d09a7d6d0a72cbc03ff402f3bc69dec98ef79df511493e75c13ffa46571b`, CDHash `8312e1bd0214499046b279a2d22ef0df8d3b271e`. Its strict signature was rechecked successfully. See [identity verification](identity.txt). Ad-hoc signing remains local validation, not distribution approval.

macOS 26.4.1 (25E253), arm64; Xcode 26.6 (17F113), Swift 6.3.3, SDK 26.5. Existing user-reported Desktop and Full Disk Access grants remain unchanged; Accessibility is untrusted. The latest recorded native setup has two displays (built-in 1512×982 at scale 2, external 2560×1440 at scale 1 above/left); the earlier human placement pass covered three. This continuation changes no permissions, shortcuts or display/Spaces settings. No competing Hana chat or native process was found before testing/launching; one build/test ran at a time. Prior [coverage/permission evidence](../validation.md#coverage-and-permission-consolidation) remains applicable with its stated limits.

## Remaining acceptance

Automated queue responsiveness is supported for these conditions. Physical shortcut-to-typing p95 below 100 ms and a universal absence of app-attributable physical typing stalls remain **unmeasured**. Prior release performance counts and cold/warm definitions remain in the [integrated report](../validation.md#performance-definitions-counts-and-limits); these test results do not replace them.

**Human follow-up: passed.** Beam answered “yes” to this exact remaining functional procedure: select the exact `/Two/` application while files are pending, keep the query unchanged, observe that same path selected when the delayed `.txt` batch arrives, then open `Installation: Two` and type without clicking while staying at the destination. Prior lifecycle, editing, styling, folder, failure-context and file destination passes need no broad repeat. The unchanged installed Hana was launched with `--diagnostics --validation-file-delay` for this check. The [runtime trace](physical-runtime.jsonl) separately records asynchronous batches and launch acknowledgments; exact selection, destination content and physical focus are established by the human answer, not those flags. No further functional recheck remains from the requested matrix.

Keep PR #19 draft and #2 open. ADR 0005 remains proposed. The original unreproduced minimize anomaly retains unknown cause; this timing investigation does not diagnose it.

At 21:20 ICT, Hana (PID 54324) and the known Two fixture (PID 54396) were terminated through `NSRunningApplication.terminate()`. The independent Option+Space probe reserved the shortcut exclusively (PID 54591), then was stopped with Control-C. No user-owned foreign app was quit; the native slot and shortcut are released. See [shutdown](shutdown.txt).
