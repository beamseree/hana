# Which on-device classifiers could replace Jev?

Research for [#103](https://github.com/beamseree/hana/issues/103), part of the map [#101](https://github.com/beamseree/hana/issues/101) (automatic switch between Search, Note and Task). Checked 2026-10-15 against Apple developer documentation, WWDC sessions and Apple Machine Learning Research. Every claim marked **Doc** or **WWDC** comes from the source cited next to it. Claims marked **Inference** are my reading and need measuring in the eval.

## Answer

Three on-device options are worth putting into the eval next to Jev. All three run on Hana's current macOS 26.0 deployment target.

| | Foundation Models, guided enum | Create ML text classifier (`NLModel`) | Deterministic heuristics |
|---|---|---|---|
| What it is | Apple's on-device LLM (~3B parameters, 2-bit) constrained to output one `@Generable` enum case | A small model you train on labelled examples, then ship as a `.mlmodel` | Rules: Hana's existing Search name tiers plus keyword and shape rules |
| OS floor | macOS 26.0. That equals Hana's target, so no `#available` gate is needed | macOS 10.14 (`NLModel`); 11.0 for `predictedLabelHypotheses` | None |
| Other requirements | Apple silicon Mac (M1 or later) with Apple Intelligence turned on, its model downloaded, and a supported language | None at runtime. Training needs labelled data | None |
| Latency (estimate) | Probably 100–300 ms warm on an M-series Mac, and seconds when the model is cold. **Inference**: Apple publishes no Mac figure | Probably about 1 ms (maxEnt) to tens of ms (BERT). **Inference**: Apple says only "very fast" | Microseconds. Hana already computes tiers on every query |
| Confidence | **None exposed.** The API returns content, raw content, usage and transcript entries only. Workarounds: an `unsure` enum case, or sampling several times and checking agreement | **Yes**: `predictedLabelHypotheses(for:maximumCount:)` returns label → probability | Implicit: a rule fires or it doesn't, plus the match tier |
| Partial input ("remind m") | Not documented. Likely fine when the stem is meaningful ("remind" → Task); unpredictable on fragments like "te" | Only as good as the training data. Train on generated prefixes of every example | Natural: match a keyword lexicon by prefix ("remind m" is a prefix of "remind me") |
| Accuracy potential | High on intent wording. Free-form zero-shot with few-shot examples in the instructions | High in-domain if the data is good. Weak on wording it hasn't seen (maxEnt), better with BERT transfer learning | High precision, low recall. Good only on the clear cases |
| Cost / privacy / offline | Free, on-device, offline | Free, on-device, offline | Free, on-device, offline |
| Effort | Low to wire up; medium to make robust (errors, guardrails, languages, a session per request, model-version drift) | Medium: building and labelling the dataset is the work. Training itself is a few lines | Low; Hana already has the Search tiers |

**Recommendation for the eval:** run four arms on the same labelled input set, with partial inputs included:

1. Jev, the baseline.
2. Foundation Models, guided enum.
3. A Create ML classifier, both maxEnt and BERT transfer learning, trained on prefix-augmented data.
4. Heuristics alone.

Measure each arm with the heuristic gate in front of it. The gate is the standing rule that a strong deterministic Search match always wins. Foundation Models is the strongest zero-training candidate. It has the most failure modes, though, and gives no confidence score, so it needs an explicit `unsure` route. The Create ML classifier is the only option with a calibrated-looking probability and near-zero latency, so it is the natural choice if its accuracy holds up. Heuristics are not a replacement on their own, but they belong in every pipeline as the gate.

Private Cloud Compute (Apple's server model) is **not** viable at the current target. It needs macOS 27, a managed entitlement and a network connection, and it has a daily quota. See the PCC section below.

## Context from the repo

- `Package.swift` declares `platforms: [.macOS("26.0")]`. The dev Mac used for this note runs macOS 26.4.1, which is the second Foundation Models model version (see the model versions under Option 1).
- Map #101 sets the priorities **accuracy > latency > cost > privacy > offline**. Beam accepts Search text leaving the Mac. The standing rule is that a strong deterministic Search match always beats the classifier.
- Hana already ranks names by `SearchName.Tier`: `exact, phrasePrefix, wordStart, substring, extensionOnly` (`Sources/Hana/SearchName.swift`). An application matching at `wordStart` or better is promoted above every other result (`Sources/Hana/Search.swift`, `promoted: result.kind == .application && tier <= .wordStart`). "Strong deterministic Search match" can therefore be defined in existing terms. One possible gate: a top result at `phrasePrefix` or better, or a promoted application. With that gate, "term" (Terminal at `phrasePrefix`) never reaches the classifier. **Inference**: which tier counts as "strong" is a product decision for the spec.

## Option 1: Foundation Models framework, guided generation into an enum

### Documented facts

- **What it is.** It gives access to "the on-device text foundation model that powers Apple Intelligence" (**Doc**, [SystemLanguageModel](https://developer.apple.com/documentation/foundationmodels/systemlanguagemodel)). It is about 3 billion parameters, quantized to 2 bits per weight (**WWDC**, [Meet the Foundation Models framework, WWDC25 286](https://developer.apple.com/videos/play/wwdc2025/286/); [Apple ML Research 2025 update](https://machinelearning.apple.com/research/apple-foundation-models-2025-updates)). Apple lists "Classify or judge text" among its capabilities (**Doc**, [Generating content and performing tasks](https://developer.apple.com/documentation/foundationmodels/generating-content-and-performing-tasks-with-foundation-models)). It is "not designed for world knowledge or advanced reasoning" (**WWDC** 286).
- **OS floor.** Foundation Models, `SystemLanguageModel`, `LanguageModelSession`, `Generable`, `prewarm(promptPrefix:)` and `GenerationOptions` are all available from macOS 26.0 (**Doc**, platform metadata on each page). Some newer API is macOS 27.0 only: `LanguageModelError`, `LanguageModelSession.Usage`, `SystemLanguageModel.Variant`. On 26.x, errors arrive as the older `LanguageModelSession.GenerationError` ([LanguageModelError](https://developer.apple.com/documentation/foundationmodels/languagemodelerror)).
- **Device and user requirements.** "To use Apple Foundation Models, people need a device that supports Apple Intelligence" (**Doc**, [Foundation Models](https://developer.apple.com/documentation/foundationmodels)). On Mac that means "Mac with M1 or later", with up to 8 GB of storage (up to 14 GB on M3 or later with 12 GB or more), and device and Siri language set to the same supported language (**Doc**, [Apple support: How to get Apple Intelligence](https://support.apple.com/en-us/121115)). Availability is reported as `.available`, or `.unavailable` with one of `deviceNotEligible`, `appleIntelligenceNotEnabled` or `modelNotReady`. "Models are downloaded automatically based on factors like network status, battery level, and system load" (**Doc**, [UnavailableReason.modelNotReady](https://developer.apple.com/documentation/foundationmodels/systemlanguagemodel/availability-swift.enum/unavailablereason/modelnotready)). Apple: "Always verify model availability first, and plan for a fallback experience".
- **Guided generation into an enum.** `@Generable` works on enums. The framework uses constrained decoding, masking out tokens that are invalid under the schema, so the output is always one of the cases (**WWDC**, [Deep dive into the Foundation Models framework, WWDC25 301](https://developer.apple.com/videos/play/wwdc2025/301/)). Apple shows this exact pattern as an output boundary for free user input: `@Generable enum Breakfast { … }` passed as `respond(to:generating: Breakfast.self)` (**Doc**, [Improving the safety of generative model output](https://developer.apple.com/documentation/foundationmodels/improving-the-safety-of-generative-model-output)). Guided generation "tends to improve model accuracy" and allows optimizations "that speed up inference" (**WWDC** 286). For choices known only at runtime, `DynamicGenerationSchema(anyOf:)` does the same (**Doc**, [Generating Swift data structures with guided generation](https://developer.apple.com/documentation/foundationmodels/generating-swift-data-structures-with-guided-generation)).
- **Determinism.** `GenerationOptions(samplingMode: .greedy)` "always produces the same output for a given input" (**Doc**, [greedy](https://developer.apple.com/documentation/foundationmodels/generationoptions/samplingmode-swift.struct/greedy)), but only for a given model version (**WWDC** 301).
- **Model versions change with the OS.** There are currently three model versions: 26.0–26.3, 26.4, and 27.0 (**Doc**, [SystemLanguageModel](https://developer.apple.com/documentation/foundationmodels/systemlanguagemodel)). Apple tells you to test prompts on each version and version them with `#available` (**Doc**, [Updating prompts for new model versions](https://developer.apple.com/documentation/foundationmodels/updating-prompts-for-new-model-versions)).
- **Latency mechanics.** Every input token costs latency, because "before the model can start producing response tokens, it first needs to process all the input tokens" (**WWDC** 301). The schema is injected into the prompt by default. `includeSchemaInPrompt: false` "can save hundreds of tokens per request" once the model has seen the format or examples (**Doc**, [Analyzing the runtime performance](https://developer.apple.com/documentation/foundationmodels/analyzing-the-runtime-performance-of-your-foundation-models-app)). The OS may unload the model "if the system is serving other critical features, or if it's been unused for some time", and the first `respond` then pays the asset-loading cost (**WWDC**, [Code-along, WWDC25 259](https://developer.apple.com/videos/play/wwdc2025/259/)).
- **Prewarming.** `prewarm(promptPrefix:)` "Loads the resources required for this session into memory ahead of a request". Apple's own example is to call it "when a person begins typing into a text field". A known prompt prefix lets the system "process the prompt eagerly". The important caveat: "only use prewarm when you have a window of at least 1 second before the call to a respond method", and there is no guarantee the assets load immediately (**Doc**, [prewarm(promptPrefix:)](https://developer.apple.com/documentation/foundationmodels/languagemodelsession/prewarm(promptprefix:))). Instructions, then tools, then transcript form a cached prefix. Appending keeps the cache; changing the instructions invalidates it (**Doc**, [Optimizing key-value caching](https://developer.apple.com/documentation/foundationmodels/optimizing-key-value-caching-in-language-model-sessions)).
- **The only published speed numbers are for iPhone.** For the 2024 on-device model on iPhone 15 Pro, Apple reported "time-to-first-token latency of about 0.6 millisecond per prompt token, and a generation rate of 30 tokens per second" (**Doc**, [Apple ML Research 2024](https://machinelearning.apple.com/research/introducing-apple-foundation-models)). The 2025 report gives no absolute figures, only that KV-cache sharing "significantly" improves time to first token.
- **Session cost and concurrency.** A session handles one request at a time and "causes a runtime error if you call it again before the previous request finishes". For single-turn use, "create a new session each time" (**Doc**, [Generating content](https://developer.apple.com/documentation/foundationmodels/generating-content-and-performing-tasks-with-foundation-models); [isResponding](https://developer.apple.com/documentation/foundationmodels/languagemodelsession/isresponding)). The context is 4,096 tokens per session. Calls are free and unlimited on-device (**Doc**, [PCC comparison table](https://developer.apple.com/documentation/foundationmodels/adding-server-side-intelligence-with-private-cloud-compute)). Rate limiting is possible "if you make too many requests in a short window". That error is documented in the macOS 27 `LanguageModelError.rateLimited`, and apps in the background are more exposed (**Doc**, [rateLimited](https://developer.apple.com/documentation/foundationmodels/languagemodelerror/ratelimited(_:)); [streamResponse](https://developer.apple.com/documentation/foundationmodels/languagemodelsession/streamresponse(to:generating:includeschemainprompt:options:))).
- **Failure modes a classifier must absorb.** Guardrails check both input and output and can throw `guardrailViolation`. With guided generation the model throws `refusal` instead of writing a refusal string. The permissive guardrail mode "only works for generating a string value", so it **does not help an enum classifier** (**Doc**, [Improving the safety](https://developer.apple.com/documentation/foundationmodels/improving-the-safety-of-generative-model-output)). Input in a language Apple Intelligence doesn't support throws `unsupportedLanguageOrLocale` (**Doc**, [Supporting languages and locales](https://developer.apple.com/documentation/foundationmodels/supporting-languages-and-locales-with-foundation-models)). The 16 Mac languages are English, Danish, Dutch, French, German, Italian, Norwegian, Portuguese, Spanish, Swedish, Turkish, Vietnamese, Simplified and Traditional Chinese, Japanese and Korean (**Doc**, [Apple support](https://support.apple.com/en-us/121115)). **Thai is not on the list.**
- **Confidence.** `LanguageModelSession.Response` exposes `content`, `rawContent`, `usage` and `transcriptEntries` (**Doc**, [Response](https://developer.apple.com/documentation/foundationmodels/languagemodelsession/response)). `GeneratedContent` exposes kind, values, `isComplete`, JSON and an id (**Doc**, [GeneratedContent](https://developer.apple.com/documentation/foundationmodels/generatedcontent)). The model samples from a token distribution internally (**WWDC** 301), but I found **no documented API that returns token probabilities or a confidence score**.
- **Prompting the small model.** Apple recommends simple, single-goal instructions and 2–15 simple few-shot examples. It also suggests a reasoning field placed *before* the answer property if the model needs to think, because properties are generated in declaration order (**Doc**, [Prompting an on-device foundation model](https://developer.apple.com/documentation/foundationmodels/prompting-an-on-device-foundation-model); [guided generation](https://developer.apple.com/documentation/foundationmodels/generating-swift-data-structures-with-guided-generation)).
- **Content tagging adapter.** `SystemLanguageModel(useCase: .contentTagging)` produces topic, emotion, action and object tags (**Doc**, [Categorizing and organizing data with content tags](https://developer.apple.com/documentation/foundationmodels/categorizing-and-organizing-data-with-content-tags)). It is not a fit, because it emits free-form tags rather than a choice among our three intents, and Apple says "if you ask the model questions, it produces tags about asking questions".
- **Eval tooling.** Apple's Evaluations framework (Xcode 27) is for prompt evals. The Foundation Models SDK for Python (`github.com/apple/python-apple-fm-sdk`; Apple silicon, Python 3.10+, Xcode) and the `fm` CLI (preinstalled from macOS 27) allow batch evaluation outside the app (**WWDC**, [WWDC26 334](https://developer.apple.com/videos/play/wwdc2026/334/); **Doc**, [Evaluating prompts](https://developer.apple.com/documentation/foundationmodels/evaluating-prompts-to-measure-performance-and-improve-model-responses)).

### Inference

- **Latency.** The Hana prompt would be roughly 60–150 tokens: instructions with Beam's three criteria, a few examples, and the schema. The typed text adds about 2–10 tokens, and the output is a single short enum case. Scaling Apple's iPhone 15 Pro figures, a cold-prefix call would be around 0.1 s of prefill plus a few output tokens, so **roughly 100–300 ms**. With the prefix prewarmed and cached, only the typed tokens need prefill, so it could come in under 100 ms on an M-series Mac. A cold model load adds seconds. None of this is measured; the Foundation Models Instruments template can measure it.
- **Per-keystroke strategy.** One session per request, plus the one-at-a-time rule, means a debounce-and-cancel design. Prewarm a fresh session when the bar opens. On a pause in typing, use that session for one request and prewarm the next. The "≥ 1 second" prewarm guidance fits bar-open time, not between keystrokes. Apple doesn't document whether the cached instruction prefix is shared *across* sessions with identical instructions. Cancelling an in-flight `respond` is not documented here either.
- **Partial input.** The model sees whatever string it is given, and constrained decoding guarantees a valid case even for "te". Stems with clear intent ("remind m", "buy mil") should classify well. Short fragments will get an arbitrary but confident-looking case, so an explicit `unsure` case (mapped to "stay in Search"), plus examples of fragments labelled `unsure`, is the natural mitigation. Asking the model for a numeric confidence field is possible, but small models' self-reported confidence is unlikely to be calibrated; treat that as unverified.
- **Accuracy.** This is the option most similar to Jev (a hosted LLM choosing among described criteria), so Beam's schema ports directly. The eval decides whether a 3B on-device model matches Jev on Beam's ~20 inputs and beyond.
- **Availability gap.** Users without Apple Intelligence, with it off, with the model still downloading, or typing an unsupported language get no automatic switch. That fallback is already listed under "Not yet specified" in #101.

### Effort

Wiring up: low, about a day. That covers an enum, a session factory, prewarming, an availability switch, error-to-"no switch" mapping, and debounce and cancellation. Robustness: medium. It means handling guardrail and refusal errors, language checks, per-model-version prompt testing (26.0–26.3, 26.4 and 27.0 behave differently), and the macOS 27 error-type split.

## Option 1b: Private Cloud Compute (server Apple model)

**Doc** ([Adding server-side intelligence with Private Cloud Compute](https://developer.apple.com/documentation/foundationmodels/adding-server-side-intelligence-with-private-cloud-compute); [PrivateCloudComputeLanguageModel](https://developer.apple.com/documentation/foundationmodels/privatecloudcomputelanguagemodel)):

- It uses the same API: swap `SystemLanguageModel` for `PrivateCloudComputeLanguageModel()`.
- It has a 32K context and optional reasoning.
- It is **macOS 27.0+ only**, requires a managed entitlement with eligibility requirements, needs a network connection, and comes with a **daily per-user request limit** (more with iCloud+).

**Inference:** a per-keystroke classifier would burn the user's daily quota and needs a newer OS than Hana's target, so PCC is not a candidate for this feature. It might become one if the target moves to 27 and calls are rare, for example once per pause.

## Option 2: Create ML text classifier served through NaturalLanguage `NLModel`

### Documented facts

- **What it is.** "A model you train to classify natural language text… you save it to a Core ML model file. You then use an instance of the NLModel class… to read the model file into your app" (**Doc**, [MLTextClassifier](https://developer.apple.com/documentation/createml/mltextclassifier)). `NLModel` keeps tokenization the same between training and use (**Doc**, [NLModel](https://developer.apple.com/documentation/naturallanguage/nlmodel)).
- **OS floor.** `NLModel` is macOS 10.14+, and `predictedLabelHypotheses(for:maximumCount:)` is macOS 11.0+ (**Doc**). Both are well below Hana's 26.0 target. It needs no Apple Intelligence, no download and no network. Training (`MLTextClassifier`) runs at development time on the Mac.
- **Confidence.** `predictedLabelHypotheses(for:maximumCount:)` returns "a dictionary of label hypotheses. Each dictionary entry is a predicted label with its associated probability score" (**Doc**, [predictedLabelHypotheses](https://developer.apple.com/documentation/naturallanguage/nlmodel/predictedlabelhypotheses(for:maximumcount:))). Apple's suggested use is thresholding: "By setting the threshold of, for instance, point eight… you can easily filter out this false positive" (**WWDC**, [Make apps smarter with Natural Language, WWDC20 10657](https://developer.apple.com/videos/play/wwdc2020/10657/)). At training time, `predictionWithConfidence(from:)` returns the same kind of label-to-score map (**Doc**).
- **Algorithms.**
  - `maxEnt` (logistic regression) is "very fast, robust, and effective", but "doesn't know anything except what it learns from the training data". It works by "noticing the words that are used most often in the training material".
  - Transfer learning (word embeddings with a neural network on top) "notices the meaning of words" and does better when real inputs "express a similar meaning with different words" (**WWDC**, [Advances in Natural Language Framework, WWDC19 232](https://developer.apple.com/videos/play/wwdc2019/232/)).
  - Options are `.crf`, `.maxEnt`, and `.transferLearning` with a `FeatureExtractorType` of `staticEmbedding`, `dynamicEmbedding`, `elmoEmbedding`, `bertEmbedding` or `customEmbedding`. Apple recommends `bertEmbedding` for multilingual data (**Doc**, [Creating a text classifier model](https://developer.apple.com/documentation/createml/creating-a-text-classifier-model); [ModelAlgorithmType](https://developer.apple.com/documentation/createml/mltextclassifier/modelalgorithmtype)).
  - The BERT embeddings ship as three models: Latin script, Cyrillic, and Chinese/Japanese/Korean, covering 27 languages (**WWDC**, [Explore Natural Language multilingual models, WWDC23 10042](https://developer.apple.com/videos/play/wwdc2023/10042/)). **Thai is not in any of the three script groups.**
- **Training data needs.** Training data is JSON or CSV `text`/`label` pairs, or folders named by label, with an 80/20 stratified train/test split (**Doc**, [Creating a text classifier model](https://developer.apple.com/documentation/createml/creating-a-text-classifier-model)). Apple gives no minimum count. Its examples: 200 examples for 14 classes gave 77% with maxEnt, and transfer learning improved on that (**WWDC** 19-232). Apple also advises: "make sure that your training data is as similar as possible to the text that you expect to see… sentence fragments, full sentences…", and to add data and retrain when the model fails (**WWDC** 19-232, 20-10657). Apple suggests generating synthetic variations with a generative model, for example "Generate 50 different ways a person might ask…" (**Doc**, [Evaluating prompts](https://developer.apple.com/documentation/foundationmodels/evaluating-prompts-to-measure-performance-and-improve-model-responses)).
- **Latency.** Apple gives no millisecond figure for `NLModel` classification. The closest published figure is for `NLEmbedding` nearest-neighbour search over compressed embeddings: "just a couple of milliseconds" (**WWDC** 19-232).

### Inference

- **Latency.** maxEnt is a linear model over tokens, so it should take well under a millisecond per call and can run on every keystroke without debounce. BERT transfer learning runs a transformer encoder: probably single-digit to tens of milliseconds on Apple silicon, plus a one-time model load. Both are far below Jev's ~100 ms network round trip. Measure in the eval.
- **Partial input.** Out of the box, maxEnt sees "remind m" as the token "remind" plus an unknown "m". It will only be right if "remind" was a strong Task feature in training. The fix is cheap and mechanical: augment every training example with its prefixes. Label each prefix with the example's label, or `unsure`/`Search` while the prefix is too short to tell. That teaches the classifier the "as you type" distribution directly. The probability then gives a natural "not yet sure" signal.
- **Accuracy.** In-domain accuracy can be high because the label space is tiny (three classes, or four with `unsure`). The risk is coverage: phrasing the data never showed. BERT transfer learning reduces that risk. The dataset can be bootstrapped from the eval set, with variations generated by an LLM (Jev, Foundation Models or a frontier model) and checked by Beam. It can also double as the eval set for the other arms, kept as a separate held-out split.
- **A three-class trap.** "Search" is open-ended (any app or file name). A classifier trained only on intent phrases will be wrong on arbitrary file names. The heuristic gate (Search tiers) covers the strong cases. The training set still needs many plain names and fragments labelled Search.

### Effort

Medium. Code integration is small: one `.mlmodel` in the bundle, an `NLModel` and a threshold. Note that Hana is a SwiftPM package, so the model is loaded with `NLModel(contentsOf:)` from a compiled `.mlmodelc` resource rather than through Xcode's generated class; that is a detail to confirm. The work is the dataset: collecting, labelling, augmenting, retraining. Unlike Foundation Models, behaviour doesn't drift with OS updates, because the model ships with the app.

### Variant 2b: sentence embedding plus nearest prototype (no training)

`NLEmbedding` provides built-in sentence embeddings (`sentenceEmbedding(for:)`) and distance queries (**Doc**, [NLEmbedding](https://developer.apple.com/documentation/naturallanguage/nlembedding)). **Inference:** embed a handful of prototype phrases per mode and pick the nearest. That needs no training and gives a distance as a rough confidence, but it is likely weaker than a trained classifier on fragments. I did not check `sentenceEmbedding(for:)`'s own platform floor or language list. It is worth including only as a cheap extra eval arm.

## Option 3: Deterministic heuristics

### Facts (from this repo)

- Hana already computes `SearchName.Tier` for every result on every query. It promotes applications matching at `wordStart` or better (`Sources/Hana/SearchName.swift`, `Sources/Hana/Search.swift`).
- Mode prefixes (`-`, `[`) and the New note / New task suggestions remain (#101 standing rules).

### Inference

- **Role.** This is the gate, not the classifier.
  1. If Search has a strong match (a promoted app, or an exact or phrase-prefix name), stay in Search. This is the standing rule.
  2. Else, if the text starts with a Task lexicon entry, or a prefix of one ("remind me", "todo", "buy", "call", "email", "pay", "book", "schedule"), suggest Task.
  3. Otherwise defer to the classifier, or stay in Search when there is none.
- **Partial input.** Handled naturally by prefix-matching the lexicon. "remind m" is a prefix of "remind me", and "term" is caught by rule 1.
- **Confidence.** Binary per rule. It can be ranked by rule strength: an exact keyword beats a keyword prefix.
- **Accuracy ceiling.** High precision on the cases it covers, but no recall on free text. "milk eggs bread", "idea for the talk: …" and "dentist thursday" all need a model. It also can't tell Note from Task when there is no verb. Note has almost no lexical marker, so as a stand-alone option it would mostly decide "Task or nothing".
- **Effort.** Low, and it can be fully unit-tested in Hana's existing test style. The OS floor is irrelevant.

## Suggested eval shape (input to #106 and later tickets)

These are inferences, not decisions.

1. **One labelled dataset.** Beam's ~20 inputs, expanded with LLM-generated variations and reviewed. Every example also appears as its prefixes, so the "as you type" curve can be measured. Include app and file names, multilingual examples if Beam types other languages, and sensitive-sounding notes to exercise guardrails.
2. **Arms.** Jev; Foundation Models guided enum (greedy, with and without an `unsure` case); Create ML maxEnt; Create ML BERT; heuristics alone. Run each arm behind the heuristic gate as well.
3. **Metrics.** Accuracy per prefix length, the wrong-switch rate (the costly error), latency p50/p95 (Foundation Models measured with Instruments, cold and warm), and the rate of errors or unavailability (Foundation Models).
4. **Tooling.** The Foundation Models Python SDK or the Evaluations framework can batch-run the Foundation Models arm. Create ML reports `evaluation(on:)` metrics directly.

## Gaps and open points

- **No published macOS latency** for Foundation Models; the only figures are for iPhone 15 Pro (2024 model). This must be measured.
- **No documented confidence or logprob API** in Foundation Models. If a newer API exists, I didn't find it on the Response, GeneratedContent or GenerationOptions pages.
- **Undocumented:** whether the KV-cached instruction prefix is shared across separate sessions with identical instructions, and how cancelling an in-flight `respond` behaves. Both matter for per-keystroke use.
- **Rate limits.** Their thresholds for frequent short on-device requests aren't documented. Whether Hana's bar counts as "background" for rate limiting is also unknown (it is an accessory/panel app).
- **No `NLModel` inference latency figure** is published.
- **No minimum training-set size** is given for `MLTextClassifier`; the only data point is Apple's 200-examples-for-14-classes demo.
- **Thai.** It is not among the Apple Intelligence languages, and not among the BERT script groups I could confirm. maxEnt with Natural Language tokenization might handle Thai, but I didn't verify that.
- **Unchecked here:** `sentenceEmbedding(for:)` availability and languages; loading `.mlmodelc` resources from a SwiftPM executable target.
- **Unknown rollout:** how the three Foundation Models model versions (26.0–26.3, 26.4, 27.0) are distributed among Hana's users, which is just Beam for now.

## Sources

Apple developer documentation (read through each page's DocC JSON on developer.apple.com, 2026-10-15):
[Foundation Models](https://developer.apple.com/documentation/foundationmodels) ·
[SystemLanguageModel](https://developer.apple.com/documentation/foundationmodels/systemlanguagemodel) ·
[Availability.UnavailableReason](https://developer.apple.com/documentation/foundationmodels/systemlanguagemodel/availability-swift.enum/unavailablereason) ·
[Generating content and performing tasks](https://developer.apple.com/documentation/foundationmodels/generating-content-and-performing-tasks-with-foundation-models) ·
[Generating Swift data structures with guided generation](https://developer.apple.com/documentation/foundationmodels/generating-swift-data-structures-with-guided-generation) ·
[Generable](https://developer.apple.com/documentation/foundationmodels/generable) ·
[prewarm(promptPrefix:)](https://developer.apple.com/documentation/foundationmodels/languagemodelsession/prewarm(promptprefix:)) ·
[Optimizing key-value caching](https://developer.apple.com/documentation/foundationmodels/optimizing-key-value-caching-in-language-model-sessions) ·
[Analyzing the runtime performance](https://developer.apple.com/documentation/foundationmodels/analyzing-the-runtime-performance-of-your-foundation-models-app) ·
[LanguageModelSession](https://developer.apple.com/documentation/foundationmodels/languagemodelsession) ·
[LanguageModelSession.Response](https://developer.apple.com/documentation/foundationmodels/languagemodelsession/response) ·
[GeneratedContent](https://developer.apple.com/documentation/foundationmodels/generatedcontent) ·
[GenerationOptions](https://developer.apple.com/documentation/foundationmodels/generationoptions) ·
[greedy](https://developer.apple.com/documentation/foundationmodels/generationoptions/samplingmode-swift.struct/greedy) ·
[LanguageModelError](https://developer.apple.com/documentation/foundationmodels/languagemodelerror) ·
[Improving the safety of generative model output](https://developer.apple.com/documentation/foundationmodels/improving-the-safety-of-generative-model-output) ·
[Supporting languages and locales](https://developer.apple.com/documentation/foundationmodels/supporting-languages-and-locales-with-foundation-models) ·
[Prompting an on-device foundation model](https://developer.apple.com/documentation/foundationmodels/prompting-an-on-device-foundation-model) ·
[Updating prompts for new model versions](https://developer.apple.com/documentation/foundationmodels/updating-prompts-for-new-model-versions) ·
[Categorizing and organizing data with content tags](https://developer.apple.com/documentation/foundationmodels/categorizing-and-organizing-data-with-content-tags) ·
[Adding server-side intelligence with Private Cloud Compute](https://developer.apple.com/documentation/foundationmodels/adding-server-side-intelligence-with-private-cloud-compute) ·
[Evaluating prompts](https://developer.apple.com/documentation/foundationmodels/evaluating-prompts-to-measure-performance-and-improve-model-responses) ·
[Foundation Models updates](https://developer.apple.com/documentation/updates/foundationmodels) ·
[MLTextClassifier](https://developer.apple.com/documentation/createml/mltextclassifier) ·
[Creating a text classifier model](https://developer.apple.com/documentation/createml/creating-a-text-classifier-model) ·
[MLTextClassifier.ModelAlgorithmType](https://developer.apple.com/documentation/createml/mltextclassifier/modelalgorithmtype) ·
[NLModel](https://developer.apple.com/documentation/naturallanguage/nlmodel) ·
[predictedLabelHypotheses(for:maximumCount:)](https://developer.apple.com/documentation/naturallanguage/nlmodel/predictedlabelhypotheses(for:maximumcount:)) ·
[NLEmbedding](https://developer.apple.com/documentation/naturallanguage/nlembedding) ·
[NLContextualEmbedding](https://developer.apple.com/documentation/naturallanguage/nlcontextualembedding)

WWDC sessions (transcripts):
[WWDC25 286 Meet the Foundation Models framework](https://developer.apple.com/videos/play/wwdc2025/286/) ·
[WWDC25 301 Deep dive into the Foundation Models framework](https://developer.apple.com/videos/play/wwdc2025/301/) ·
[WWDC25 259 Code-along](https://developer.apple.com/videos/play/wwdc2025/259/) ·
[WWDC26 334 fm CLI and Python SDK](https://developer.apple.com/videos/play/wwdc2026/334/) ·
[WWDC19 232 Advances in Natural Language Framework](https://developer.apple.com/videos/play/wwdc2019/232/) ·
[WWDC20 10657 Make apps smarter with Natural Language](https://developer.apple.com/videos/play/wwdc2020/10657/) ·
[WWDC23 10042 Explore Natural Language multilingual models](https://developer.apple.com/videos/play/wwdc2023/10042/)

Other Apple sources:
[Apple ML Research: Introducing Apple's On-Device and Server Foundation Models (2024)](https://machinelearning.apple.com/research/introducing-apple-foundation-models) ·
[Apple ML Research: Updates to Apple's On-Device and Server Foundation Language Models (2025)](https://machinelearning.apple.com/research/apple-foundation-models-2025-updates) ·
[Apple Support: How to get Apple Intelligence](https://support.apple.com/en-us/121115)
