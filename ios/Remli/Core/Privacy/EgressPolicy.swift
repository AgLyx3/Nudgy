import Foundation

// ─────────────────────────────────────────────────────────────────────────────────────────────
//  THE INVARIANT
//
//  Remli makes exactly one promise that everything else rests on: protected health information
//  never leaves this device. This file is where that promise is made checkable rather than
//  merely intended.
//
//  1. No health data is ever placed in a URL path, query string, header, or request body by any
//     caller, anywhere in this app. Not hashed, not encrypted, not "de-identified". Not at all.
//  2. The only network egress in v1 is downloading Gemma model weights from Hugging Face. That
//     traffic is outbound-only in the meaningful sense: the request identifies a public model
//     file and nothing about the person using the app.
//  3. There is no analytics SDK, no crash reporter, and no remote logging in this project. This
//     is not "PHI is scrubbed before it is sent" — there is no sender to scrub.
//  4. Every `URLSession` call site in the app routes through `requireAllowed(_:)` first. A new
//     network dependency cannot be added without editing this file, which is the point: an
//     auditor reviewing "where can data go?" reads one type.
//
//  When SMART on FHIR lands, the authorization host joins this list. That connection *receives*
//  health data — it is the source of it — but it still never *sends* any: the request carries an
//  OAuth token and a resource query, and the response body is written straight into the encrypted
//  vault. The direction of travel is the thing to keep straight.
// ─────────────────────────────────────────────────────────────────────────────────────────────

/// The single auditable gate on network access.
enum EgressPolicy {
    /// A host the app is permitted to contact, and the justification for it.
    ///
    /// `receivesHealthData` is a documented property rather than an enforced one — no type system
    /// can prove a string is not PHI. It exists so the list reads as an argument, not an allowlist.
    struct AllowedHost: Hashable {
        let host: String
        /// Why this host is reachable at all.
        let purpose: String
        /// True if the host ever receives health data. Every entry in v1 is false, and the FHIR
        /// entry is false too: FHIR is a *source* of health data, never a destination for it.
        let receivesHealthData: Bool
        /// False for hosts that are declared but not yet reachable, so a placeholder cannot become
        /// a live network path by accident.
        let isEnabledInV1: Bool

        /// Copy suitable for the privacy screen.
        var userFacingDescription: String { "\(host) — \(purpose)" }
    }

    /// Hugging Face API/metadata host for the Gemma 4 E2B `.litertlm` file.
    static let huggingFace = AllowedHost(
        host: "huggingface.co",
        purpose: "Gemma model weights. Outbound only; requests a public model file and carry no health data.",
        receivesHealthData: false,
        isEnabledInV1: true
    )

    /// Hugging Face's large-file CDN, which `huggingface.co` redirects model downloads to.
    /// Listed explicitly because a redirect target is still egress.
    static let huggingFaceCDN = AllowedHost(
        host: "cdn-lfs.huggingface.co",
        purpose: "Gemma model weight blobs (redirect target of huggingface.co). Outbound only.",
        receivesHealthData: false,
        isEnabledInV1: true
    )

    /// Placeholder for the SMART on FHIR authorization and API host.
    ///
    /// Deliberately not a real hostname and deliberately disabled. Epic's endpoint is
    /// per-organization and is resolved from the user's chosen provider at authorization time, so
    /// the eventual implementation replaces this entry with a set derived from a signed endpoint
    /// directory — not with a wildcard.
    static let futureFHIRAuthorization = AllowedHost(
        host: "fhir.authorization.placeholder.invalid",
        purpose: "Reserved for patient-authorized SMART on FHIR. Inbound health data only; sends an OAuth token and a resource query, never health content.",
        receivesHealthData: false,
        isEnabledInV1: false
    )

    /// Everything the app may contact, including entries not yet enabled.
    static let declaredHosts: [AllowedHost] = [huggingFace, huggingFaceCDN, futureFHIRAuthorization]

    /// The hosts actually reachable today.
    static var activeHosts: [AllowedHost] { declaredHosts.filter(\.isEnabledInV1) }

    // MARK: - The gate

