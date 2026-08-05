# Nudgy Design Doc

## Summary

Nudgy is a privacy-first, on-device healthcare assistant for mobile phones. It helps people turn fragmented patient-portal health data into calm, reviewable, proactive reminders for recurring care actions.

The v1 product is not a diagnostic assistant. It focuses on reminders and summarization, especially for medication routines and physical therapy/home exercise tasks that people need to do repeatedly.

The assistant should feel like a private conversation with a careful health aide: calm, soothing, conversational, and transparent about where each reminder came from.

## Product Thesis

Patients often receive care across multiple systems, such as NYU Langone MyChart, Columbia MyChart, and Cornell/Weill Cornell MyChart. Important care instructions are scattered across medication lists, visit summaries, discharge notes, clinician messages, and appointment instructions.

Nudgy helps by:

- Connecting to health portals where possible.
- Collecting relevant health data into an encrypted local vault.
- Finding recurring action items.
- Proposing reminders with source citations.
- Letting the user approve, edit, or skip each reminder.
- Sending local phone notifications after approval.
- Supporting calm voice and text interaction on device.

## V1 Scope

V1 should focus narrowly on recurring action reminders.

Included:

- Medication reminders.
- Physical therapy or home exercise reminders.
- Reminder proposals from explicit chart sources.
- Source citations for every generated reminder.
- User review before activation.
- Local push notifications.
- Voice and text conversation inside the app.
- Medication-label photo capture shown as a UI/demo affordance only.

Excluded:

- Diagnosis.
- Treatment recommendations.
- Urgent triage.
- Autonomous medication timing advice.
- Cloud-based PHI processing.
- SMS/call reminders containing PHI.
- Fully automated reminder creation without user review.

## Core User Flow

1. User connects health sources, ideally through patient-authorized MyChart/Epic FHIR access.
2. Nudgy imports supported data to an encrypted local health vault.
3. The on-device reminder engine identifies possible recurring care actions.
4. Nudgy presents each proposed reminder conversationally.
5. Each proposal cites the source record.
6. User approves, edits, or skips.
7. Approved reminders become local phone notifications.
8. User can ask follow-up questions by voice or text.

Example:

```text
I found a possible reminder from your Columbia medication list.

Metformin 500 mg
Instruction: "Take 1 tablet by mouth twice daily with meals."

Would you like me to remind you around breakfast and dinner?

[Approve] [Edit] [Skip]
```

## Reminder Rule Policy

Every generated rule must distinguish between clinical source facts and assistant suggestions.

Rule categories:

- From your record: directly sourced chart or label text.
- Pattern noticed: inferred from user routine, calendar, or app usage.
- Needs review: user must confirm before activation.

Rules:

- Every reminder proposal must cite its source.
- The assistant may propose reminders from medication lists, prescription instructions, after-visit summaries, discharge instructions, PT plans, appointment instructions, and clinician messages.
- If medication timing or food instructions are absent, the assistant should not invent clinical advice.
- The assistant may suggest convenient reminder windows from non-clinical context, but must label them as convenience suggestions.
- The assistant can flag possible inconsistencies without giving medical advice.
- Every generated reminder must be approved individually in v1.

Example safe language:

```text
Your chart says this is taken once daily.
It does not say what time of day.

Mornings look open in your calendar, so I can remind you then if that matches your routine.
```

Unsafe v1 language:

```text
You should take this medication in the morning.
```

## Medication And PT Reminder Complexity

Medication reminders can become clinically sensitive because timing, food, interactions, and side effects matter.

V1 should handle this conservatively:

- If the source says "with food," preserve that instruction.
- If one source has a food instruction and another does not, show a possible concern flag.
- If multiple medications have close reminder times, offer notification-management options rather than medical advice.
- If interaction logic is needed, defer to pharmacist/clinician guidance unless sourced from an approved drug knowledge base in a future version.

PT and exercise reminders should also cite source instructions:

- Exercise name.
- Frequency.
- Duration or repetitions.
- Equipment requirements if explicitly stated.
- Body position if explicitly stated.

If equipment or safety constraints are unclear, the assistant should ask the user to review or confirm with the care team.

## Medication Photo UI Affordance

Users can see an entry point for adding a medication by taking a picture of a bottle or label. In v1, this should be treated as a UI/demo affordance, not a backend-enabled feature.

V1 behavior:

1. User taps "Add from photo."
2. The app opens the phone camera.
3. The UI can show a draft-review concept using sample/demo data.
4. No production backend OCR, extraction, or medication parsing is required in v1.
5. No reminder should be created from a photo in production v1 unless the user manually enters and approves the medication details.

