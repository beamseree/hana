# Jev backoff and key handling — issue #126

2026-10-15. Implements the failure/key slice of #120 on its integration branch, based on the Word-paced tracer at `37bac99`. This record describes automated evidence; it makes no claim about physical switch timing, focus, or classifier quality.

## Acceptance evidence

| Requirement | Evidence |
| --- | --- |
| 401 stops requests across bar sessions until Save | `JevBackoffTests.rejectedKeyStopsAcrossSessionsUntilANewKeyIsSaved`. A new policy using the same launch memory records a key-rejected backoff instead of classifying. |
| An older 401 still rejects the key after a newer verdict | `anOlderRejectedKeyStillStopsSendsAfterANewerAnswer`. |
| An old-key reply cannot reject a replacement key | `aReplyForTheOldKeyCannotRejectANewlySavedKey`; request key revisions distinguish the credential in use when a request started. |
| 429 respects Retry-After, including across sessions | `rateLimitUsesRetryAfterAcrossBarSessions` tests 1 ms before and exactly at expiry. `concurrentRateLimitsCannotShortenAnExistingRetryAfter` preserves the longer of two overlapping limits. |
| Missing Retry-After doubles 1, 2, 4, 8, 16, 30, 30 seconds and success resets it | `missingRetryAfterGrowsToThirtySecondsAndSuccessResetsIt`. |
| Two consecutive network failures pause 2 seconds; success resets the streak | `twoNetworkErrorsPauseForTwoSecondsAcrossSessions`, with a shared fake clock. |
| Failures leave plain Search | `aFailureReturnsAnAutomaticallyEnteredModeToPlainSearch`, parameterized over authentication, rate limit, network, and malformed response. |
| Skips record a content-free backoff reason without latency | Policy assertions plus `backoffRowsContainOnlyAReasonAndNoInputOrLatency` writing real JSONL through diagnostics. |
| Stable sorted request keys | `ClassifierAdapterTests.jevSerializesRequestAndChoiceKeysInStableAlphabeticalOrder` checks literal top-level and choice order at the stubbed transport boundary. |
| Typed HTTP/network/malformed failures, Retry-After seconds and HTTP date | Existing adapter failure cases plus `jevRateLimitCarriesAUsableRetryAfter`, with injected wall time. Invalid/missing Retry-After falls back to the policy delay. |
| A saved/removed key affects an already-created adapter | `savedOrRemovedKeyTakesEffectOnAnAlreadyCreatedAdapter`; the adapter reads a launch-memory provider and sends nothing when it has been removed. |
| Key read once per launch, refreshed after Save/Remove | `JevKeychainTests.launchReadsKeyOnceAndRefreshesOnlyAfterSaveOrRemove` exercises a unique real Keychain service and observes the Security API query boundary. Three classifier constructions and presence checks perform no extra secret reads. |
| Presence checks request only attributes | `presenceChecksRequestAttributesWithoutSecretData` checks real missing/saved Keychain items and asserts that no data/value-data attribute is requested. Authentication UI is forbidden for these metadata queries. |
| No keys in defaults/events | `keySavesReadsReplacesAndRemovesInAnIsolatedService` and `JevRejectionMenuTests` inspect isolated defaults, standard defaults, recorded events, and menu labels. |
| Disabled “Jev key rejected” status clears after Save | `JevRejectionMenuTests.menuShowsRejectedKeyAndSavingANewKeyClearsTheStatus`, a menu-only test driven by a scripted policy 401. |
| No real Jev calls | Every adapter test injects a transport, policy tests use effects only, and menu/key tests never classify using a live adapter. |

## Validation

```sh
xcrun swift test --no-parallel --filter 'JevBackoffTests|ClassifierAdapterTests|JevKeychainTests|JevRejectionMenuTests|JevSharedTransportTests|AutomaticSwitchWordPacedTests|AutomaticSwitchDiagnosticsTests|AutomaticSwitchWakeUpTests|AutomaticSwitchTests'
git diff --check
```

89 tests in nine suites passed. The native window suites and installation are reserved for the integration owner and were not run in this worktree. The menu-only rejection test does not present a bar, working window, or modal alert.

TDD red-to-green observations include unsorted body assertions, network sends continuing before the 2 s expiry, a newer answer hiding an older 401, concurrent Retry-After values shortening a pause, and an old-key 401 stopping a newly saved key. New APIs were introduced only after their seam tests failed to compile or assert.

Mac Interaction now keeps one launch epoch across bar invocations, passes parsed Retry-After through the failure event, and shares the service's launch memory. Service construction reads the key once; classifier construction on bar opening uses only that cache. No cache, backoff state, key revision, or secret is persisted.

## Remaining integration evidence

The integration owner must run the native regression suites after merging the other #120 slices. Beam's trial remains the source of observed switch feel, request counts in live use, physical latency, and wrong/missed switch quality. Dedicated-session connection reuse/preconnect belongs to #127.
