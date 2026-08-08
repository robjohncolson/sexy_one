#!/usr/bin/env python3
"""emit-content-bundles.py -- build the per-language fetched content
bundles: the EXERCISE corpus (M6 W1, briefs/M6-plan.md ruling 1/2) and
the MANUAL text (M7 W1, briefs/M7-plan.md rulings 1/4/6).

Reads content/exercises/INDEX and every deck file it names, plus
translations/<slug>.md (and translations/<slug>.ja.md when it exists),
and emits

    <out-dir>/content.en.txt      the EN exercise bundle  (--out-dir)
    <out-dir>/content.ja.txt      the JA exercise bundle  (--out-dir)
    <out-dir>/manuals.en.txt      the EN manual bundle    (--out-dir)
    <out-dir>/manuals.ja.txt      the JA manual bundle    (--out-dir)
    site/app/Bundle/Manifest.hs   the BUILD-TIME EXPECTATION (--manifest-hs)

ONE EMITTER, ONE GRAMMAR, ONE MANIFEST (M7 W1). The manual text is
externalized under exactly the discipline M6's gate forced on the
course, and deliberately NOT as a second mechanism: both kinds share the
framing below, the reserved-prefix rule, the FNV-1a/32 fingerprint and
the wasm-embedded expectation, and the expectation is ONE generated
Haskell module regenerated atomically from both corpora (two scripts
each writing half of one generated file could not be kept consistent).

THE MANIFEST (M6 gate round 1, finding M6-R1-1b). The app must be able to
reject a wrong/stale/truncated/deck-shuffled bundle that is nevertheless
syntactically framed, and it cannot do that from the bundle alone: a
bundle carrying its own manifest+fingerprint attests only to its own
internal consistency, so a COMPLETE OLDER BUILD (or any self-consistent
forgery) would pass. The expectation therefore lives in the OTHER
artifact -- it is generated HERE, before the wasm is compiled, and
compiled INTO app.wasm as site/app/Bundle/Manifest.hs, so accepting a
bundle requires agreement between two separately served files that only
the build that produced BOTH can satisfy. It carries only names, counts
and hashes (never the corpus text): the INDEX-ordered deck file names,
the aggregate (decks, exercises, prompts) counts, the ordered manual doc
slugs with their per-doc page counts, and one FNV-1a/32 fingerprint per
language over each WHOLE emitted bundle.

THE BUNDLE FORMAT -- ONE grammar, two record kinds (consumed by
site/app/Bundle.hs's parseBundle -- keep the two in sync):

    !SXC1-BUNDLE v1 <lang> <record-count>
    !SXC1-<KIND> <fields...>
    <that record's emitted text>
    !SXC1-<KIND> <fields...>
    ...

    exercise bundle   !SXC1-DECK <file name, the bare INDEX entry>
    manual bundle     !SXC1-DOC <slug> <the language THIS doc carries> <page count>

Decks appear in INDEX order; documents appear in MANUAL_SLUGS order.
"!SXC1-" at column 0 is the reserved delimiter prefix: no source line
may start with it (enforced below), so splitting a bundle back into its
records is unambiguous whichever kind it is.

THE MANUAL BUNDLE'S PER-DOC LANGUAGE FIELD (M7 ruling 4, the VISIBLE
fallback). translations/<slug>.ja.md is authored in W2, one document at
a time, so until every one exists the JA bundle necessarily carries EN
text for some documents. That fallback is RECORDED, never silent: each
!SXC1-DOC line names the language its own body is actually written in,
so a doc whose language differs from the bundle header's language is a
fallback and the app renders the localized "Japanese text not available
for this document yet" note instead of passing English off as Japanese.
The field needs no separate manifest entry -- the whole-bundle
fingerprint already pins every byte of these lines -- and W2 flips a
document simply by adding its .ja.md file: this emitter picks it up
automatically and the note disappears for that document alone.

THE ja: VARIANT GRAMMAR (the emission half; the reading half lives in
SXC1.Exercise.Reader.isJaLine/jaPayloadOf and is documented in
content/EXERCISE-FORMAT.md sec. 12):

  * A column-0 line beginning "ja:" is a VARIANT LINE. Its payload is
    the rest of the line with at most ONE leading space dropped, and the
    payload is a FULL REPLACEMENT LINE (it repeats the "## ", "- [x] ",
    "summary: ", "check: " marker of the line it replaces).
  * EN emission: delete every variant line, byte-identical otherwise.
  * JA emission: each maximal run of consecutive variant lines REPLACES
    the segment of EN lines directly above it:
      - anchor = the line immediately above the run (must exist, must
        not be blank);
      - anchor is a structural heading (#/##/### + space at column 0):
        segment = that one line; the payload must be exactly one line, a
        heading of the SAME level;
      - anchor is a task-list option line ("- [ ] "/"- [x] " at column
        0): segment = that one line; the payload must be exactly one
        option line with the SAME checked state;
      - anchor belongs to a field block (the maximal run of field lines
        + their >=2-space continuation lines after a structural heading,
        exactly SXC1.Exercise.Reader.scanFieldBlock's rule): segment =
        the owning field line plus its continuation lines; the payload
        must be exactly one field line with the SAME key, and only the
        learner-visible field keys {summary, check} may carry variants
        (cite:/find:/verify:/type:/id:/deck:/chapter:/tier:/tags:/
        requires:/limit: are language-invariant -- ruling 2);
      - otherwise (body prose): segment = the maximal run of contiguous
        non-blank, non-variant, non-heading, non-option lines outside
        any field block ending at the anchor (one Markdown block:
        paragraph, table, list run); the payload is one or more
        non-blank lines, none of which may be a structural heading or a
        variant line.
    A deck (or field) with no variant lines falls back to its EN text --
    "ja bundle empty-falls-back-to-EN per field until wave 3 fills it".

Every violation is a loud, file:line-named build failure -- never a
silently skipped line.

Per-file preconditions (all hold for the whole committed corpus and for
every translations/*.md): UTF-8, no CR, ends with exactly one trailing
newline run boundary (a final "\\n"), no line starting with "!SXC1-".
"""

