# Nudgy Roadmap

Scope decisions for data acquisition. Companion to `DESIGN_DOC.md` and `ARCHITECTURE.md`.

The through-line: **the layers above the connector never change.** Normalizer, proposal engine,
citations, safety rules, notifications, and on-device Gemma are identical no matter where the FHIR
came from. Every item below is an adapter behind `HealthSourceConnector`, which is why these can
ship in any order without rework.

```swift
protocol HealthSourceConnector {
    var source: HealthSourceDescriptor { get }
    func authorize() async throws
    func fetch() async throws -> [FHIRResource]
}
```

---

## V1 — shipped in this build

**Data sources:** real MITRE Synthea R4 bundles + an authored portal-export bundle, both parsed by
the production decoding and normalization path. Manual entry.

Only the *transport* is stubbed. The FHIR shapes, the citation plumbing, and every safety rule are
production code, exercised against real synthetic patient records.

**Privacy claim:** absolute. No health data leaves the phone, because there is no health-data
egress path at all. The only network access in the entire app is the Gemma model-weight download.

---

## V2 — real patient-authorized MyChart / Epic access

**Status: planned, build if time allows. This is the intended real-data path.**

Patient-authorized SMART on FHIR. The user authenticates with their own MyChart credentials
through the provider's own authorization page; Nudgy never sees the password.

```
User ──► MyChart authorization page (ASWebAuthenticationSession)
             │
             ▼  authorization code + PKCE verifier
        Token exchange ──► access token in Keychain
             │
             ▼
   FHIR resources pulled DIRECTLY provider ──► phone
             │
             ▼
        Encrypted local vault (existing)
```

**This preserves the V1 privacy claim exactly.** No intermediary sees the data; the phone talks to
the provider's FHIR server. That is the reason to prefer this path over any aggregator.

What's already in place:
- `SMARTOnFHIRConnector` implementing the protocol, with the real scope list it would request
  (`launch/patient openid fhirUser offline_access patient/Patient.read patient/MedicationRequest.read
  patient/MedicationStatement.read patient/CarePlan.read patient/AllergyIntolerance.read
  patient/Appointment.read patient/Condition.read`).
- `EgressPolicy.futureFHIRAuthorization`, currently `isEnabledInV1: false` with a placeholder host
  so it is rejected today.
- A normalizer already written against genuine Epic-flavored FHIR shapes.

What remains to build:
1. **App registration** with Epic on FHIR — a patient-facing app, non-production client ID for the
   sandbox first. This is a lead-time item; start it before the code.
2. **PKCE** — S256 code verifier/challenge (CryptoKit, base64url, no padding).
3. **Endpoint discovery** — `.well-known/smart-configuration` per organization. Epic endpoints are
   per-organization; NYU Langone, Columbia, and Weill Cornell each have their own base URL. Do not
   wildcard these in `EgressPolicy` — enumerate them.
4. **`ASWebAuthenticationSession`** for the authorization leg, plus a registered redirect scheme.
5. **Token storage** in the Keychain under a service **distinct** from `app.nudgy.Nudgy.vault`, with
   refresh handling for `offline_access`.
6. **Pagination** — Epic returns `Bundle.link[rel=next]`; the demo bundles do not, so this is
   genuinely untested code today.
7. Flip `EgressPolicy.futureFHIRAuthorization` to enabled and replace the placeholder host.

**Recommended proving order:** Epic's public sandbox first (self-serve, real OAuth, fake patients),
then a real MyChart account. The sandbox validates every step above without any PHI in the loop.

---

## Tross — evaluated and declined

**Status: decided against. Not on the roadmap.** Direct patient-authorized FHIR (V2 above) is the
data-acquisition path. This section is kept as the record of why, and what would have to change if
the question is ever reopened.

The deciding argument: Tross's value is **breadth**, and Nudgy's value is **trust**. Paying for the
former with the latter is a bad trade for this product. An aggregator makes sense for a company
whose differentiator is coverage; Nudgy's differentiator is that the answer to "who else has seen
this?" is *nobody*. Introducing an intermediary to reach more portals would spend the single thing
the product is actually selling.

Practical consequences of this decision, which are what make it worth writing down:

- `EgressPolicy` keeps **zero** hosts with `receivesHealthData: true`. The only network access in
  the app remains the Gemma model-weight download.
- The privacy status strip stays **unconditional**. No connected-mode variant, no consent-gated
  second state, no mode-dependent copy — the claim is simply true, everywhere, always.
- The two-mode "local-first with consented connected mode" reframing is **not needed**. The product
  stays local-only, which is a stronger and simpler thing to say.
- Coverage gaps (payer portals, non-Epic systems) are handled by **manual entry**, which already
  exists and carries `DataOrigin.manualEntry` provenance, rather than by a third party.

### What would reopen it

Only one thing: a genuine direct-to-device path where Tross brokers authorization but records flow
provider → phone without transiting their infrastructure. That would make it an authorization
convenience rather than a data intermediary, and the objection above would not apply. Absent that,
the analysis below stands.

### Original analysis (retained for the record)

[Tross](https://ontross.com/) is an early-stage API layer for EHR **and payer portal** data,
positioning itself around eliminating multi-month EHR integration timelines.

**Its value is breadth, not privacy** — reaching insurers and non-Epic systems that have no
patient-facing FHIR API at all. That is a real problem, and a real reason to want it.

But it is an intermediary, and that changes a claim rather than just an implementation:

```
V2 (direct):  provider ──────────────► phone        "no health data leaves this phone"
V3 (Tross):   provider ──► Tross cloud ──► phone     claim must be restated
```

If adopted, the product moves from **local-only** to **local-first with an explicitly consented
connected mode**, exactly as `DESIGN_DOC.md` anticipates ("If a future cloud feature is added, it
must be clearly separated from local-only mode"). Concretely that means: a visually distinct mode,
consent copy naming Tross as a processor, `EgressPolicy` gaining its first host with
`receivesHealthData: true`, and the status strip telling the truth about it.

Note that **on-device Gemma inference is unaffected** in all three tiers — the model never leaves
the phone regardless of where records came from.

### Due diligence — ask in this order

The first question is load-bearing and the rest only matter if it passes:

1. **Does PHI persist on Tross infrastructure, or does it only transit?** Transit-only with no
   retention is defensible inside a local-first framing. Storage and processing is a materially
   different product.
2. Will they sign a BAA?
3. Is access official FHIR/OAuth, delegated patient access, or browser automation? Payer-portal
   coverage implies credential-mediated access, which carries different consent and durability
   properties than patient OAuth.
4. Is there any direct-to-device path where Tross brokers authorization but data flows straight to
   the phone? If so, most of the concern above evaporates.
5. Can it operate without long-term credential storage?
6. Does it return structured medication and PT/action-instruction data, or documents needing
   extraction? The proposal engine needs the former.
7. Coverage for NYU Langone, Columbia, Weill Cornell.
8. Handling of MFA, CAPTCHA, portal UI changes, and revoked access.

There are no public developer docs (`docs.ontross.com` does not resolve), so this evaluation
requires a direct conversation and likely an NDA. It cannot be validated on a hackathon timeline.

---

## Deferred (per design doc)

- On-device OCR for medication labels. v1 ships the camera affordance with clearly-labelled sample
  data and creates no reminder from a photo.
- Twilio. Not needed while reminders are local notifications, and it would move communication data
  off the device.
- Drug interaction logic. Requires an approved knowledge base; out of scope until then.
