#!/usr/bin/env python3
"""emit-content-bundles.py -- build the per-language exercise content
bundles (M6 W1, briefs/M6-plan.md ruling 1/2).

Reads content/exercises/INDEX and every deck file it names, and emits

    <out-dir>/content.en.txt      the EN bundle
    <out-dir>/content.ja.txt      the JA bundle

THE BUNDLE FORMAT (consumed by site/app/Exercises/Bundle.hs's
parseBundle -- keep the two in sync):

    !SXC1-BUNDLE v1 <lang> <deck-count>
    !SXC1-DECK <file name, the bare INDEX entry>
    <that deck's emitted text>
    !SXC1-DECK <next file name>
    ...

Decks appear in INDEX order. "!SXC1-" at column 0 is the reserved
delimiter prefix: no source line may start with it (enforced below), so
splitting the bundle back into decks is unambiguous.

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

Per-file preconditions (all hold for the whole committed corpus): UTF-8,
no CR, ends with exactly one trailing newline run boundary (a final
"\\n"), no line starting with "!SXC1-".
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


def fail(msg):
    print("emit-content-bundles: ERROR: %s" % msg, file=sys.stderr)
    sys.exit(1)


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
            for p in payloads:
                if HEADING_RE.match(p):
                    fail("%s: a prose ja: payload may not be a structural heading" % where)
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
    ap.add_argument("--out-dir", required=True)
    args = ap.parse_args()

    index_path = os.path.join(args.exercises_dir, "INDEX")
    if not os.path.isfile(index_path):
        fail("%s does not exist" % index_path)
    names = index_entries(index_path)
    if not names:
        fail("%s names no deck files" % index_path)

    bundles = {"en": [], "ja": []}
    for name in names:
        path = os.path.join(args.exercises_dir, name)
        if not os.path.isfile(path):
            fail("INDEX names %s but %s does not exist" % (name, path))
        text = open(path, encoding="utf-8").read()
        en_lines, ja_lines = emit_deck(name, text)
        bundles["en"].append((name, en_lines))
        bundles["ja"].append((name, ja_lines))

    os.makedirs(args.out_dir, exist_ok=True)
    for lang in ("en", "ja"):
        out_lines = ["!SXC1-BUNDLE v1 %s %d" % (lang, len(names))]
        for name, dlines in bundles[lang]:
            out_lines.append("!SXC1-DECK %s" % name)
            out_lines.extend(dlines)
        data = ("\n".join(out_lines) + "\n").encode("utf-8")
        out_path = os.path.join(args.out_dir, "content.%s.txt" % lang)
        with open(out_path, "wb") as fh:
            fh.write(data)
        gz = len(gzip.compress(data, 9))
        print("emit-content-bundles: content.%s.txt -> %d bytes raw, %d bytes gzipped (%d decks)"
              % (lang, len(data), gz, len(names)))


if __name__ == "__main__":
    main()