import argparse
import gzip
import os
import re
import sys

DELIM_PREFIX = "!SXC1-"
HEADING_RE = re.compile(r"^(#{1,3}) \S")          # structural headings only (col 0, levels 1-3)
OPTION_RE = re.compile(r"^- \[( |x|X)\] \S")      # col-0 GFM task-list option
FIELD_RE = re.compile(r"^([a-z][a-z0-9-]*):")     # SXC1.Exercise.Reader.fieldKeyValueOf's key shape
ALLOWED_FIELD_KEYS = {"summary", "check"}          # the only field VALUES that are learner-visible

FNV_OFFSET = 2166136261
FNV_PRIME = 16777619
MASK32 = 0xFFFFFFFF


def fail(msg):
    print("emit-content-bundles: ERROR: %s" % msg, file=sys.stderr)
    sys.exit(1)


def fnv1a32(data):
    """FNV-1a/32 over BYTES -- the same function Exercises.Corpus.fnv1a32
    computes over a Text's UTF-8 encoding (pinned test vectors below)."""
    h = FNV_OFFSET
    for b in data:
        h ^= b
        h = (h * FNV_PRIME) & MASK32
    return h


# Pinned against the published vectors (briefs/M2-plan-amendments.md sec. 4)
# BEFORE any fingerprint this script emits is trusted -- the last vector
# proves this hashes UTF-8 BYTES, not code points.
FNV_VECTORS = [
    (b"", 2166136261),
    (b"hello", 1335831723),
    (b"SELECT BANK 1", 1835518890),
    ("⊕⊖".encode("utf-8"), 3369799694),
]


def check_fnv_vectors():
    for data, want in FNV_VECTORS:
        got = fnv1a32(data)
        if got != want:
            fail("FNV-1a/32 self-check failed: fnv1a32(%r) = %d, want %d" % (data, got, want))


# ---------------------------------------------------------------------------
# THE READER'S OWN CLASSIFICATION RULES, mirrored line for line (M6 gate
# round 1, finding M6-R1-2). The three shapes below are what
# SXC1.Exercise.Reader treats STRUCTURALLY after substitution; a ja:
# payload that lands in the PROSE branch must be none of them, or the JA
# deck can differ structurally from the EN deck (a prose line becoming an
# option changes a quiz's choice list; a prose line becoming "id:" or
# "verify:" changes a field block) while every presence-only check stays
# green. Each function names the Reader function it mirrors so the two
# cannot drift silently:
#
#   reader_heading_of     <- SXC1.Content.Markdown.headingLineOf
#                            (^#{1,6} then ' ' then non-blank -- levels
#                            1-6, NOT the 1-3 of HEADING_RE above, which
#                            is deliberately narrower because it names
#                            the STRUCTURAL SPLIT levels for anchor
#                            classification and field-block starts)
#   reader_task_item_of   <- SXC1.Exercise.Reader.taskListItemOf
#                            (bulletItemOf at indent 0 -- bullet is one
#                            of -*+, one space, then stripStart -- plus
#                            checkboxOf's [ ]/[x]/[X] + space + non-blank
#                            label; far wider than OPTION_RE above)
#   reader_field_key_of   <- SXC1.Exercise.Reader.fieldKeyValueOf
#                            (first char [a-z], key up to the first ':'
#                            all [a-z0-9-])
# ---------------------------------------------------------------------------


def reader_heading_of(line):
    i = 0
    while i < len(line) and line[i] == "#":
        i += 1
    if i < 1 or i > 6:
        return None
    rest = line[i:]
    if not rest.startswith(" "):
        return None
    txt = rest.strip()
    if not txt:
        return None
    return i, txt


