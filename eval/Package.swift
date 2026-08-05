// swift-tools-version: 5.9
import PackageDescription

// Nudgy's evaluation suite.
//
// This package deliberately does not vendor or copy a single line of app code. `Sources/NudgyCore`
// is a SYMLINK to `../ios/Nudgy/Core`, so the evals compile the exact sources the app ships. A
// drifted copy of SafetyGuard that passes its own tests is worse than no tests at all.
//
// Everything here builds and runs on macOS with `swift test` — no simulator, no device, no model
// weights. That is possible because Nudgy's clinical and safety core is Foundation-only by design
// (see the note at the top of HealthSourceConnector.swift), and it is what keeps these evals fast
// enough to run on every change.
let package = Package(
    name: "NudgyEval",
    platforms: [.macOS(.v13)],
    targets: [
        // The app's own Core, compiled as-is.
        //
        // Only genuinely platform-bound files are excluded: `Notifications` needs UserNotifications
        // and UIKit, `LanguageModelProvider` imports UIKit, and `Speech` uses AVAudioSession, which
        // is unavailable on macOS. Everything else — SafetyGuard, GroundedPromptBuilder, the
        // normalizer, the proposal engine, the adherence ledger — is Foundation-only and compiles
        // here untouched.
        //
        // If a new file under Core starts importing UIKit, this build breaks. That is intended: the
        // breakage is the signal that something left the portable core. Add it here only after
        // confirming it genuinely needs a device framework.
        .target(
            name: "NudgyCore",
            path: "Sources/NudgyCore",
            exclude: [
                "Notifications",
                "Speech",
                "Language/LanguageModelProvider.swift",
            ]
        ),

        // Fixture loading, corpus types, and report emission shared by every test target.
        .target(
            name: "EvalKit",
            dependencies: ["NudgyCore"],
            path: "Sources/EvalKit"
        ),

        // Family 1: does SafetyGuard reject what it must, and allow what it must?
        .testTarget(
            name: "GuardEvalTests",
            dependencies: ["EvalKit", "NudgyCore"],
            path: "Tests/GuardEvalTests"
        ),

        // Family 2: does the streaming tripwire stay in step with the full-text guard?
        .testTarget(
            name: "TripwireEvalTests",
            dependencies: ["EvalKit", "NudgyCore"],
            path: "Tests/TripwireEvalTests"
        ),

        // Grounding scope: can a prompt ever see a fact it was not supposed to?
        .testTarget(
            name: "GroundingScopeTests",
            dependencies: ["EvalKit", "NudgyCore"],
            path: "Tests/GroundingScopeTests"
        ),
    ]
)