    /// The one question every network call site must ask.
    ///
    /// Requires HTTPS: an allowlisted host reached over cleartext is not an allowlisted host.
    /// Matches the host exactly rather than by suffix — suffix matching is how
    /// `huggingface.co.attacker.example` gets through.
    static func isAllowed(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), scheme == "https" else { return false }
        guard let host = url.host?.lowercased() else { return false }
        return activeHosts.contains { $0.host == host }
    }

    /// Throwing form, for call sites that should refuse to proceed.
    static func requireAllowed(_ url: URL) throws {
        guard isAllowed(url) else { throw EgressViolation.hostNotAllowed(host: url.host ?? "<none>") }
    }

    /// Human-readable refusal, for the diagnostics list in Settings.
    static func denialReason(for url: URL) -> String? {
        if isAllowed(url) { return nil }
        if url.scheme?.lowercased() != "https" {
            return "Blocked: \(url.scheme ?? "no scheme") is not HTTPS."
        }
        return "Blocked: \(url.host ?? "unknown host") is not on Remli's allowlist."
    }

    // MARK: - The PHI contract

    /// Query keys a Remli-constructed URL is permitted to carry.
    ///
    /// The list is short on purpose. Model downloads are addressed by path; if a URL Remli builds
    /// needs a query parameter that is not here, that is a design change worth someone reading.
    static let permittedQueryKeys: Set<String> = ["download", "revision"]

    /// Query-key prefixes allowed on URLs the app did not construct — chiefly the pre-signed S3
    /// parameters Hugging Face's CDN redirects to. Remli follows those URLs verbatim; it never
    /// composes them.
    static let permittedQueryKeyPrefixes: [String] = ["X-Amz-", "Expires", "Policy", "Signature", "response-content"]

    /// The contract every caller signs: *this URL contains no health data*.
    ///
    /// This cannot be proven — no function can look at a string and tell you whether it is a
    /// medication name. What it can do is enforce the shape that makes accidental leakage
    /// possible: an unexpected query parameter, a fragment, or userinfo in the authority is how
    /// data ends up somewhere it was never meant to be. In debug builds those trip an assertion at
    /// the call site rather than in a code review six weeks later.
    ///
    /// The real obligation stays with the caller, so call it explicitly and near the construction
    /// of the URL, where the claim is actually true or false:
    ///
    /// ```swift
    /// let url = modelWeightsURL(for: .gemma4E2B)
    /// EgressPolicy.assertNoPHI(url)          // contains a repo id and a filename, nothing else
    /// try EgressPolicy.requireAllowed(url)
    /// ```
    static func assertNoPHI(_ url: URL, file: StaticString = #fileID, line: UInt = #line) {
        #if DEBUG
        assert(isAllowed(url), "Egress to a non-allowlisted host: \(url.host ?? "<none>")", file: file, line: line)

        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        assert(components?.fragment == nil, "URL fragments are never needed and never inspected server-side; remove it.", file: file, line: line)
        assert(components?.user == nil && components?.password == nil, "Credentials in a URL are logged by every proxy in the path.", file: file, line: line)

        for item in components?.queryItems ?? [] {
            let permitted = permittedQueryKeys.contains(item.name)
                || permittedQueryKeyPrefixes.contains { item.name.hasPrefix($0) }
            assert(permitted, "Unexpected query parameter '\(item.name)' on an egress URL. If this is app-constructed, justify it in EgressPolicy.permittedQueryKeys.", file: file, line: line)
        }
        #endif
    }

    // MARK: - Status surface

    /// Backs the status strip's egress indicator. The design doc asks for privacy state to be
    /// visible and true, not a static reassuring label.
    static var statusStripDescription: String {
        "No health data leaves this phone"
    }

    /// Longer copy for the privacy screen: what the app can reach, and why.
    static var auditSummary: String {
        let lines = declaredHosts.map { host -> String in
            let state = host.isEnabledInV1 ? "allowed" : "reserved, not reachable in v1"
            return "• \(host.host) (\(state)) — \(host.purpose)"
        }
        return (["Remli may contact:"] + lines + [
            "",
            "No analytics, crash reporting, or remote logging is present in this app.",
        ]).joined(separator: "\n")
    }
}

/// Raised when a call site attempts egress the policy does not permit. Carries the host so the
/// failure is diagnosable, and nothing else — an error message is a place data leaks from too.
enum EgressViolation: Error, LocalizedError, Equatable {
    case hostNotAllowed(host: String)

    var errorDescription: String? {
        switch self {
        case .hostNotAllowed(let host):
            return "Remli does not connect to \(host)."
        }
    }
}