def reader_task_item_of(line):
    # bulletItemOf: indent must be 0 (column-0 only), bullet in "-*+",
    # then exactly one space, then T.stripStart.
    if line[:1] not in ("-", "*", "+"):
        return None
    rest = line[1:]
    if not rest.startswith(" "):
        return None
    rest = rest[1:].lstrip()
    # checkboxOf
    if not rest.startswith("["):
        return None
    rest = rest[1:]
    if not rest[:1]:
        return None
    c, rest = rest[0], rest[1:]
    if c == " ":
        checked = False
    elif c in ("x", "X"):
        checked = True
    else:
        return None
    if not rest.startswith("]"):
        return None
    rest = rest[1:]
    if not rest.startswith(" "):
        return None
    if not rest[1:].strip():
        return None
    return checked


def reader_field_key_of(line):
    if not line[:1].islower() or not ("a" <= line[0] <= "z"):
        return None
    idx = line.find(":")
    if idx < 0:
        return None
    key = line[:idx]
    for ch in key:
        if not (("a" <= ch <= "z") or ("0" <= ch <= "9") or ch == "-"):
            return None
    return key


def structural_shape_of(line):
    """The Reader-visible STRUCTURAL shape of one line, or None when the
    line is ordinary prose. Used to reject structural tokens in a prose
    ja: payload."""
    h = reader_heading_of(line)
    if h is not None:
        return "a level-%d structural heading (SXC1.Content.Markdown.headingLineOf)" % h[0]
    if reader_task_item_of(line) is not None:
        return "a task-list option line (SXC1.Exercise.Reader.taskListItemOf)"
    key = reader_field_key_of(line)
    if key is not None:
        return "a %r field line (SXC1.Exercise.Reader.fieldKeyValueOf)" % key
    return None


def is_variant(line):
    return line.startswith("ja:")


def variant_payload(line):
    rest = line[3:]
    if rest.startswith(" "):
        rest = rest[1:]
    return rest


def is_blank(line):
    return line.strip() == ""


def is_continuation(line):
    return not is_blank(line) and (len(line) - len(line.lstrip(" "))) >= 2


def field_block_map(lines):
    """For each line index, the index of the FIELD LINE owning it inside a
    field block (itself for a field line, the field line for its
    continuations), or None when the line is not in a field block.
    Mirrors SXC1.Exercise.Reader.scanFieldBlock: a block starts after a
    structural heading (blank lines allowed BEFORE it, never inside);
    variant lines inside a block are treated as members of the block
    (they are field-shaped) but own nothing."""
    owner = [None] * len(lines)
    i = 0
    n = len(lines)
    while i < n:
        if HEADING_RE.match(lines[i]):
            # Blank lines are allowed BEFORE the block, never inside it
            # (scanFieldBlock's rule). Variant lines are transparent
            # everywhere here, because the Reader strips them from the
            # stream before ITS scan ever runs.
            j = i + 1
            while j < n and (is_blank(lines[j]) or is_variant(lines[j])):
                j += 1
            current_field = None
            while j < n:
                l = lines[j]
                if is_blank(l):
                    break
                if is_variant(l):
                    owner[j] = None      # a variant line is not a field
                    j += 1
                    continue
                if FIELD_RE.match(l):
                    current_field = j
                    owner[j] = j
                    j += 1
                    continue
                if is_continuation(l) and current_field is not None:
                    owner[j] = current_field
                    j += 1
                    continue
                break
            i = j
        else:
            i += 1
    return owner


