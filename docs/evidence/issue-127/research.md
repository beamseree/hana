# Issue #127 — Independent preconnect research

Checked 2026-10-15 (Asia/Bangkok), using TypeSafe primary sources and the integration agent's retained manual check. No classification, Search text or API key was sent for this research.

**Conclusion:** no supported route satisfying all three requirements—no Search text, no API key, and no rate-limit quota—has been established. This is a limit of the available evidence, not proof that every possible suitable route is absent. #127 permits delivering the dedicated retained session without preconnect in this case.

## Published routes and guarantees

The current [TypeSafe OpenAPI schema](https://api.typesafe.ai/openapi.json) lists two operations. Both declare HTTP bearer authentication. It contains no separate health, warm-up or preconnect operation.

| Route | Published contract | Qualifies? |
| --- | --- | --- |
| `GET /v1/models` | Model discovery for the authenticated account; no request body is defined | No: requires an API key |
| `POST /v1/systemone` | Evaluation of supplied `state` and named questions; authenticated, required request body | No: inference endpoint requiring an API key |

The [HTTP API reference](https://docs.typesafe.ai/api) confirms the evaluation endpoint's bearer header and required `state`, `model` and `questions`. Its rate-limit section describes 429/529 and exponential backoff. The consulted reference does not promise a quota-exempt preconnect operation.

The [documentation index](https://docs.typesafe.ai/llms.txt) and [asynchronous client reference](https://docs.typesafe.ai/sdk/python/api/clients/async) provide API/SDK entry points, but establish no additional unauthenticated, quota-exempt warm-up contract. The public schema and documentation being readable without a key does not establish that fetching them is a supported inference preconnect mechanism or uses no rate-limit quota. Do not infer either guarantee from a successful documentation download.

## Manual check already performed by integration agent

The integration agent sent a bodyless, unauthenticated `GET https://api.typesafe.ai/v1/models`. The retained response is HTTP 403 with `authentication_error` and a message requiring an API key. I independently inspected the retained response and status line; I did not repeat this probe. It confirms that the documented model-discovery route does not satisfy the no-key requirement for that check.

Retained local evidence: `/tmp/hana-issue-120-context/jev-models-no-key.json`, `jev-models-no-key.headers`, and `jev-openapi.json`. The public documentation was read through the browser tool; there were no authenticated calls or inference calls. Headers containing cookies are not copied into this record.

A [sanitized manual-check record](manual-models-check.json) preserves the method, request constraints, status, and error body in this repository. It excludes response headers and cookies.

No connection-reuse timing, TLS saving, quota usage or physical first-request latency was measured. A dedicated retained session remains independently implementable; any runtime reuse or speed claim needs its own evidence.
