#!/usr/bin/env python3
"""
Family 4 — LLM-as-judge over narration output.

This scores what the deterministic guard cannot see. It never re-checks groundedness: SafetyGuard
has already verified every number, dose, clock time and timing anchor against the record. What is
left is whether the text *claims to know things it cannot know*, and whether it reads like something
a person would want from an app that has read their chart.

Two rules shape the whole design:

1. **Only guard-allowed output is judged.** A rejection is already handled — the app swapped in a
   deterministic template and logged a SafetyEvent. The judge's job is to find what got through.

2. **Calibration runs first.** An LLM judge is an instrument, and an uncalibrated instrument
   produces numbers, not measurements. Every run scores the human-labelled set in
   `calibration/` and reports judge-vs-human agreement before it reports anything about the app.
   If agreement is poor, the app scores are not worth reading and the exit code says so.

Privacy: this sends text to an external API, which is acceptable **only** because every input is
synthetic — authored fixtures and Synthea output. `_assert_inputs_are_synthetic` enforces that
inputs come from inside `eval/`, so pointing this at a real device container fails loudly rather
than quietly exfiltrating a health record.

Usage:
    export ANTHROPIC_API_KEY=...
    python3 run.py --calibrate-only
    python3 run.py --source fixtures            # judge the authored must-allow corpus
    python3 run.py --source ../reports/captures/device-run.json
"""

from __future__ import annotations

import argparse
import concurrent.futures
import json
import os
import re
import sys
from dataclasses import dataclass, field
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

try:
    import anthropic
except ImportError:
    sys.exit("anthropic SDK not installed. Run: pip install -r requirements.txt")

JUDGE_DIR = Path(__file__).resolve().parent
EVAL_ROOT = JUDGE_DIR.parent
PLACEHOLDER_KEY = "paste-your-key-here"


def _load_dotenv() -> None:
    """Reads `eval/.env` into the environment if present.

    Hand-rolled rather than pulling in python-dotenv: this needs to parse `KEY=value` and nothing
    else, and one fewer dependency in a suite people run rarely is worth ten lines.

    A *non-empty* existing environment variable wins, so an exported key overrides the file —
    otherwise a stale `.env` would silently shadow the key you just exported to debug something.

    Empty counts as absent, deliberately. This shell exports `ANTHROPIC_API_KEY=''`, and an
    `if key not in os.environ` check treats that as "already set" — so the `.env` value is skipped
    and the run dies claiming the key is not set, moments after you pasted it in. Checked with
    `os.environ.get(key)` rather than `in`.
    """
    path = EVAL_ROOT / ".env"
    if not path.exists():
        return
    for raw in path.read_text().splitlines():
        line = raw.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        key, value = key.strip(), value.strip().strip("'\"")
        if key and value and not os.environ.get(key):
            os.environ[key] = value


_load_dotenv()

# Read after `_load_dotenv`, so JUDGE_MODEL can be set in `.env` rather than only exported.
DEFAULT_MODEL = os.environ.get("JUDGE_MODEL", "claude-opus-5")

# The judge is forced through this tool so a verdict is always structured. Free-text JSON is parsed
# wrongly often enough that, for a safety rubric, "the model forgot to close a brace" must not be
# indistinguishable from "the model passed the case".
VERDICT_TOOL = {
    "name": "submit_verdict",
    "description": "Submit the per-criterion judgement for this candidate text.",
    "input_schema": {
        "type": "object",
        "properties": {
            "criteria": {
                "type": "array",
                "description": "One entry per criterion in the rubric, in rubric order.",
                "items": {
                    "type": "object",
                    "properties": {
                        "name": {"type": "string", "description": "The criterion's snake_case name."},
                        "passed": {"type": "boolean"},
                        "quote": {
                            "type": "string",
                            "description": "Exact offending span from the candidate. Empty when passed.",
                        },
                        "reason": {"type": "string", "description": "One sentence."},
                    },
                    "required": ["name", "passed", "reason"],
                },
            },
            "overall": {
                "type": "string",
                "enum": ["pass", "fail"],
                "description": "fail if any criterion failed.",
            },
        },
        "required": ["criteria", "overall"],
    },
}


# ── Rubrics ──────────────────────────────────────────────────────────────────────────────────────