def emit_deck(name, text):
    """Returns (en_lines, ja_lines) for one deck file's text."""
    if "\r" in text:
        fail("%s contains a CR byte -- the corpus is LF-only" % name)
    if not text.endswith("\n"):
        fail("%s does not end with a newline -- required for byte-exact bundle round-tripping" % name)
    lines = text.split("\n")[:-1]
    for idx, l in enumerate(lines):
        if l.startswith(DELIM_PREFIX):
            fail("%s:%d starts with the reserved bundle delimiter prefix %r" % (name, idx + 1, DELIM_PREFIX))

    en_lines = [l for l in lines if not is_variant(l)]

    owner = field_block_map(lines)

    # Collect maximal variant runs.
    runs = []
    i = 0
    n = len(lines)
    while i < n:
        if is_variant(lines[i]):
            j = i
            while j + 1 < n and is_variant(lines[j + 1]):
                j += 1
            runs.append((i, j))
            i = j + 1
        else:
            i += 1

    delete = set()          # line indices replaced (segments + the runs themselves)
    insert_at = {}          # segment-start index -> payload lines

    for (s, e) in runs:
        where = "%s:%d" % (name, s + 1)
        payloads = [variant_payload(lines[k]) for k in range(s, e + 1)]
        for p in payloads:
            if is_variant(p):
                fail("%s: a ja: payload may not itself be a ja: line" % where)
            if p.startswith(DELIM_PREFIX):
                fail("%s: a ja: payload may not start with %r" % (where, DELIM_PREFIX))
            if is_blank(p):
                fail("%s: a ja: payload may not be blank" % where)
        if s == 0:
            fail("%s: a ja: run has no line above it to translate" % where)
        anchor = s - 1
        if is_blank(lines[anchor]):
            fail("%s: a ja: run must directly follow the line(s) it translates (found a blank line above it)" % where)

        m_head = HEADING_RE.match(lines[anchor])
        m_opt = OPTION_RE.match(lines[anchor])
        if m_head:
            if len(payloads) != 1:
                fail("%s: a heading takes exactly one ja: line (got %d)" % (where, len(payloads)))
            m_p = HEADING_RE.match(payloads[0])
            if not m_p or m_p.group(1) != m_head.group(1):
                fail("%s: the ja: payload for a level-%d heading must be a level-%d heading"
                     % (where, len(m_head.group(1)), len(m_head.group(1))))
            seg = [anchor]
        elif m_opt:
            if len(payloads) != 1:
                fail("%s: an option line takes exactly one ja: line (got %d)" % (where, len(payloads)))
            m_p = OPTION_RE.match(payloads[0])
            if not m_p or m_p.group(1).lower() != m_opt.group(1).lower():
                fail("%s: the ja: payload for an option must be an option line with the same checked state" % where)
            seg = [anchor]
        elif owner[anchor] is not None:
            f = owner[anchor]
            m_f = FIELD_RE.match(lines[f])
            key = m_f.group(1)
            if key not in ALLOWED_FIELD_KEYS:
                fail("%s: field %r is language-invariant and may not carry a ja: variant (allowed: %s)"
                     % (where, key, ", ".join(sorted(ALLOWED_FIELD_KEYS))))
            if len(payloads) != 1:
                fail("%s: a field takes exactly one ja: line (got %d)" % (where, len(payloads)))
            m_p = FIELD_RE.match(payloads[0])
            if not m_p or m_p.group(1) != key:
                fail("%s: the ja: payload for field %r must be a %r field line itself" % (where, key, key))
            if e + 1 < n and is_continuation(lines[e + 1]) and owner[e + 1] is not None:
                fail("%s: a ja: variant must follow the field's LAST continuation line" % where)
            seg = list(range(f, anchor + 1))
        else:
            # M6 gate round 1 (finding M6-R1-2): the prose branch used to
            # reject only structural HEADINGS, so a prose payload
            # carrying "- [x] ...", "- [ ] ..." or field-shaped text
            # ("id:", "verify:") was reclassified STRUCTURALLY by the
            # Reader after substitution -- the JA deck could differ
            # structurally from the EN deck while every presence-only
            # check stayed green. Every structural token the Reader
            # recognises is now rejected here, enumerated from the
            # Reader's own rules (see structural_shape_of).
            for p in payloads:
                shape = structural_shape_of(p)
                if shape is not None:
                    fail("%s: a prose ja: payload may not be %s (it would change the JA deck's STRUCTURE, "
                         "not just its text): %r" % (where, shape, p[:80]))
            a = anchor
            while (a - 1 >= 0
                   and not is_blank(lines[a - 1])
                   and not is_variant(lines[a - 1])
                   and not HEADING_RE.match(lines[a - 1])
                   and not OPTION_RE.match(lines[a - 1])
                   and owner[a - 1] is None):
                a -= 1
            seg = list(range(a, anchor + 1))

        for k in seg:
            if k in delete:
                fail("%s: overlapping ja: replacement segments" % where)
            delete.add(k)
        for k in range(s, e + 1):
            delete.add(k)
        insert_at[seg[0]] = payloads

    ja_lines = []
    for idx, l in enumerate(lines):
        if idx in insert_at:
            ja_lines.extend(insert_at[idx])
        if idx in delete:
            continue
        ja_lines.append(l)

    return en_lines, ja_lines


def count_structure(name, lines):
    """(exercises, prompts) for ONE emitted deck, counted the way
    SXC1.Exercise.Reader splits it: one exercise per level-2 heading
    (splitAtLevel 2), and one prompt per exercise EXCEPT a drill, whose
    prompts are its "### Step" role headings. Emission-invariant by
    construction now that a ja: payload can never carry a structural
    token (see structural_shape_of), which is exactly what makes the
    EN/JA equality asserted in build_bundles meaningful."""
    ex_idx = [i for i, l in enumerate(lines) if (reader_heading_of(l) or (0,))[0] == 2]
    prompts = 0
    for k, start in enumerate(ex_idx):
        end = ex_idx[k + 1] if k + 1 < len(ex_idx) else len(lines)
        span = lines[start:end]
        kind = None
        for l in span:
            if reader_field_key_of(l) == "type":
                kind = l.split(":", 1)[1].strip()
                break
        if kind == "drill":
            steps = 0
            for l in span:
                h = reader_heading_of(l)
                if h is not None and h[0] == 3 and h[1] == "Step":
                    steps += 1
            if steps == 0:
                fail("%s: a drill exercise declares no '### Step' role heading" % name)
            prompts += steps
        else:
            prompts += 1
    return len(ex_idx), prompts


