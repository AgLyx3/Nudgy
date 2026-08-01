# Nudgy v1 Architecture

Companion to `DESIGN_DOC.md`. That document defines *what* Nudgy is and what it must never do.
This document defines *how* the app is built so those rules are structurally enforced rather
than merely intended.

Target: native iOS app, SwiftUI, iOS 17+, on-device Gemma 4 via LiteRT-LM.

---

## 1. The load-bearing idea

The design doc's hardest requirement is not the FHIR import or the notifications. It is this
pair of rules:

> Every reminder proposal must cite its source.
> If medication timing or food instructions are absent, the assistant should not invent clinical advice.

A language model cannot be trusted to honor those rules by instruction alone. So Nudgy does not
ask it to. The architecture splits the system in two:

```
                    ┌─────────────────────────────────────┐
                    │   DETERMINISTIC CORE (trusted)      │
   FHIR ──────────► │   normalizer → proposal engine      │ ──► ReminderProposal
                    │   every field traced to a citation  │     (the actual clinical content)
                    └─────────────────────────────────────┘
                                      │
                                      │ structured, already-decided facts
                                      ▼
                    ┌─────────────────────────────────────┐
                    │   GEMMA (untrusted, cosmetic)       │
                    │   phrases the proposal warmly       │ ──► narration text
                    │   answers "what is this from?"      │
                    └─────────────────────────────────────┘
                                      │
                                      ▼
                             SafetyGuard (regex + claim check)
                                      │
                          pass ────────┴──────── fail → deterministic template
```

**Gemma never decides anything clinical.** It never picks a dose, a time, a frequency, or a
food instruction. Those are computed by `ReminderProposalEngine` from FHIR fields, each carrying
a `SourceCitation` pointing at the exact resource and the verbatim text it came from. Gemma
receives the finished proposal and writes the sentence around it.

If Gemma is unavailable (simulator, model not downloaded, out of memory), the app loses warmth
and keeps correctness. The demo still runs end to end.

This is also the answer to "what happens when the model hallucinates on stage."

---

## 2. Layers

```
┌──────────────────────────────────────────────────────────────┐
│ Features/            SwiftUI. Conversation timeline, review  │
│                      cards, settings, photo affordance.      │
├──────────────────────────────────────────────────────────────┤
│ Language/            NudgyLanguageModel protocol             │
│                      ├─ LiteRTGemmaModel   (device, real)    │
│                      └─ ScriptedModel      (simulator)       │
│                      GroundedPromptBuilder, SafetyGuard      │
├──────────────────────────────────────────────────────────────┤
│ Reminders/           ReminderProposalEngine (deterministic)  │
│                      ScheduleResolver, NotificationScheduler │
├──────────────────────────────────────────────────────────────┤
│ Normalize/           FHIR → domain, citation capture         │
│                      DosageInstructionParser, PTTaskParser   │
├──────────────────────────────────────────────────────────────┤
│ FHIR/                Resource decoding, HealthSourceConnector │
│                      ├─ SyntheaBundleConnector (v1 demo)     │
│                      └─ SMARTOnFHIRConnector   (seam, later) │
├──────────────────────────────────────────────────────────────┤
│ Vault/               AES-GCM encrypted store, Keychain key   │
├──────────────────────────────────────────────────────────────┤
│ Models/              Domain types. No FHIR, no UI, no I/O.   │
└──────────────────────────────────────────────────────────────┘
```

Dependencies point downward only. `Models` knows nothing about anything else, which is what
makes the proposal engine testable without a device, a model file, or a network.

---

## 3. Provenance is a type, not a convention

Every user-visible clinical claim carries its origin in the type system:

```swift
enum Provenance {
    case fromYourRecord(SourceCitation)   // verbatim chart text
    case patternNoticed(basis: String)    // routine/calendar inference
    case needsReview(reason: ReviewReason)// user must confirm
    case convenienceSuggestion            // Nudgy's idea, explicitly not clinical
}
```

A `ReminderProposal` cannot be constructed without provenance for each of its clinical fields.
The UI renders provenance differently by case — record-sourced facts get the citation chip and
a tap-to-expand showing the raw source text; convenience suggestions get visibly softer styling
and hedged copy. There is no code path that renders a clinical instruction without its origin,
because there is no way to build one.