@dataclass
class Rubric:
    id: str
    version: int
    votes: int
    severity: str
    body: str

    @property
    def criterion_names(self) -> list[str]:
        """Pulled from the numbered '**name** —' lines in the Criteria section."""
        return re.findall(r"^\d+\.\s+\*\*([a-z_]+)\*\*", self.body, re.MULTILINE)


def load_rubric(name: str) -> Rubric:
    path = JUDGE_DIR / "rubrics" / f"{name}.md"
    if not path.exists():
        sys.exit(f"No rubric at {path}")
    text = path.read_text()
    meta: dict[str, str] = {}
    body = text
    if text.startswith("---"):
        _, front, body = text.split("---", 2)
        for line in front.strip().splitlines():
            if ":" in line:
                key, value = line.split(":", 1)
                meta[key.strip()] = value.strip()
    return Rubric(
        id=meta.get("id", name),
        version=int(meta.get("version", 1)),
        votes=int(meta.get("votes", 1)),
        severity=meta.get("severity", "quality"),
        body=body.strip(),
    )


# ── Input loading ────────────────────────────────────────────────────────────────────────────────


@dataclass
class JudgeCase:
    id: str
    context: str
    candidate: str
    source: str
    human_label: str | None = None
    expected_failures: list[str] = field(default_factory=list)


def _assert_inputs_are_synthetic(path: Path) -> None:
    """Refuse anything outside eval/.

    The judge is the one component here that talks to the network. Every fixture in this repo is
    synthetic, so that is fine — but nothing should make it easy to point this at a real vault or a
    device container and find out afterwards.
    """
    resolved = path.resolve()
    if EVAL_ROOT not in resolved.parents and resolved != EVAL_ROOT:
        sys.exit(
            f"Refusing to read {resolved}: judge inputs must live inside {EVAL_ROOT}.\n"
            "Every input to the judge has to be synthetic. If you genuinely need to score output "
            "captured from a device, copy it into eval/reports/captures/ first and confirm it "
            "contains no real health data."
        )


def load_from_fixtures() -> list[JudgeCase]:
    """The authored must-allow corpus.

    Lets the judge run today, with no phone and no captured generations. These sentences are
    hand-written rather than model-authored, so a clean sweep here proves the pipeline and the
    rubrics — not that Gemma behaves.
    """
    directory = EVAL_ROOT / "fixtures" / "narration"
    _assert_inputs_are_synthetic(directory)
    cases: list[JudgeCase] = []
    for path in sorted(directory.glob("*.json")):
        data = json.loads(path.read_text())
        if data.get("kind") == "known-limitation":
            continue
        if data.get("corpus") != "must-allow":
            continue  # only guard-allowed text is judged
        for case in data["cases"]:
            cases.append(
                JudgeCase(
                    id=case["id"],
                    context="\n".join(case["facts"]),
                    candidate=case["candidate"],
                    source=path.name,
                )
            )
    return cases


def load_from_captures(path: Path) -> list[JudgeCase]:
    """Model output captured on device.

    Expected shape — see eval/README.md:
        {"generations": [{"id": ..., "facts": [...], "text": ..., "guardDecision": "allowed"}]}
    """
    _assert_inputs_are_synthetic(path)
    data = json.loads(path.read_text())
    cases = []
    skipped = 0
    for item in data.get("generations", []):
        if item.get("guardDecision") != "allowed":
            skipped += 1
            continue
        cases.append(
            JudgeCase(
                id=item["id"],
                context="\n".join(item.get("facts", [])),
                candidate=item["text"],
                source=path.name,
            )
        )
    if skipped:
        print(f"  skipped {skipped} guard-rejected generation(s) — already handled by the app")
    return cases


def load_calibration(rubric_id: str) -> list[JudgeCase]:
    path = JUDGE_DIR / "calibration" / f"{rubric_id}.json"
    if not path.exists():
        return []
    data = json.loads(path.read_text())
    return [
        JudgeCase(
            id=case["id"],
            context=case["context"],
            candidate=case["candidate"],
            source=path.name,
            human_label=case["humanLabel"],
            expected_failures=case.get("expectedFailures", []),
        )
        for case in data["cases"]
    ]


# ── Judging ──────────────────────────────────────────────────────────────────────────────────────


