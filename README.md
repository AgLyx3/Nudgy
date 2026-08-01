# Nudgy

A privacy-first, on-device health assistant for iOS. It turns fragmented patient-portal records
into calm, source-cited, individually-approved reminders for medications and physical therapy.

Health data stays on the phone. The language model runs on the phone. Nothing leaves it.

---

## The idea in one diagram

The hardest requirement in `DESIGN_DOC.md` is not the FHIR import or the notifications — it is
this pair of rules:

> Every reminder proposal must cite its source.
> If medication timing or food instructions are absent, the assistant should not invent clinical advice.

A language model cannot be trusted to honor those by instruction alone, so Nudgy does not ask it to:

```
        ┌──────────────────────────────────────┐
FHIR ─► │  DETERMINISTIC CORE (trusted)        │ ─► ReminderProposal
        │  normalizer → proposal engine        │    every field traced to a citation
        └──────────────────────────────────────┘
                        │ structured, already-decided facts
                        ▼
        ┌──────────────────────────────────────┐
        │  GEMMA (untrusted, cosmetic)         │ ─► narration
        │  phrases it warmly, answers "why?"   │
        └──────────────────────────────────────┘
                        │
                        ▼  SafetyGuard — reject → deterministic template
```

Gemma never decides anything clinical. It never picks a dose, a time, a frequency, or a food
instruction. Those are computed from FHIR fields, each carrying a `SourceCitation` pointing at the
exact resource and the verbatim text it came from. Gemma writes the sentence around the answer.

If Gemma is unavailable, the app loses warmth and keeps correctness.

Full reasoning: **[ARCHITECTURE.md](ARCHITECTURE.md)**. Scope decisions: **[ROADMAP.md](ROADMAP.md)**.

---

## Status

⚠️ **Work in progress.** Subsystems are individually verified; the full target has not been built
end to end yet. Read the table honestly before running anything.

| Subsystem | State | How it was verified |
|---|---|---|
| Domain model + provenance types | ✅ | Typechecks; provenance is unforgeable by construction |
| FHIR decoding (R4 subset) | ✅ | Decodes real Synthea bundles + authored portal export |
| Encrypted vault | ✅ | AES-GCM, Keychain `ThisDeviceOnly`, complete file protection, excluded from backup |
| Normalizer + proposal engine | ✅ | **Executed** against both real bundles via a CLI harness |
| Notifications | ✅ | Typechecks against iOS SDK; discreet lock-screen copy |
| Design system + review UI | ✅ | Typechecks against iOS SDK |
| Gemma / LiteRT-LM layer | 🚧 | Written; verification in progress |
| Session wiring + conversation screen | ⬜ | Not started |
| Full app build + device run | ⬜ | **Not done yet** |
| SMART on FHIR (real MyChart) | ⬜ | V2 — planned, see ROADMAP |

---

## Running it

```sh
open ios/Nudgy.xcodeproj
```

iOS 17+, Xcode 16+. No third-party dependencies are required to build.

| Environment | Import | Proposal engine | Notifications | Gemma |
|---|---|---|---|---|
| iOS Simulator | real | real | real | scripted fallback |
| iPhone (A17 Pro or newer) | real | real | real | **real Gemma 4 E2B** |

### Why Gemma needs a physical device

LiteRT-LM cannot run inference in the iOS Simulator — the CPU/XNNPACK path throws `INTERNAL` on
first generation and the GPU path fails to create an engine
([LiteRT-LM #2504](https://github.com/google-ai-edge/LiteRT-LM/issues/2504)). The app detects this
and falls back to deterministic narration, labelled "Scripted" in the UI rather than passed off as
model output. Every other layer is fully exercised in the Simulator.

### Enabling real Gemma

1. In Xcode: **File → Add Package Dependencies** → `https://github.com/google-ai-edge/LiteRT-LM`,
   version 0.13.0 or later. All model code is behind `#if canImport(LiteRTLM)`, so the project
   builds without this step.
2. Obtain `gemma-4-E2B-it.litertlm` (2.58 GB) from
   [`litert-community/gemma-4-E2B-it-litert-lm`](https://huggingface.co/litert-community/gemma-4-E2B-it-litert-lm).
   `GemmaModelManager` will find a side-loaded copy or download it on first launch.
3. Run on a physical device.

Gemma 4 E2B uses Google's mixed 2/4/8-bit mobile quantization derived from QAT checkpoints:
~607 MB peak RAM on the CPU backend, 56.5 tok/s decode and 0.3 s time-to-first-token on GPU
(iPhone 17 Pro figures).

---

## Data

No real patient data exists in this repository, and none should ever be added.

- **`synthea-glover.json`** — a trimmed bundle from [MITRE Synthea](https://github.com/synthetichealth/synthea),
  the open-source synthetic patient generator. Fully synthetic; no real person.
- **`portal-export-demo.json`** — hand-authored, tagged `data-origin: authored-demo`, which the app
  reads and surfaces in the UI so demo data is never mistaken for a chart pull.

The authored bundle exists because Synthea's `MedicationRequest.dosageInstruction` carries only
`timing.repeat` — **no instruction text, no food instruction, no time of day**. That gap is not a
problem to work around; it is the product's central case:

> "Your chart says this is taken once daily. It does not say what time of day."

Real Synthea data drives that path. The authored bundle additionally exercises verbatim dosage
text, an `ACM` timing code, PT activities with reps and equipment, and a deliberate cross-source
food-instruction conflict.

---

## Deliberately not built

Per the design doc's exclusions: no diagnosis, no treatment recommendation, no triage, no
autonomous timing advice, no cloud PHI processing, no SMS/voice reminders, and no reminder that
activates without individual approval.

Two scope decisions made during the build, both recorded with reasoning:

- **Voice input cut from v1** (`ARCHITECTURE.md` §8). It sits outside the
  connect → cite → propose → approve → notify loop while carrying the most failure modes in the
  app. Implementation preserved at `ios/Deferred/SpeechCapture.swift`. Spoken read-back is kept.
- **Tross declined** (`ROADMAP.md`). Its value is breadth; Nudgy's is trust. Direct
  patient-authorized FHIR keeps the privacy claim literally true.

Medication-label photo capture is a UI affordance only. The camera opens, a clearly-labelled sample
draft appears, and no reminder can be created from it.

---

## Layout

```
DESIGN_DOC.md            product spec (source of truth for what Nudgy may say)
ARCHITECTURE.md          how the safety properties are structurally enforced
ROADMAP.md               data-acquisition scope: V1, V2 MyChart, Tross decision
ios/Nudgy/
  Core/Models/           domain types; provenance is a type, not a convention
  Core/FHIR/             R4 decoding + HealthSourceConnector seam
  Core/Normalize/        FHIR → domain, capturing citations
  Core/Reminders/        deterministic proposal engine + scheduling
  Core/Language/         Gemma protocol, LiteRT-LM, SafetyGuard, scripted fallback
  Core/Vault/            AES-GCM encrypted store
  Core/Privacy/          EgressPolicy — the only place network access is allowed
  Features/              SwiftUI
ios/Deferred/            preserved, intentionally outside the build target
web-prototype/           original static mockup, kept for reference
```