`SourceCitation` holds: resource type, resource id, source organization label, the field path
the text came from, and the **verbatim** string. The verbatim string is never paraphrased before
display — paraphrasing is exactly where a med instruction quietly changes meaning.

---

## 4. Deterministic proposal engine

Input: normalized `MedicationItem` / `TherapyTask`. Output: `ReminderProposal`.

What it does:

- **Frequency → slots.** `Timing.repeat{frequency: 2, period: 1, periodUnit: d}` becomes two
  daily slots. This is arithmetic on a structured field, not interpretation.
- **Times of day are never derived from clinical data**, because FHIR rarely encodes them. If
  the chart says "twice daily" with no time, the engine emits slots with `timeOfDay == nil` and
  a `needsReview(.timeOfDayNotSpecified)`. The UI then offers a *convenience suggestion*
  ("mornings look open") clearly labeled as Nudgy's idea, per the doc's safe-language example.
- **Food and route instructions are preserved verbatim**, never normalized into an enum that
  could lose nuance. "with meals" stays "with meals."
- **Conflict detection**, not resolution. Two sources disagreeing on a food instruction produces
  a `PossibleConcern` flag that shows both sources side by side and recommends asking the care
  team. Nudgy states the discrepancy; it does not adjudicate it.
- **Clustering** of reminders within a window produces a notification-management offer (bundle,
  stagger, or leave alone) — a UX decision, explicitly not a clinical one.

What it will not do: infer timing from drug class, apply interaction logic, or rank importance.
Those require a drug knowledge base and are out of v1 scope by the design doc.

---

## 5. Gemma 4 on device

**Runtime:** [LiteRT-LM](https://github.com/google-ai-edge/LiteRT-LM) Swift package (`import LiteRTLM`),
Google's production on-device inference framework.

**Model:** `litert-community/gemma-4-E2B-it-litert-lm` — Gemma 4 E2B in `.litertlm` format,
using Google's Gemma-4 mobile quantization scheme (a mixture of 2-, 4-, and 8-bit weights derived
from QAT checkpoints). 2.58 GB on disk; ~607 MB peak RAM on the CPU backend, ~1.45 GB on GPU.
Published iPhone 17 Pro figures: 56.5 tok/s decode and 0.3 s time-to-first-token on the GPU
backend.

**Why E2B over E4B:** E4B needs ~3.4 GB peak on the GPU backend, which is uncomfortably close
to the per-app memory ceiling on non-Pro iPhones. E2B leaves headroom for the vault, the speech
stack, and SwiftUI. Nudgy's model does narration, not reasoning, so E2B is sufficient.

**Model delivery:** the file is far too large to bundle. `GemmaModelManager` resolves it in
order: (1) a file already staged in Application Support, (2) a file dropped into the app
container during development, (3) a resumable background download from Hugging Face with
progress UI. Stored with `.completeFileProtection` and excluded from iCloud backup.

