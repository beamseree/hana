# Jev retained HTTP session — issue #127

2026-10-15 (Asia/Bangkok), based on integration commit `daa443a`.

## Delivered behavior

Live Jev adapters now use one dedicated `JevHTTPSession.live`, which retains an ephemeral `URLSession` for the app launch. The existing launch-wide Word-paced limiter calls this transport, and new classifiers created for later bar openings keep using the same HTTP owner. Closing a bar does not flush or invalidate the session. URLSession manages persistent connections and can reuse them when the server and network allow it; no physical connection-reuse or latency improvement is claimed by the automated tests.

The dedicated session uses Apple's [ephemeral configuration](https://developer.apple.com/documentation/foundation/urlsessionconfiguration/ephemeral), which keeps session caches, cookies, and credentials in RAM rather than persistent storage. Apple's [URLSession documentation](https://developer.apple.com/documentation/foundation/urlsession) describes session-level connection behavior. Hana adds no manual Connection header, extra inference request, retry, or warm-up call.

## Preconnect decision

Preconnect is omitted under #127's research fallback. The [independent primary-source research](research.md) and [sanitized manual check](manual-models-check.json) establish that:

- The published `GET /v1/models` and `POST /v1/systemone` operations require a bearer key.
- A manual bodyless, unauthenticated `GET /v1/models` returned HTTP 403 requiring an API key.
- No consulted primary source establishes a supported route with no Search text, no API key, and no rate-limit quota. Public documentation downloads do not establish a quota-exempt inference preconnect contract.

This is an evidence limit, not proof that every possible suitable route is absent. There is no preconnect code, so the conditional preconnect test requirements do not apply. No physical first-request measurement was made with or without preconnect.

## Automated validation

```sh
xcrun swift test --no-parallel --filter 'JevHTTPSessionTests|ClassifierAdapterTests|JevSharedTransportTests'
git diff --check
```

18 tests in three suites passed; whitespace validation passed.

- `JevHTTPSessionTests.retainedSessionServesIndependentAdaptersAndPreservesRetryAfter` drives the actual URLSession data path through an injected in-process URLProtocol. Two independent adapters use the same retained HTTP owner; a successful reply decodes, and a later 429 preserves Retry-After through the structured failure.
- `aNonHTTPResponseRemainsAContentFreeMalformedFailure` verifies the session response guard and the classifier's typed failure preservation.
- Existing adapter tests cover sorted request keys, pinned wording/model, HTTP/network/malformed/cancellation mapping, key refresh, and Retry-After parsing.
- Existing shared transport tests cover two-slot admission across independent clients, active cancellation retaining a slot until HTTP work exits, and cancelled waiters never sending.

The new test was first red because the dedicated HTTP owner did not exist, then green after it was introduced and wired into `JevClassifier.liveTransport`. Tests use an injected URLSession whose URLProtocol intercepts every request; there are no automated calls to TypeSafe or another external host. These checks prove response plumbing and shared ownership, not real TCP/TLS reuse or physical switch timing.

No AppKit window tests, install, or launch occurred in this worktree.