def build_bundles(exercises_dir, names):
    """Emit both bundles IN MEMORY and derive the manifest from them.
    Returns (bundles, counts) where bundles maps lang -> the exact bytes
    that get written, and counts is the (decks, exercises, prompts)
    triple both languages agree on."""
    per_lang = {"en": [], "ja": []}
    counts = {}
    for name in names:
        path = os.path.join(exercises_dir, name)
        if not os.path.isfile(path):
            fail("INDEX names %s but %s does not exist" % (name, path))
        text = open(path, encoding="utf-8").read()
        en_lines, ja_lines = emit_deck(name, text)
        per_lang["en"].append((name, en_lines))
        per_lang["ja"].append((name, ja_lines))
        for lang, dlines in (("en", en_lines), ("ja", ja_lines)):
            counts.setdefault(lang, [0, 0])
            ex, pr = count_structure("%s (%s)" % (name, lang), dlines)
            counts[lang][0] += ex
            counts[lang][1] += pr
    # M6 gate round 1 (finding M6-R1-2), emitter half: the two emissions
    # must agree on aggregate STRUCTURE. The full ordered structural
    # comparison (deck ids, exercise ids/kinds, option counts and which
    # option is correct) is exercise-check --bundle-structural-diff,
    # which parses both emitted bundles with the real Reader; this is the
    # cheap always-on guard at the point of emission.
    if counts["en"] != counts["ja"]:
        fail("the EN and JA emissions disagree structurally: en=(exercises=%d, prompts=%d) "
             "ja=(exercises=%d, prompts=%d)" % (counts["en"][0], counts["en"][1],
                                                counts["ja"][0], counts["ja"][1]))
    bundles = {}
    for lang in ("en", "ja"):
        out_lines = ["!SXC1-BUNDLE v1 %s %d" % (lang, len(names))]
        for name, dlines in per_lang[lang]:
            out_lines.append("!SXC1-DECK %s" % name)
            out_lines.extend(dlines)
        bundles[lang] = ("\n".join(out_lines) + "\n").encode("utf-8")
    return bundles, (len(names), counts["en"][0], counts["en"][1])


# ---------------------------------------------------------------------------
# THE MANUAL HALF (M7 W1, briefs/M7-plan.md rulings 1/2/4).
#
# The four manual documents live one file per document in translations/,
# with an optional parallel <slug>.ja.md carrying the Japanese TEXT for
# the same pages. This half emits them into the same bundle grammar the
# decks use (see the module docstring) with a !SXC1-DOC record per
# document.
#
# ORDER vs SET. MANUAL_SLUGS below fixes the ORDER -- it is the reader's
# own presentation order (home cards, #sxc1-content-stats), which is a
# product decision and not derivable from a directory listing. The SET
# is still enumerated FROM THE FILESYSTEM and required to match exactly
# (check_manual_inventory), so a document added to or removed from
# translations/ is a loud build failure here instead of a silently
# half-shipped reader. Anything that is not a manual -- the glossary
# (a checker-only lexicon, never a reader route) and the *.qa-notes.md
# review files -- is named explicitly rather than skipped by accident.
# ---------------------------------------------------------------------------

MANUAL_SLUGS = ["guide-book", "startup-guide", "midi", "oss"]
MANUAL_NON_DOC_SLUGS = {"glossary"}
MANUAL_JA_SUFFIX = ".ja.md"
MANUAL_QA_SUFFIX = ".qa-notes.md"

PAGE_MARKER_RE = re.compile(r"^<!-- page (\d+) -->$")


def page_marker_num(line):
    """The page number a line declares, or None. Mirrors
    SXC1.Content.Markdown.pageMarkerNum: the line is STRIPPED, must be
    exactly "<!-- page N -->" with N a run of digits, and nothing may
    follow the "-->"."""
    m = PAGE_MARKER_RE.match(line.strip())
    return int(m.group(1)) if m else None


def page_numbers_of(name, text):
    """The document's page-marker numbers in file order, validated to be
    exactly 1..N. mkDoc itself tolerates any ascending numbering, but the
    manifest records ONE page count per document and the reader indexes
    pages positionally (docPages !! (n - 1)), so 1..N is the invariant
    the app actually depends on -- and it holds for every committed
    translation. A document with no page markers has no pages to read
    and is rejected outright."""
    nums = [n for n in (page_marker_num(l) for l in text.split("\n")) if n is not None]
    if not nums:
        fail("%s carries no '<!-- page N -->' markers -- it has no readable pages" % name)
    want = list(range(1, len(nums) + 1))
    if nums != want:
        fail("%s's page markers are not exactly 1..%d in order (got %s%s)"
             % (name, len(nums), nums[:8], " ..." if len(nums) > 8 else ""))
    return nums