This feature is useful to communicate the future direction when portal data is incomplete, delayed, or unavailable. The production v1 implementation should prioritize MyChart/FHIR-sourced reminders and manually entered reminders.

Demo example:

```text
Draft from photo

Metformin 500 mg
Instruction found: Take 1 tablet by mouth twice daily with meals.
Source: medication label photo, processed on device

[Approve reminder] [Edit first]
```

Post-v1 behavior may add on-device OCR and extraction:

1. OCR and extraction run on device.
2. Nudgy drafts medication name, dose, and instructions.
3. The source is cited as the medication label photo.
4. The user must approve or edit before any reminder is created.

## Interaction Model

The UI should feel like a conversation, not a generic chatbot.

Design principles:

- Use a flowing timeline rather than support-chat bubbles as the only structure.
- Include short assistant turns.
- Periodically show "I heard" summaries.
- Convert health details into reviewable cards.
- Keep privacy status visible.
- Make voice primary for quick capture.
- Make text available for precise or sensitive details.
- Keep the tone calm, careful, and soothing.

Primary screen components:

- Header: private conversation state and on-device status.
- Status strip: microphone, storage, mode.
- Timeline: assistant messages, user turns, local summaries, proposed reminders.
- Composer: microphone, text input, quick actions.
- Side action: add medication from photo.

## Privacy Model

The product promise is that PHI stays on the device.

Required:

- On-device Gemma model inference.
- Encrypted local health vault.
- Local notification scheduling.
- On-device OCR for medication labels.
- On-device speech-to-text and text-to-speech where feasible.
- No PHI in analytics, crash logs, remote debugging, SMS, or cloud backups unless explicitly designed and consented.

If a future cloud feature is added, it must be clearly separated from local-only mode.

## Data Acquisition

Preferred path:

- Patient-authorized SMART on FHIR / Epic on FHIR access.
- User authenticates through the provider's MyChart authorization flow.
- The app requests specific scopes.
- The mobile app pulls supported FHIR resources and stores them locally.

Useful resources may include:

- MedicationRequest / MedicationStatement.
- Appointment.
- DocumentReference.
- CarePlan.
- Observation.
- AllergyIntolerance.
- Condition.
- Patient.

Epic supports patient-facing apps where users authenticate with MyChart credentials through OAuth 2.0 and authorize access to specific health data. MyChart Central may also allow sharing data across multiple organizations when supported.

References:

- Epic on FHIR patient-facing apps: https://fhir.epic.com/Documentation?docid=implementing&section=interfacesetupforapps
- Epic patient authentication: https://open.epic.com/Tutorial/PatientAuthentication?whereFrom=MyChart
- MyChart Central app access: https://www.mychart.org/l/en-us/help/app-access-central/

## Twilio Assessment

Twilio is not needed for v1 if reminders are local phone notifications and PHI stays on device.

Twilio may be useful later for:

- SMS reminders.
- Voice-call reminders.
- Caregiver notifications.
- Provider-side engagement workflows.
- Remote voice agent workflows.

However, using Twilio means communication data leaves the device. Even if configured as HIPAA-eligible with a BAA, that is different from a strict local-only privacy promise.

For v1, avoid Twilio except perhaps for generic messages with no PHI, such as:

```text
You have a reminder in Nudgy.
```

References:

- Twilio Healthcare: https://www.twilio.com/en-us/solutions/healthcare
- Twilio HIPAA messaging help: https://help.twilio.com/articles/360059959413
- Twilio ConversationRelay: https://static0.twilio.com/docs/voice/twiml/connect/conversationrelay

## Tross Assessment

Tross may be relevant for EHR and payer portal integration, but it needs due diligence.

Open question:

```text
Does PHI pass through Tross infrastructure?
```

If yes, Tross conflicts with the strict v1 privacy promise. If Tross offers an on-device SDK or a direct-to-device OAuth/FHIR path where PHI does not touch Tross servers, it may be useful.

Questions for Tross:

- Does it support patient-facing MyChart portals?
- Does it support NYU Langone, Columbia, and Cornell/Weill Cornell?
- Is access official FHIR/OAuth, delegated patient access, or browser automation?
- Can it return structured medication and PT/action-instruction data?
- Can it operate without long-term credential storage?
- Will PHI pass through Tross servers?
- Will they sign a BAA?
- How do they handle MFA, CAPTCHA, portal UI changes, and revoked access?

Reference:

- Tross: https://ontross.com/

## Suggested V1 Architecture