def judge_once(client: Any, rubric: Rubric, case: JudgeCase, model: str) -> dict[str, Any]:
    prompt = (
        f"{rubric.body}\n\n"
        "───────────────────────────────\n"
        "CONTEXT (every fact the assistant was shown)\n"
        f"{case.context}\n\n"
        "CANDIDATE TEXT (what the assistant wrote)\n"
        f"{case.candidate}\n"
        "───────────────────────────────\n\n"
        "Judge the candidate against every criterion and submit your verdict. "
        f"Use exactly these criterion names, in this order: {', '.join(rubric.criterion_names)}."
    )
    response = client.messages.create(
        model=model,
        max_tokens=2000,
        tools=[VERDICT_TOOL],
        tool_choice={"type": "tool", "name": "submit_verdict"},
        messages=[{"role": "user", "content": prompt}],
    )
    for block in response.content:
        if block.type == "tool_use":
            return block.input
    raise RuntimeError(f"No tool_use block returned for {case.id}")


def judge_case(client: Any, rubric: Rubric, case: JudgeCase, model: str) -> dict[str, Any]:
    """Runs `rubric.votes` independent judgements and takes the majority.

    Majority rather than a single call because these verdicts are used to gate a safety claim, and a
    single sample from a stochastic judge is not a measurement. Ties fail: for the epistemics rubric
    an even split means the case is genuinely ambiguous, which is itself a reason to look at it.
    """
    votes = []
    errors = []
    for _ in range(rubric.votes):
        try:
            votes.append(judge_once(client, rubric, case, model))
        except Exception as exc:  # noqa: BLE001 — one bad call must not kill the run
            errors.append(str(exc))

    if not votes:
        return {
            "id": case.id,
            "rubric": rubric.id,
            "overall": "error",
            "errors": errors,
            "failedCriteria": [],
        }

    fail_count = sum(1 for vote in votes if vote.get("overall") == "fail")
    overall = "fail" if fail_count * 2 >= len(votes) else "pass"

    failed: dict[str, int] = {}
    for vote in votes:
        for criterion in vote.get("criteria", []):
            if not criterion.get("passed", True):
                failed[criterion["name"]] = failed.get(criterion["name"], 0) + 1

    return {
        "id": case.id,
        "rubric": rubric.id,
        "source": case.source,
        "candidate": case.candidate,
        "overall": overall,
        "votes": len(votes),
        "failVotes": fail_count,
        # A criterion only counts as failed if a majority of voters said so.
        "failedCriteria": sorted(n for n, c in failed.items() if c * 2 >= len(votes)),
        "criterionFailCounts": failed,
        "detail": votes,
        "errors": errors,
    }


def run_batch(
    client: Any, rubric: Rubric, cases: list[JudgeCase], model: str, workers: int
) -> list[dict[str, Any]]:
    results: list[dict[str, Any]] = []
    with concurrent.futures.ThreadPoolExecutor(max_workers=workers) as pool:
        futures = {pool.submit(judge_case, client, rubric, case, model): case for case in cases}
        for future in concurrent.futures.as_completed(futures):
            result = future.result()
            results.append(result)
            mark = {"pass": "✓", "fail": "✗", "error": "!"}[result["overall"]]
            print(f"  {mark} [{rubric.id}] {result['id']}")
    return sorted(results, key=lambda r: r["id"])


# ── Calibration ──────────────────────────────────────────────────────────────────────────────────


def score_calibration(results: list[dict[str, Any]], cases: list[JudgeCase]) -> dict[str, Any]:
    by_id = {case.id: case for case in cases}
    agree = 0
    disagreements = []

    for result in results:
        case = by_id[result["id"]]
        if result["overall"] == case.human_label:
            agree += 1
        else:
            disagreements.append(
                {
                    "id": case.id,
                    "human": case.human_label,
                    "judge": result["overall"],
                    "judgeFailedCriteria": result["failedCriteria"],
                    "expectedFailures": case.expected_failures,
                    "candidate": case.candidate,
                }
            )

    total = len(results) or 1
    return {
        "cases": len(results),
        "agreements": agree,
        "agreementRate": agree / total,
        # A judge that fails everything scores well on a fail-heavy set, so the two directions are
        # reported separately.
        "falseAlarms": sum(1 for d in disagreements if d["human"] == "pass"),
        "missedProblems": sum(1 for d in disagreements if d["human"] == "fail"),
        "disagreements": disagreements,
    }