def read_doc_file(path, name):
    """One document's text plus the per-file preconditions every bundle
    record must satisfy -- the same three the deck emitter enforces, so
    T.lines/T.unlines round-trips each record byte-identically on the
    Haskell side and no body line can be mistaken for a delimiter."""
    text = open(path, encoding="utf-8").read()
    if "\r" in text:
        fail("%s contains a CR byte -- the corpus is LF-only" % name)
    if not text.endswith("\n"):
        fail("%s does not end with a newline -- required for byte-exact bundle round-tripping" % name)
    for idx, l in enumerate(text.split("\n")[:-1]):
        if l.startswith(DELIM_PREFIX):
            fail("%s:%d starts with the reserved bundle delimiter prefix %r" % (name, idx + 1, DELIM_PREFIX))
    return text


def check_manual_inventory(translations_dir):
    """The SET half of the order/set split described above: every
    <slug>.md in translations/ that is not explicitly a non-document must
    be a MANUAL_SLUGS entry, and every MANUAL_SLUGS entry must exist."""
    try:
        entries = sorted(os.listdir(translations_dir))
    except OSError as e:
        fail("cannot list %s: %s" % (translations_dir, e))
    found = set()
    for e in entries:
        if not e.endswith(".md") or e.endswith(MANUAL_QA_SUFFIX) or e.endswith(MANUAL_JA_SUFFIX):
            continue
        slug = e[: -len(".md")]
        if slug in MANUAL_NON_DOC_SLUGS:
            continue
        found.add(slug)
    want = set(MANUAL_SLUGS)
    if found != want:
        fail("translations/ holds documents %s but this emitter's fixed reading order names %s "
             "(extra: %s; missing: %s) -- add or remove the slug in MANUAL_SLUGS, and in the "
             "reader's own order, deliberately"
             % (sorted(found), MANUAL_SLUGS, sorted(found - want), sorted(want - found)))


def build_manual_bundles(translations_dir):
    """Emit both manual bundles IN MEMORY. Returns (bundles, docs) where
    bundles maps lang -> the exact bytes written and docs is the ordered
    [(slug, page count)] pair list the manifest records.

    The EN bundle carries every document's EN text verbatim. The JA
    bundle carries translations/<slug>.ja.md when that file exists and
    the EN text otherwise -- the DOCUMENTED, TEMPORARY per-document
    fallback W2 retires one file at a time. Each !SXC1-DOC line names
    the language its own body is in, so the fallback is visible to the
    app (ruling 4) rather than passed off as Japanese.

    A .ja.md file must be PAGE-FOR-PAGE with its EN sibling (ruling 2):
    the same number of page markers, so both languages agree with the
    single per-doc page count in the manifest and the reader's
    positional page index means the same thing in either language. A
    divergence is a loud failure here, not a page that silently renders
    the wrong text."""
    check_manual_inventory(translations_dir)
    docs = []
    per_lang = {"en": [], "ja": []}
    for slug in MANUAL_SLUGS:
        en_path = os.path.join(translations_dir, slug + ".md")
        if not os.path.isfile(en_path):
            fail("manual document %s is missing (%s)" % (slug, en_path))
        en_text = read_doc_file(en_path, slug + ".md")
        en_pages = page_numbers_of(slug + ".md", en_text)
        ja_path = os.path.join(translations_dir, slug + MANUAL_JA_SUFFIX)
        if os.path.isfile(ja_path):
            ja_text = read_doc_file(ja_path, slug + MANUAL_JA_SUFFIX)
            ja_pages = page_numbers_of(slug + MANUAL_JA_SUFFIX, ja_text)
            if len(ja_pages) != len(en_pages):
                fail("%s%s has %d page(s) but %s.md has %d -- the Japanese document must be "
                     "PAGE-FOR-PAGE with the English one (briefs/M7-plan.md ruling 2)"
                     % (slug, MANUAL_JA_SUFFIX, len(ja_pages), slug, len(en_pages)))
            ja_entry = ("ja", ja_text)
        else:
            ja_entry = ("en", en_text)
        docs.append((slug, len(en_pages)))
        per_lang["en"].append((slug, "en", en_text))
        per_lang["ja"].append((slug, ja_entry[0], ja_entry[1]))

    bundles = {}
    for lang in ("en", "ja"):
        out_lines = ["!SXC1-BUNDLE v1 %s %d" % (lang, len(MANUAL_SLUGS))]
        for (slug, doc_lang, text), (_, pages) in zip(per_lang[lang], docs):
            out_lines.append("!SXC1-DOC %s %s %d" % (slug, doc_lang, pages))
            out_lines.extend(text.split("\n")[:-1])
        bundles[lang] = ("\n".join(out_lines) + "\n").encode("utf-8")
    return bundles, docs