**Known constraint — the simulator cannot run inference.** LiteRT-LM fails in the iOS Simulator:
the CPU/XNNPACK path throws `INTERNAL` on first generation and the GPU path fails to create an
engine ([LiteRT-LM #2504](https://github.com/google-ai-edge/LiteRT-LM/issues/2504)). A physical
iPhone is required for real Gemma. `NudgyLanguageModel` therefore has two implementations, chosen
at runtime; the simulator gets `ScriptedModel` and the UI shows an honest "scripted narration"
badge rather than pretending. All non-model layers are fully exercised either way.

**Grounding.** The prompt is assembled by `GroundedPromptBuilder`, never by string interpolation
at a call site. It contains: a system message stating the assistant may only restate facts
present in the supplied context and must never give medical advice; the structured proposal as
labeled fields; and the user's question. No raw vault dump is ever placed in the context — only
the specific proposal under discussion.

**SafetyGuard.** Post-generation filter, applied to every token stream before display:

1. Reject imperative clinical advice patterns ("you should take", "it's safe to", "instead of").
2. Reject any dose, frequency, or time string that is not present in the grounding context —
   catches the highest-consequence hallucination class, invented numbers.
3. Reject diagnosis and triage language.

A rejection swaps in the deterministic template for that proposal and logs the event locally
(no PHI) so the failure is visible in Settings rather than silent.

---

## 6. Privacy implementation

The promise is "PHI stays on the device," so it is enforced at the boundary rather than by
convention:

- **Vault:** `CryptoKit` AES-GCM. Key generated on first launch, stored in the Keychain with
  `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` (never syncs, never restores to another
  device). Ciphertext written with `.completeFileProtection` and `isExcludedFromBackup`.
- **No analytics SDK, no crash reporter, no remote logging.** Not "PHI is scrubbed from
  analytics" — there is no analytics dependency to scrub.
- **Network egress is allowlisted to two hosts** and neither ever receives PHI: Hugging Face
  (model weights, outbound only) and the FHIR authorization/API host once SMART on FHIR lands.
  A single `EgressPolicy` type gates all `URLSession` use so this is auditable in one file.
- **Speech:** voice *input* was cut from v1 (see §8). Spoken read-back uses `AVSpeechSynthesizer`,
  which is local and involves no network. The deferred dictation implementation is preserved at
  `ios/Deferred/SpeechCapture.swift`, outside the build target; it gates on
  `SFSpeechRecognizer.supportsOnDeviceRecognition` and sets `requiresOnDeviceRecognition = true`,
  disabling dictation with an explanation rather than ever falling back to Apple's servers.
- **No Twilio in v1**, matching the doc's assessment.

The status strip is wired to real state — the "on device" indicator reflects the actual model
backend and egress state, not a static label.

---

## 7. Data acquisition

v1 ships `SyntheaBundleConnector`, reading real [Synthea](https://github.com/synthetichealth/synthea)
R4 bundles (MITRE's synthetic patient generator) through the same decoding and normalization
path production data will use. Only the transport is stubbed.

`HealthSourceConnector` is the seam:

```swift
protocol HealthSourceConnector {
    var source: HealthSourceDescriptor { get }
    func authorize() async throws
    func fetch(_ kinds: Set<FHIRResourceKind>) async throws -> [FHIRResource]
}
```

`SMARTOnFHIRConnector` (OAuth 2.0 + PKCE against Epic/MyChart, tokens in Keychain) implements
the same protocol and changes nothing above it. That is the whole point of building the
normalizer against real FHIR shapes now.

**Real patient-authorized MyChart access is the intended V2 and is planned, not cut.** See
`ROADMAP.md` for the concrete build steps, the Epic app-registration lead time, and why the
direct provider-to-phone path preserves the privacy claim in section 6 exactly — whereas routing
through an aggregator such as Tross would require restating it.

---

## 8. What is deliberately not built

Per the design doc's exclusions: no diagnosis, no treatment recommendation, no triage, no
autonomous timing advice, no cloud PHI processing, no SMS/voice reminders, and no reminder that
activates without individual user approval.

Photo capture is a UI affordance only — the camera opens and a clearly-labeled sample draft
appears. No OCR runs and no reminder can be created from a photo without the user typing and
approving the details, exactly as specified.

**Voice input is cut from v1** — a deliberate rescope against the design doc, which listed
"voice and text conversation" under v1 scope. Reasoning: dictation sits outside the
connect → cite → propose → approve → notify loop the product is judged on, while carrying the
most failure modes in the app (audio session lifecycle, two permission flows, on-device
availability that varies by locale, and no microphone in the Simulator). Typing is also the
better default for the field people most need to get exactly right — a dose. The implementation
is preserved at `ios/Deferred/SpeechCapture.swift` and can be restored by moving one file back
into the target.

Note this does not affect the on-device model: Gemma's role is narrating proposals and answering
"where did this come from?" in text. Voice input was never what justified it.

---

## 9. Running it

| Environment | FHIR import | Proposal engine | Notifications | Gemma |
|---|---|---|---|---|
| iOS Simulator | real | real | real | scripted fallback |
| iPhone (A17 Pro+) | real | real | real | **real Gemma 4 E2B** |

Physical device path requires: an Apple Developer team for signing, ~3 GB free storage, and a
first-launch model download.
