#!/usr/bin/env python3
"""recount-citations.py -- the M1 gate fix's genuinely independent citation
recount (briefs/M2-gate-triage.md, "C. THE 'INDEPENDENT' CITATION RECOUNT
COPIES THE MODEL").

Before this script existed, check-site.sh's own three-way content-agreement
Python did not independently count citation DECLARATIONS at all: it
documented SXC1.Exercise.Report.buildTotals's own scoping rule (a quiz's
cite: line counts twice -- once as exCites, once via its prompt's prCites;
a drill's step cite: lines count once each; a lookup's find: line never
counts at all) and REPRODUCED that rule in Python. Agreement between the two
proved nothing: it was one implementation, checked twice, dressed up as an
independent second opinion -- exactly what the three-way agreement design
this project ships elsewhere exists to prevent.

Wave 1 of the M2 gate-fix round redefined the model's own `totals.citations`
(site/src/SXC1/Exercise/Report.hs's totCitations) to count DECLARATIONS --
one per cite:/find: line actually written in content/exercises/*.ex.md, with
no per-kind duplication or omission. Against that redefinition, a genuinely
independent recount is now possible with NO knowledge of the model's own
internal scoping (exCites/prCites/FindPage): every line in every
content/exercises/*.ex.md file that starts with "cite:" or "find:", counted
once, full stop. On the shipped corpus that is 27 + 5 = 32, which is exactly
what the redefined model now reports -- agreement that means something,
because the two sides do not share a single line of counting logic.

Deliberately NOT accompanied by a check-site.sh grep asserting this line
scan "is present" in this file (see this task's own brief): a presence grep
for text that legitimately also appears in a check LABEL (both "^cite:" and
"^find:" show up verbatim in this very docstring, and in check-site.sh's own
diagnostic strings) is exactly the can't-fail-check anti-pattern this whole
gate round exists to eliminate. The proof this script is genuine is
behavioural, not textual: run it against a doctored report (see --report
below) and it must fail. That is this script's own negative control.

Usage:
    recount-citations.py --report <exercise-check --json capture>
                          [--content-dir DIR]

  --report PATH        Path to a JSON file shaped like `exercise-check
                        --json`'s own output (must have a numeric
                        totals.citations field). Required.
  --content-dir DIR     Directory containing *.ex.md files to scan.
                        Defaults to <repo-root>/content/exercises, where
                        <repo-root> is resolved from THIS SCRIPT's own file
                        location (scripts/../), never from the current
                        working directory -- so this runs correctly no
                        matter where it is invoked from, exactly like
                        check-site.sh's own REPO_ROOT resolution.

Exit status: 0 and a one-line OK summary on stdout when the disk-derived
recount agrees with the report's totals.citations; non-zero and a readable
diff otherwise (missing/unreadable report, non-numeric totals.citations, or
a genuine disagreement).
"""

import argparse
import json
import os
import re
import sys

# Anchored to the start of the line, deliberately: only a genuine
# cite:/find: FIELD declaration counts, never an indented continuation or
# incidental substring. This is intentionally blind to which exercise, which
# prompt, or which role a line belongs to -- see the module docstring for
# why that blindness is the whole point.
CITE_LINE_RE = re.compile(r"^(?:cite|find):")


def repo_root_from_this_file():
    # scripts/recount-citations.py -> scripts/ -> repo root. Resolved from
    # __file__, never from os.getcwd(), so this script behaves identically
    # regardless of the caller's working directory (check-site.sh invokes
    # it via an absolute path; a human might invoke it from anywhere).
    scripts_dir = os.path.dirname(os.path.abspath(__file__))
    return os.path.dirname(scripts_dir)


def default_content_dir():
    return os.path.join(repo_root_from_this_file(), "content", "exercises")


def count_declarations(content_dir):
    """Returns (total, per_file) where per_file is a sorted list of
    (filename, count) pairs, restricted to *.ex.md files directly under
    content_dir (no recursion -- that is where this corpus's exercise decks
    live; see content/exercises/INDEX)."""
    if not os.path.isdir(content_dir):
        raise SystemExit(
            "recount-citations: content directory not found: %s" % content_dir
        )
    per_file = []
    total = 0
    for fname in sorted(os.listdir(content_dir)):
        if not fname.endswith(".ex.md"):
            continue
        path = os.path.join(content_dir, fname)
        with open(path, encoding="utf-8") as fh:
            n = sum(1 for line in fh if CITE_LINE_RE.match(line))
        per_file.append((fname, n))
        total += n
    return total, per_file


def load_report_citations(report_path):
    try:
        with open(report_path, encoding="utf-8") as fh:
            data = json.load(fh)
    except OSError as e:
        raise SystemExit("recount-citations: could not read --report %r: %s" % (report_path, e))
    except ValueError as e:
        raise SystemExit("recount-citations: --report %r is not valid JSON: %s" % (report_path, e))
    totals = data.get("totals")
    if not isinstance(totals, dict):
        raise SystemExit("recount-citations: --report %r has no \"totals\" object" % report_path)
    citations = totals.get("citations")
    if not isinstance(citations, int) or isinstance(citations, bool):
        raise SystemExit(
            "recount-citations: --report %r's totals.citations is not an integer (got %r)"
            % (report_path, citations)
        )
    return citations


def main(argv):
    parser = argparse.ArgumentParser(
        description="Genuinely independent ^cite:/^find: line-scan recount, "
        "diffed against exercise-check --json's totals.citations."
    )
    parser.add_argument(
        "--report",
        required=True,
        help="Path to an exercise-check --json capture.",
    )
    parser.add_argument(
        "--content-dir",
        default=None,
        help="Directory of *.ex.md files (default: <repo-root>/content/exercises, "
        "resolved from this script's own location).",
    )
    args = parser.parse_args(argv)

    content_dir = args.content_dir or default_content_dir()
    disk_total, per_file = count_declarations(content_dir)
    model_total = load_report_citations(args.report)

    if disk_total == model_total:
        print(
            "recount-citations: OK  %d citation declaration(s) (^cite:/^find: lines "
            "in %s) agree with the report's totals.citations"
            % (disk_total, content_dir)
        )
        return 0

    lines = [
        "recount-citations: MISMATCH",
        "  report (%s): totals.citations = %d" % (args.report, model_total),
        "  disk scan (%s): %d ^cite:/^find: line(s)" % (content_dir, disk_total),
        "  per-file counts:",
    ]
    for fname, n in per_file:
        lines.append("    %-40s %d" % (fname, n))
    lines.append(
        "  difference: %+d (disk - report)" % (disk_total - model_total)
    )
    print("\n".join(lines), file=sys.stderr)
    return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