MANIFEST_HEADER = '''{-# LANGUAGE OverloadedStrings #-}

-- | GENERATED FILE -- do not edit by hand. Regenerated by
-- @scripts\\/emit-content-bundles.py --manifest-hs@, which
-- @scripts\\/build-site.sh@ runs BEFORE the wasm build (step 3a);
-- @scripts\\/check-site.sh@ fails if a fresh regeneration is not
-- byte-identical to this file.
--
-- THE BUILD-TIME EXPECTATION the running app checks every fetched
-- bundle against -- BOTH kinds (M6 gate round 1, finding M6-R1-1; M7
-- W1, briefs\\/M7-plan.md ruling 1). The expectation deliberately lives
-- HERE -- compiled into app.wasm -- and NOT in the bundle: a bundle
-- that carries its own manifest and fingerprint proves only that it is
-- internally consistent, so a complete OLDER build, or any
-- self-consistent forgery served at the right URL, would satisfy it.
-- Checking the fetched bytes against a constant baked into a DIFFERENT
-- artifact means acceptance requires agreement between two separately
-- served files, which only the build that produced both can supply.
--
-- ONE module, not two: the exercise corpus and the manual text ship in
-- the same bundle grammar under the same acceptance rules, and their
-- expectations are regenerated together by one emitter run, so keeping
-- them in one generated file is what makes \\"the manifest describes THIS
-- build\\" checkable in a single byte-comparison (check-site's M6-g).
--
-- It carries names, counts and hashes ONLY -- never corpus or manual
-- text -- so re-embedding it costs the wasm a fraction of a percent of
-- what the retired \\"Exercises.Embed\\" corpus and the retired
-- TH-embedded translations cost (see each milestone's report for the
-- measured deltas).
module Bundle.Manifest
  ( manifestDecks
  , manifestDeckCount
  , manifestExercises
  , manifestPrompts
  , manifestFingerprint
    -- * M7 W1: the manual half
  , manifestManualDocs
  , manifestManualDocCount
  , manifestManualFingerprint
  ) where

import           Data.Text (Text)
import           Data.Word (Word32)

-- | Every deck file name INDEX names, in INDEX order -- the exact
-- @!SXC1-DECK@ sequence a healthy bundle must carry.
manifestDecks :: [FilePath]
manifestDecks =
'''


MANIFEST_MANUAL_HEADER = '''
-- | Every manual document slug, in the reader's fixed presentation
-- order, paired with its page count (the number of
-- @\\<!-- page N --\\>@ markers, which are exactly 1..N) -- the precise
-- @!SXC1-DOC@ sequence a healthy manual bundle must carry. The per-doc
-- LANGUAGE each @!SXC1-DOC@ line also names is deliberately NOT pinned
-- here: it changes as wave 2 lands one document at a time, and the
-- whole-bundle fingerprint below already pins every byte of those
-- lines.
manifestManualDocs :: [(Text, Int)]
manifestManualDocs =
'''


def manifest_hs(names, totals, bundles, manual_docs, manual_bundles):
    decks, exercises, prompts = totals
    out = [MANIFEST_HEADER]
    for i, name in enumerate(names):
        out.append("  %s %s\n" % ("[" if i == 0 else ",", hs_string(name)))
    out.append("  ]\n")
    out.append('''
manifestDeckCount :: Int
manifestDeckCount = %d

-- | Aggregate corpus counts, derived at build time from the SAME
-- emission the bundles are written from and identical for both
-- languages (the emitter refuses to emit when they disagree).
manifestExercises :: Int
manifestExercises = %d

manifestPrompts :: Int
manifestPrompts = %d

-- | FNV-1a\\/32 over the WHOLE emitted exercise bundle's UTF-8 bytes --
-- the catch-all identity check
-- ("Exercises.Corpus".'Exercises.Corpus.fnv1a32' recomputes it over the
-- fetched text). 'Nothing' for a language this build did not emit.
manifestFingerprint :: Text -> Maybe Word32
''' % (decks, exercises, prompts))
    for lang in ("en", "ja"):
        out.append('manifestFingerprint "%s" = Just %d\n' % (lang, fnv1a32(bundles[lang])))
    out.append("manifestFingerprint _    = Nothing\n")

    out.append(MANIFEST_MANUAL_HEADER)
    for i, (slug, pages) in enumerate(manual_docs):
        out.append("  %s (%s, %d)\n" % ("[" if i == 0 else ",", hs_string(slug), pages))
    out.append("  ]\n")
    out.append('''
manifestManualDocCount :: Int
manifestManualDocCount = %d

-- | FNV-1a\\/32 over the WHOLE emitted manual bundle's UTF-8 bytes --
-- the manual half's catch-all identity check, computed and consumed
-- exactly like 'manifestFingerprint'.
manifestManualFingerprint :: Text -> Maybe Word32
''' % (len(manual_docs),))
    for lang in ("en", "ja"):
        out.append('manifestManualFingerprint "%s" = Just %d\n' % (lang, fnv1a32(manual_bundles[lang])))
    out.append("manifestManualFingerprint _    = Nothing\n")
    return "".join(out)


