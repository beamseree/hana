# What Jev offers in production

Research for [#102](https://github.com/beamseree/hana/issues/102), part of the map [#101](https://github.com/beamseree/hana/issues/101) (automatic switch between Search, Note and Task). Checked on 2026-10-15 against TypeSafe AI's own docs, site and legal pages. No account was created and no API key was used.

Each point is marked **Documented** (stated by TypeSafe, with the source linked), **Measured** (observed from this Mac, without credentials) or **Inference** (my reasoning, not stated anywhere).

## Short answer

- **How to call it.** One HTTPS endpoint, `POST https://api.typesafe.ai/v1/systemone`, with `Authorization: Bearer <key>` and a JSON body. There are official SDKs for Python and JavaScript only. There is no official Swift SDK, so Hana would call the endpoint with `URLSession`.
- **Confidence.** Yes. A `choice` answer returns the winning option, a probability for every option (they sum to 1), and a `confidence` from 0 to 1 that is computed from those probabilities with a published formula.
- **Latency.** TypeSafe claims 70–500 ms end to end, measured from laptops on the US West Coast. There is no p50/p95 and no region option. From Bangkok, a warm-connection request that the API rejects for missing auth already takes **about 290–350 ms**, before any inference happens. The ~100 ms playground figure is not what Hana would see. A real request from here will probably take **about 0.35–0.6 s** (inference).
- **Cost.** Negligible. $0.042 per million input tokens, output free. A short one-question request is about 300 input tokens (≈ $0.0000126), so even 10,000 calls a day is about $4 a month (inference). Credits are prepaid.
- **Privacy.** TypeSafe does not train on inputs. The service is hosted in the US. There is no fixed retention period, the customer agreement allows Customer Data to be kept indefinitely for telemetry, abuse monitoring and legal compliance, and zero data retention is for enterprise customers only.
- **Offline / on-device.** None. The weights are not public, and no self-hosted, VPC or on-device option is documented.

## API shape and auth

**Documented** ([API reference](https://docs.typesafe.ai/api), [Models](https://docs.typesafe.ai/models), [Quick start](https://docs.typesafe.ai/introduction/quickstart)):

- `POST https://api.typesafe.ai/v1/systemone`, `Content-Type: application/json`, `Authorization: Bearer <API_KEY>`. Keys come from `console.typesafe.ai/keys`.
- The body has three fields: `state` (a string, object or array), `model` (`"jev-latest"`, or a pinned ID such as `"jev-1.13.0"`) and `questions`, a map from a key you choose to a typed question. Beam's `{"classify_input": {"type": "choice", "instructions": ..., "criteria": {...}}}` is exactly one entry in that `questions` map. The typed text goes in `state`. The question key is not sent to the model.
- Question types are `noul` (yes/no), `choice` (up to 255 options), `score` (2–10 ordered levels) and `box` (image regions). Jev 1.13/1.14 accept text input only.
- The response is `{model, answers: {<key>: Answer}, usage: {input_tokens, output_tokens}}`. `model` gives the versioned ID that actually answered.
- Error codes: 400 (rule violation, or `max_tokens_exceeded`), 401 (bad or missing key), 413 (body over 32 MiB), 415 (bad `Content-Encoding`), 422 (validation failure), 429 (rate limited), 529 (overloaded). Back off and retry on 429 and 529. The SDKs do this by default and follow `retry-after`.
- Request bodies can be compressed with gzip or zstd. The SDKs use zstd for bodies of 1 KiB or more, which does not matter for Hana's tiny bodies.
- Aliases: `jev-latest` currently points to `jev-1.13.0`, and `jev-preview` points to `jev-1.14.0` (released 2026-10-14). An alias moves without warning, so TypeSafe advises pinning the version you tuned your thresholds against.
- Context limits are 64k tokens per request and 32k per question. They do not matter for search-bar text.

**Measured:** an unauthenticated POST returns `403` with an `authentication_error` JSON body, not the documented `401`. The response is served through Cloudflare over HTTP/2 and advertises HTTP/3.

## Does `choice` return per-option confidence?

**Documented** ([API reference: Choice answer](https://docs.typesafe.ai/api#choice-answer), [Confidence](https://docs.typesafe.ai/confidence)):

```json
{"type": "choice", "choice": "billing",
 "probabilities": {"billing": 0.88, "technical": 0.12, "sales": 0.0},
 "confidence": 0.81}
```

- `probabilities` covers every option, and the values sum to 1.
- `confidence = (p_max − 1/n) / (1 − 1/n)`, where `n` is the number of options. It is 0 when the distribution is uniform and 1 when all the probability is on one option. TypeSafe suggests the top probability, or the ratio of the top two, as alternatives you can compute yourself. With three options (Search, Note, Task), confidence 0.5 corresponds to p_max ≈ 0.67.
- TypeSafe markets the probabilities as calibrated (trained with "RLCD"), but tells developers to validate thresholds on their own data. It publishes no calibration figures for short or partial text.
- Known weak spots ([Jev 1.13 jaggedness](https://docs.typesafe.ai/model-jaggedness/jev-1.13), reviewed 2026-10-02):
  - It reads instructions literally.
  - It **leans toward the first Choice option** in some cases. TypeSafe advises reordering the options to check consistency. In Beam's schema, Search is listed first.
  - Adversarial text in `state` can steer the answer.
  - English is the strongest language.
- TypeSafe recommends adding an `other`/`none of the above` option when the list may not cover every input ([Choice](https://docs.typesafe.ai/primitives/choice)).

## Latency and region

**Documented:**

- TypeSafe's launch post ([Introducing System One models and Jev](https://typesafe.ai/blog/introducing-system-one-models-and-jev), 2026-09-15) gives "70ms-500ms" end-to-end response time. It says its published evals are generally run from its own laptops on the US West Coast. It gives no percentiles, no input sizes and no server/client split.
- The [Privacy Policy](https://typesafe.ai/legal/privacy-policy) says the services are hosted in the United States. No region choice is documented anywhere, and the enterprise FAQ asks about data location without answering it.
- The [parallel-questions cookbook](https://docs.typesafe.ai/cookbooks/parallel_questions) reports 0.27 s for one call carrying 13 questions over a long article, against about 0.21 s per call when each question was sent alone. Client location is not stated.
- Adding questions to one request "barely changes the response time", because questions are evaluated in parallel ([Primitives](https://docs.typesafe.ai/primitives)).
- The SDK default timeout is 10 s per HTTP operation.

**Measured from this Mac (Bangkok, Cloudflare edge `SIN`), 2026-10-15, without credentials:**

| Request | Time |
| - | - |
| Ping to the Cloudflare IP | 18–52 ms |
| Cloudflare edge only (`/cdn-cgi/trace`), warm | 78–120 ms |
| `POST /v1/systemone` with no key (rejected by TypeSafe's backend; has an `x-typesafe-request-id`), cold, including DNS + TCP + TLS | 390–730 ms |
| Same request, **warm connection reused** | **294–352 ms** |

**Inference:**

- The rejection travels to TypeSafe's US origin and back without running the model, so ~300 ms is the network floor for each warm request from Beam's location. A real classification adds Jev's inference on top. If the playground's ~100 ms is mostly server time, expect roughly 0.35–0.6 s per keystroke classification from Bangkok, and more on a cold connection.
- In practice Hana would need to:
  - keep one warm `URLSession` connection (HTTP/2 or HTTP/3);
  - cancel stale in-flight requests;
  - treat the classifier as arriving well after the deterministic Search results.
- This needs a real authenticated measurement (see Gaps).

## Streaming and batching

**Documented:**

- **No streaming.** Each response is a single JSON object. No streaming mode or SSE is documented.
- **Batching:**
  - One request takes one `state` and any number of questions, evaluated in parallel. There is no limit on how many questions you send, only on context length.
  - There is no endpoint for many states in one request. Concurrency comes from sending requests in parallel; the SDK pool keeps up to 100 connections open, each kept alive for 30 s.
  - TypeSafe recommends "speculative fan-out": ask every question you might need in one call ([Speculative fan-out](https://docs.typesafe.ai/patterns/fan-out)).
- **Inference:** for Hana, extra questions in the same request cost almost no time. Examples are a Noul such as "is this a partial word?" or a second wording of the Choice to check order bias.

## Pricing

**Documented** ([Models](https://docs.typesafe.ai/models), [typesafe.ai](https://typesafe.ai), [Master Customer Agreement §8](https://typesafe.ai/legal/mca)):

- **Price:**
  - $42 per billion input tokens ($0.042 per million). Output tokens are free. Jev 1.13 and 1.14 cost the same.
  - TypeSafe says it cannot prove the price is not subsidised, and expects prices to go down rather than up (launch post).
- **Billing:**
  - Usage is paid from prepaid Credits. Credits are not refundable and expire 12 months after purchase or at the end of the term, whichever comes first. Auto-refill is optional.
  - The minimum credit purchase and any free tier are not stated publicly.
- **Example request size:** the API reference examples (a nine-word `state` plus one question) report 296–318 input tokens, which suggests a fixed per-request overhead of a few hundred tokens.

**Inference:**

| Calls per day | Approximate cost per month |
| - | - |
| 1,000 | $0.38 |
| 10,000 | $3.80 |

This assumes about 300 tokens per call. Cost will not drive the decision.

## Rate limits

**Documented** ([Models: Rate limits](https://docs.typesafe.ai/models#rate-limits)):

- Limits are set per organization, in tokens per second and requests per second. Going over either returns 429.
- The actual numbers are shown only in the logged-in console (`console.typesafe.ai/rate-limits`). Higher limits are available on custom and enterprise plans.
- **Not found:** default limit values. They need a console check. **Inference:** one user typing is unlikely to come close to any plausible requests-per-second limit if requests are debounced and stale ones cancelled.

## Data retention and training on inputs

**Documented:**

- **Training on inputs:**
  - Jev "is not trained on customer requests or responses" ([Models: Data handling](https://docs.typesafe.ai/models#data-handling)).
  - The Privacy Policy, last updated 2025-11-19, says TypeSafe will not train or fine-tune models on Input.
  - The MCA §4.1 says the licence does not allow training on Customer Data without the customer's prior consent.
  - The same weights serve every account. There is no per-account fine-tuning.
- **Retention:**
  - The Privacy Policy keeps data "as long as reasonably necessary". The [Data Processing Addendum](https://typesafe.ai/legal/data-processing) (last updated 2026-04-24) keeps it "as long as necessary". Neither sets a fixed period.
  - MCA §4.1 lets TypeSafe process Customer Data (Input and Output) in perpetuity to derive Telemetry, monitor fraud and abuse, and comply with law. §4.3 lets it use Telemetry (logs, metrics) without restriction.
- **Zero data retention:** enterprise customers only, through sales ([Legal](https://docs.typesafe.ai/legal), [Enterprise](https://typesafe.ai/enterprise)).
- **Location and subprocessors:**
  - Hosted in the US. Transfers out of the EEA/UK are covered by Standard Contractual Clauses.
  - The subprocessor list is at `trust.typesafe.ai/subprocessors`, a script-rendered page that did not load here, so I did not read it.
  - SOC 2 Type II is claimed; the report is available on request.
- **API keys:** MCA §2.4 requires access credentials to be kept confidential and never shared. **Inference:** this suits Hana as Beam's own personal app (ADR 0004), with the key stored in Keychain. Shipping a key inside a distributed app would break that clause, so distribution to others would need a proxy server.

**Inference:** with a standard account, every Search keystroke Beam sends could be retained indefinitely as "Customer Data used for Telemetry/abuse monitoring", although it will not be used for training. Beam accepts text leaving the Mac, so this is a disclosure question rather than a blocker.

## On-device or self-hosted

**Documented:**

- Only the hosted API is documented. The enterprise page lists "VPC or on-prem" as an FAQ question with no visible answer.
- TypeSafe's public GitHub (`typesafe-ai`) has no model weights. Its `system-one-adapter-python` is a drop-in client backed by *other* LLM APIs, not a local Jev.

**Inference:** offline means no Jev. The "slow or offline fallback" in #101 has to be plain Search. A third-party Swift package (`mattt/AnyDecisionModel`) claims both local MLX models and the Jev API behind one interface; that could be a possible offline fallback, but it is not verified and is not TypeSafe's.

## Swift and macOS access

**Documented:**

- Official SDKs exist for Python and JavaScript/TypeScript (Node.js 22 or newer) only ([Client SDKs](https://docs.typesafe.ai/sdk)). TypeSafe says the HTTP API can be called from any language.
- Several **unofficial** Swift clients exist on GitHub, for example `d-date/swift-jev`, `NSStudent/JevSwiftSDK` and `peterfriese/system-one-foundation-models`. I did not review them.

**Inference:** the API surface Hana needs is one POST with a fixed JSON shape, so a small `Codable` + `URLSession` client is simpler than taking on a third-party dependency. The retry behaviour to copy is backoff on 429/529 honouring `retry-after`, but for a classification that is already late, the usual right move is to drop it rather than retry.

## Gaps (could not find)

- **Real authenticated round-trip latency from Beam's Mac:** p50/p95 for Beam's actual schema on warm and cold connections, and how much of it is server time. This needs one API key and about 100 timed calls; the docs have nothing equivalent.
- **Accuracy on short or partial queries** such as "term" or "remind m". There are no published evals for this kind of input, and TypeSafe's benchmarks are its own workflow evals.
- Default rate-limit numbers, the minimum credit purchase and any free tier. These are console-only.
- A fixed retention period for standard accounts, the subprocessor names (the trust page did not render), and whether a server-side timing header exists.
- Whether any region other than the US, or a VPC/on-prem deployment, exists. The enterprise FAQ question has no visible answer.
- An uptime SLA. None exists in the MCA (§9.3 disclaims uninterrupted service).
