# Remli Roadmap

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
through the provider's own authorization page; Remli never sees the password.

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
5. **Token storage** in the Keychain under a service **distinct** from `app.remli.Remli.vault`, with
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

The deciding argument: Tross's value is **breadth**, and Remli's value is **trust**. Paying for the
former with the latter is a bad trade for this product. An aggregator makes sense for a company
whose differentiator is coverage; Remli's differentiator is that the answer to "who else has seen
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

## Considered: ingredient-level matching

**Status: not built. Recorded because the evaluation was informative and the case will get stronger
with real data.**

Remli currently reconciles medications by their display string. The question was whether to switch
to RxNorm codes, on the theory that real portals write the same drug differently. Measured against
all 111 Synthea patients before building anything:

```
3,274 medication codings · 95 distinct RxNorm codes · 95 distinct display strings
codes written with more than one display string:  0
display strings mapping to more than one code:    0
```

**Identity matching by code would be a no-op**, at least here. Synthea emits canonical strings from
one table, so string and code agree perfectly. This measurement says nothing about real portals —
it says Synthea cannot test the question.

The same pass surfaced something better. **14 of 111 patients (12.6%) hold two or more *active*
products sharing an ingredient:**

```
Donte636   Acetaminophen 300 MG / Codeine
           Acetaminophen 300 MG / Hydrocodone
           Acetaminophen 325 MG / Oxycodone      [Percocet]
           Acetaminophen 325 MG                  [Tylenol]

Ursula220  Simvastatin 10 MG + Simvastatin 20 MG
```

Only one of Donte's four says "Tylenol". An ingredient hidden inside a combination product is
invisible in the brand name, which is exactly why this is worth surfacing and exactly why a person
would not spot it themselves.

### What could be said, and what could not

Stating the overlap is a fact derivable from the record's own coded data, and sits in the same
category as the existing cross-source conflict flag — it names a discrepancy without adjudicating
it:

> Three of your medications list **acetaminophen** as an ingredient: Percocet, Tylenol, and the
> hydrocodone tablet. Your pharmacist can tell you whether that is intended.

What Remli must not say is anything about maximum daily doses or consequences. That is clinical,
and it needs the approved drug knowledge base `DESIGN_DOC.md` defers.

### When to build it

**When medication names get messy** — that is, with real portal data rather than a generator. Two
things become true at once: display strings stop agreeing, so code-based identity starts earning
its keep; and combination products appear under brand names, so ingredient overlap becomes harder
for a person to see and more valuable to surface.

At that point the mapping should come from RxNorm `has_ingredient` relationships rather than the
first-token heuristic used in the evaluation above, which works only because Synthea's strings are
canonical. An MCP server such as [`medical-mcp`](https://github.com/JamesANZ/medical-mcp) or a
DailyMed server can build that map **at development time**, shipped as a bundled table — never a
runtime lookup, which would send a medication name off the device and break the claim in §V1.

Note the demo data does not currently show this: Terry Glover holds only one acetaminophen product.
Demonstrating it would mean switching to a patient like Donte636 or adding a second
acetaminophen-containing medication to the authored bundle.

---

## Deferred (per design doc)

- On-device OCR for medication labels. v1 ships the camera affordance with clearly-labelled sample
  data and creates no reminder from a photo.
- Twilio. Not needed while reminders are local notifications, and it would move communication data
  off the device.
- Drug interaction logic. Requires an approved knowledge base; out of scope until then.