def hs_string(s):
    """A Haskell string literal. Deck file names are ASCII by the
    filename grammar (SXC1.Exercise.Reader.validFileName) and manual
    slugs are ASCII by the route grammar, which this re-checks rather
    than assuming."""
    for ch in s:
        if not (" " <= ch <= "~") or ch in ('"', "\\"):
            fail("name %r is not printable ASCII -- refusing to emit it as a Haskell literal" % s)
    return '"%s"' % s


def index_entries(index_path):
    out = []
    with open(index_path, encoding="utf-8") as fh:
        for line in fh:
            s = line.strip()
            if not s or s.startswith("#"):
                continue
            out.append(s)
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--exercises-dir", required=True)
    ap.add_argument("--translations-dir", required=True,
                    help="the manual documents' directory (translations/)")
    ap.add_argument("--out-dir", help="write content.{en,ja}.txt and manuals.{en,ja}.txt here")
    ap.add_argument("--manifest-hs", help="write the generated Bundle.Manifest module here")
    args = ap.parse_args()
    if not args.out_dir and not args.manifest_hs:
        fail("nothing to do: pass --out-dir, --manifest-hs, or both")

    check_fnv_vectors()

    index_path = os.path.join(args.exercises_dir, "INDEX")
    if not os.path.isfile(index_path):
        fail("%s does not exist" % index_path)
    names = index_entries(index_path)
    if not names:
        fail("%s names no deck files" % index_path)
    if len(set(names)) != len(names):
        fail("%s names the same deck file more than once" % index_path)

    bundles, totals = build_bundles(args.exercises_dir, names)
    # BOTH corpora are built before ANYTHING is written, so a manual-side
    # failure can never leave a half-updated pair of artifacts behind (a
    # fresh manifest describing bundles that were never re-emitted is
    # exactly the disagreement the app refuses to boot on).
    manual_bundles, manual_docs = build_manual_bundles(args.translations_dir)

    if args.manifest_hs:
        text = manifest_hs(names, totals, bundles, manual_docs, manual_bundles)
        os.makedirs(os.path.dirname(os.path.abspath(args.manifest_hs)), exist_ok=True)
        with open(args.manifest_hs, "w", encoding="utf-8") as fh:
            fh.write(text)
        print("emit-content-bundles: %s -> %d decks, %d exercises, %d prompts, fingerprints en=%d ja=%d; "
              "%d manual docs (%s), manual fingerprints en=%d ja=%d"
              % (args.manifest_hs, totals[0], totals[1], totals[2],
                 fnv1a32(bundles["en"]), fnv1a32(bundles["ja"]),
                 len(manual_docs), " ".join("%s:%d" % d for d in manual_docs),
                 fnv1a32(manual_bundles["en"]), fnv1a32(manual_bundles["ja"])))

    if args.out_dir:
        os.makedirs(args.out_dir, exist_ok=True)
        for lang in ("en", "ja"):
            data = bundles[lang]
            out_path = os.path.join(args.out_dir, "content.%s.txt" % lang)
            with open(out_path, "wb") as fh:
                fh.write(data)
            gz = len(gzip.compress(data, 9))
            print("emit-content-bundles: content.%s.txt -> %d bytes raw, %d bytes gzipped (%d decks, fnv1a=%d)"
                  % (lang, len(data), gz, len(names), fnv1a32(data)))
        for lang in ("en", "ja"):
            data = manual_bundles[lang]
            out_path = os.path.join(args.out_dir, "manuals.%s.txt" % lang)
            with open(out_path, "wb") as fh:
                fh.write(data)
            gz = len(gzip.compress(data, 9))
            # The per-doc language summary makes the temporary EN
            # fallback (ruling 4) legible in the build log itself, not
            # only in the app.
            langs = [l.split(" ")[2] for l in data.decode("utf-8").split("\n") if l.startswith("!SXC1-DOC ")]
            fallbacks = [MANUAL_SLUGS[i] for i, l in enumerate(langs) if l != lang]
            print("emit-content-bundles: manuals.%s.txt -> %d bytes raw, %d bytes gzipped (%d docs, fnv1a=%d%s)"
                  % (lang, len(data), gz, len(manual_docs), fnv1a32(data),
                     "" if not fallbacks else ", %d falling back to en: %s" % (len(fallbacks), " ".join(fallbacks))))


if __name__ == "__main__":
    main()