```text
MyChart / Epic OAuth
        |
FHIR resources pulled by mobile app
        |
Encrypted local health vault
        |
Normalizer for meds, PT tasks, appointments, notes
        |
On-device reminder proposal engine
        |
Gemma on-device conversational layer
        |
User review and approval
        |
Local notifications
```

Deferred side path:

```text
Medication label photo
        |
On-device OCR/extraction
        |
Draft medication reminder
        |
User review and approval
        |
Local notification
```

This side path is not required for production v1.

## Demo Recommendation

Build the first demo on iOS.

Reasons:

- Strong privacy expectations.
- Strong healthcare story through Apple Health and HealthKit permissions.
- Good local notification and secure storage primitives.
- On-device speech and privacy messaging demo well.
- The "your health data stays on your phone" story is easy to understand.

Android remains important, especially because Gemma/mobile AI positioning is strong there, but iOS is likely the cleaner first product demo.

## V1 Success Criteria

The demo should prove this loop:

```text
Connect health source
-> extract medication or PT action item
-> cite source
-> propose reminder
-> user approves
-> local notification
-> calm voice/text follow-up
```

The product is successful if users trust the assistant because it is:

- Local-first.
- Source-cited.
- Reviewable.
- Calm.
- Useful for daily health actions.
- Careful about what it does not know.

---

## Amendments Made During Implementation

This section records where the built product diverges from the specification above, and why. The
original text is left unedited: it is the statement of intent, and knowing what was changed is more
useful than a document that quietly agrees with the code.

### 1. Individual approval replaced by tiered activation

**Specified:** "User review before activation", "Every generated reminder must be approved
individually in v1", and "Fully automated reminder creation without user review" under Excluded.

**Built:** proposals are sorted into three tiers. Unambiguous, fully-timed reminders schedule
themselves on import; only cross-source conflicts and missing details wait for a person; as-needed
medications are kept as records and never given a time.

**Why:** the real Synthea patient produced eighteen proposals. Eighteen cards is not review — by
the sixth, people tap Approve without reading, which is worse for safety than reviewing the two
that matter. Approval did not disappear, it moved to where it is cheap: a running reminder shows
where it came from and can be retimed or stopped from its card or its notification.

**The line held:** a proposal where two clinics recorded different instructions is *never*
auto-activated. That is the case where a human is genuinely worth the interruption.

### 2. Voice input cut

**Specified:** "Voice and text conversation inside the app", and "Make voice primary for quick
capture".

**Built:** text input and spoken read-back. Dictation is preserved at
`ios/Deferred/SpeechCapture.swift`, outside the build target.

**Why:** dictation sits outside the connect → cite → propose → approve → notify loop the product is
judged on, while carrying the most failure modes in the app — audio session lifecycle, two
permission flows, on-device availability that varies by locale, and no microphone in the Simulator.
Typing is also the better default for the field people most need to get exactly right: a dose.

This does not affect the on-device model. Gemma narrates proposals and answers questions in text;
voice input was never what justified it.

### 3. Gemma proposes reminder times

**Specified:** "The assistant may suggest convenient reminder windows from non-clinical context,
but must label them as convenience suggestions."

**Built:** exactly that, with the model doing the choosing. Gemma is given the medication, the
record's own instruction, any meal anchor the chart named, the times of the person's other
reminders, and any routine they have mentioned — and picks times that space around them. The result
is schema-validated (right count, waking hours, spaced apart) with deterministic spacing as the
floor, so a reminder always arrives able to fire.

**The line held:** provenance stays `.convenienceSuggestion`, the chip reads "My suggestion", and
the clock renders muted rather than sage. `SafetyGuard` permits Gemma to say "I've set this for
9:30" and still refuses "your chart says 9:30". Doses remain strict under every framing.

### 4. Nutrition added

**Specified:** medication and PT reminders.

**Built:** diet guidance as a third item type. Care-plan diet activities, `NutritionOrder` including
`excludeFoodModifier`, and food allergies become meal-anchored cards.

**Why:** the data was already there and being discarded — the real Synthea patient carries a
"Diabetic diet" and a "Dietary Approaches to Stop Hypertension diet", both cited care-plan entries,
which the therapy parser skipped because they are not exercise.

**The line held:** Nudgy restates, it does not compose. Nothing is inferred from a diagnosis —
"diabetic" does not become "avoid sugar" — and hydration reminders are deliberately absent, because
hydration is almost never in a chart and generating one would be inventing health advice. It
remains available through user-created reminders, where the person is the source.

### 5. Tross declined

**Specified:** an open question pending due diligence.

**Decided:** not adopted. Its value is breadth; Nudgy's is trust. Full reasoning, and the one
condition that would reopen it, are in `ROADMAP.md`.