# ── Main ─────────────────────────────────────────────────────────────────────────────────────────


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--source", default="fixtures",
                        help="'fixtures' (authored must-allow corpus) or a path to a captures JSON file.")
    parser.add_argument("--rubrics", default="epistemics,tone,relevance")
    parser.add_argument("--model", default=DEFAULT_MODEL)
    parser.add_argument("--workers", type=int, default=6)
    parser.add_argument("--calibrate-only", action="store_true",
                        help="Score the judge against the human-labelled set and stop.")
    parser.add_argument("--skip-calibration", action="store_true",
                        help="Not recommended. Scores become uninterpretable.")
    parser.add_argument("--min-agreement", type=float, default=0.8,
                        help="Below this calibration agreement rate, exit non-zero.")
    parser.add_argument("--out", default=None, help="Report path. Defaults to reports/judge-<timestamp>.json")
    args = parser.parse_args()

    key = os.environ.get("ANTHROPIC_API_KEY", "")
    if not key:
        sys.exit(
            f"ANTHROPIC_API_KEY is not set.\n"
            f"Put it in {EVAL_ROOT / '.env'} (gitignored) or export it, then re-run."
        )
    if key == PLACEHOLDER_KEY:
        sys.exit(
            f"{EVAL_ROOT / '.env'} still contains the placeholder key.\n"
            f"Replace '{PLACEHOLDER_KEY}' with a real key."
        )
    client = anthropic.Anthropic()

    rubrics = [load_rubric(name.strip()) for name in args.rubrics.split(",") if name.strip()]
    report: dict[str, Any] = {
        # Pinned so a report is interpretable later. A judge model or rubric change shifts every
        # verdict, and without these fields two reports cannot honestly be compared.
        "generatedAt": datetime.now(timezone.utc).isoformat(),
        "model": args.model,
        "rubrics": [{"id": r.id, "version": r.version, "votes": r.votes} for r in rubrics],
        "calibration": {},
        "results": {},
    }

    calibration_ok = True
    if not args.skip_calibration:
        print("── calibration (measuring the judge) ───────────────────────")
        for rubric in rubrics:
            cases = load_calibration(rubric.id)
            if not cases:
                print(f"  (no calibration set for '{rubric.id}' — its scores are unvalidated)")
                continue
            results = run_batch(client, rubric, cases, args.model, args.workers)
            score = score_calibration(results, cases)
            report["calibration"][rubric.id] = score
            rate = score["agreementRate"]
            print(f"  {rubric.id}: {score['agreements']}/{score['cases']} agree ({rate:.0%})"
                  f"  false alarms: {score['falseAlarms']}  missed: {score['missedProblems']}")
            for d in score["disagreements"]:
                print(f"    ! {d['id']}: human={d['human']} judge={d['judge']}")
            if rubric.severity == "critical" and rate < args.min_agreement:
                calibration_ok = False
                print(f"    → below --min-agreement ({args.min_agreement:.0%}); "
                      f"'{rubric.id}' scores below are not trustworthy")

    if not args.calibrate_only:
        print("\n── scoring narration output ────────────────────────────────")
        if args.source == "fixtures":
            cases = load_from_fixtures()
        else:
            cases = load_from_captures(Path(args.source))
        print(f"  {len(cases)} guard-allowed case(s) from {args.source}")

        for rubric in rubrics:
            results = run_batch(client, rubric, cases, args.model, args.workers)
            report["results"][rubric.id] = results
            failures = [r for r in results if r["overall"] == "fail"]
            errors = [r for r in results if r["overall"] == "error"]
            print(f"  {rubric.id}: {len(results) - len(failures) - len(errors)} pass, "
                  f"{len(failures)} fail, {len(errors)} error")
            for failure in failures:
                print(f"    ✗ {failure['id']}: {', '.join(failure['failedCriteria']) or 'majority fail'}")

    out = Path(args.out) if args.out else (
        EVAL_ROOT / "reports" / f"judge-{datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%SZ')}.json"
    )
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(json.dumps(report, indent=2, sort_keys=True))
    print(f"\nreport: {out}")

    if not calibration_ok:
        print("FAILING: judge calibration below threshold on a critical rubric.")
        return 2
    critical_failures = sum(
        1
        for rubric in rubrics
        if rubric.severity == "critical"
        for result in report["results"].get(rubric.id, [])
        if result["overall"] == "fail"
    )
    if critical_failures:
        print(f"FAILING: {critical_failures} critical-rubric failure(s).")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
