---
editor_options: 
  markdown: 
    wrap: 72
---

# Plan: manuscript-editor v2 — closing the loop to tracked-changes .docx

## Context

v1 produces three PDFs (original, edited, latexdiff) for visual review.
The user then transcribes accepted edits by hand into Word. The goal of
v2 is to close that loop: emit a `.docx` where Claude's edits appear as
Word *tracked changes* the user can accept or reject in Word directly.

This is the hardest piece of the original vision and was explicitly
descoped from v1. It deserves careful thought because the naive approach
("just have pandoc write tracked changes") does not work — pandoc reads
tracked changes but cannot write them.

## Why this is harder than it looks

1.  **Pandoc is one-way on tracked changes.**
    `--track-changes=accept|reject|all` only controls how pandoc *reads*
    existing changes. On the `md → docx` side, pandoc has no concept of
    "this delta is a revision by author X". The tracked-changes XML
    (`<w:ins>`, `<w:del>`, `<w:delText>`) has to come from somewhere
    else.
2.  **Word's tracked-changes XML is structural, not textual.** Revision
    marks live inside paragraph runs, not between them. A sentence-level
    rewrite needs to be decomposed into one or more runs of deleted text
    followed by runs of inserted text, all nested correctly inside the
    surrounding `<w:p>` / `<w:r>` structure. Getting this wrong produces
    a file Word opens but renders oddly (missing formatting, broken list
    numbering, stray paragraph marks).
3.  **Formatting boundaries bite.** If the original says
    `the **red**    fox` and Claude changes it to `the **scarlet** fox`,
    the revision needs to live *inside* the bold run — not wrapping it.
    Word-level diffs operating on plain text lose this context.
4.  **Prior tracked changes in the input.** The v1 default accepts those
    before editing. v2 needs to decide whether that remains the baseline
    or whether prior changes stay visible (layering two authors' edits
    is messy; Word handles it but the output is noisy).
5.  **Author attribution matters.** The user wants the revisions to show
    up as their edits (so they can accept/reject in Word as normal).
    Labeling the author `"Reuman (via Claude)"` is honest and lets the
    user filter in the Review pane.

## Approaches under consideration

Four candidates, ranked by engineering effort ascending.

### A. "Two .docx files, user clicks Compare" (trivial — already possible)

-   Produce `paper.accepted.docx` (pandoc md→docx from the
    accepted-prior-changes baseline) and `paper.edited.docx` (pandoc
    md→docx from Claude's edited md).
-   Ship both alongside the PDFs.
-   User opens Word, `Review → Compare → Compare…`, picks the two files.
    Word generates a third doc with tracked changes.

This is not really v2 — it's just surfacing two intermediate files v1
already has in-flight. But it's worth making a first-class output
regardless of what else v2 does: it is the highest-quality fallback
(Word's own compare algorithm) and takes \~5 lines to add to
`editmanuscript`.

Recommended inclusion: **yes, unconditionally**. Do this even if we also
ship one of B/C/D.

### B. LibreOffice headless compare

-   Same two .docx files as in A.
-   Drive LibreOffice from the command line to do the compare and write
    `paper.tracked.docx`.
-   Deliver that file directly — no manual Word step.

**Status**: needs investigation. `soffice --help` doesn't advertise a
`--compare` flag; LibreOffice's Compare Documents lives in the GUI's
`Edit → Track Changes → Compare Document`. Driving it headlessly
typically requires a small macro run via
`soffice --headless --norestore --nologo --nofirststartwizard --invisible macro:///...`
or the UNO bridge. Achievable but more involved than the flag suggests.

**Risks**: - Output fidelity: LibreOffice's compare algorithm differs
from Word's. May flag cosmetic differences (smart quotes, non-breaking
spaces) as edits unless the inputs are first normalized. - LibreOffice
macros have a steep operational reliability curve — they can hang, spawn
zombie processes, fight over a shared user profile. Worth a timeout and
a throwaway `--user-profile` per run.

**Pros**: Leverages mature compare logic. No hand-rolled diff needed.
**Cons**: Adds a heavyweight dependency (full LibreOffice install).
Output quality is a live question until tested.

### C. Raw-OOXML injection via pandoc (hand-rolled diff)

Pandoc's Markdown reader supports passing raw OOXML through to the docx
writer via `` `<w:tag …/>`{=openxml} `` inline spans and
```` ```{=openxml} … ``` ```` blocks. If we can produce a Markdown file
where every changed passage is wrapped in the right `<w:ins>` /
`<w:del>` construct, pandoc will embed those verbatim in the output docx
and Word will render them as tracked changes.

Pipeline sketch:

```         
accepted-original.md ──┐
                       ├──► word-level diff ──► merged.md (with raw OOXML) ──► pandoc ──► paper.tracked.docx
edited.md ─────────────┘
```

The new piece is a small script (Python, probably) that:

1.  Tokenises both markdown files at the word level, keeping track of
    paragraph and sentence boundaries.
2.  Uses `difflib.SequenceMatcher` (or `diff-match-patch` for cleaner
    word-level granularity) to compute insert/delete/replace opcodes.
3.  Emits `merged.md` where each changed span is wrapped in the
    appropriate raw-openxml construct, preserving surrounding markdown
    (emphasis, lists, etc.).

**Pros**: - Deterministic, no external proprietary tool. - Small surface
area — one Python script, one pandoc invocation. - Keeps everything else
of v1 unchanged.

**Cons / open problems**: - **Formatting-boundary handling.** Diffing
raw markdown means `**scarlet**` vs `**red**` looks like a change to
both the text and the surrounding asterisks. Diffing the pandoc AST (via
`pandoc -t   json`) instead of the raw markdown string sidesteps this
but is a bigger lift. Start with raw-text diff and see how bad the
asterisk problem actually is; AST-level diff is the fallback. -
**Structural changes.** A "paragraph split" needs a `<w:ins>` around a
`<w:p>` boundary; `diff` operating on a flattened word stream will
mis-classify this as a deletion-plus-insertion of surrounding text.
Recommend detecting paragraph-boundary deltas separately and handling
them as structural insertions. - **Equations, tables, figures.** Don't
diff these. Treat the entire block as a single token and either leave it
unchanged or replace wholesale with a single ins/del pair. The v1 system
prompt already tells Claude not to touch math/tables, so in practice
these should not differ. - **Lists.** List item reordering is a classic
diff pathology. Punt on this for v2 — flag as a known limitation, not a
bug.

**Pros**: Most "closed loop" of the automated options. **Cons**: The
most novel code. Testing-heavy.

### D. Python-docx post-processor

-   Generate `accepted-original.docx` and `edited.docx` via pandoc.
-   Use `python-docx` (or direct `lxml` on `document.xml`) to walk both
    files, align paragraphs, and synthesize a third docx with `<w:ins>`
    / `<w:del>` runs.
-   Effectively reimplementing LibreOffice's compare in Python.

Not recommended for v2 — highest engineering cost, most room for bugs,
and duplicates what B would give for free if B's output quality is
acceptable.

## Recommendation

Short version: **A + (B or C)**.

1.  **Unconditionally** add `paper.accepted.docx` and
    `paper.edited.docx` as first-class outputs of the pipeline. Cheap,
    immediately useful, and a safety net for whatever else we do.
2.  **Investigate B first** (LibreOffice headless compare). If the
    macro-driven compare produces usable output on one real manuscript,
    ship it — this is the lowest-effort path to a closed loop.
3.  **Fall back to C** if B's output is too noisy, too slow, or too
    unreliable. Build the pandoc raw-OOXML injection path in Python.

D stays on the shelf unless both B and C fail.

## Investigation tasks (to do before committing to B vs C)

1.  **LibreOffice compare**: find the minimal macro that runs Compare
    Documents and saves the result. Probable shape:

    ``` python
    # scriptforge or uno macro:
    oDoc1.compareWith(oDoc2, "tracked_output.docx")
    ```

    Run on a small fixture, open result in Word, evaluate fidelity.

2.  **Pandoc raw-openxml**: verify the `` `…`{=openxml} `` and
    ```` ```{=openxml} ``` ```` passthrough survives md→docx with
    revision marks intact. Small fixture:

    ``` markdown
    The fox was `<w:ins w:id="1" w:author="test" w:date="2026-04-22T00:00:00Z"><w:r><w:t>scarlet</w:t></w:r></w:ins>`{=openxml}`<w:del w:id="2" w:author="test" w:date="2026-04-22T00:00:00Z"><w:r><w:delText>red</w:delText></w:r></w:del>`{=openxml}.
    ```

    Confirm Word opens it and shows one tracked insert + one tracked
    delete.

3.  **Diff library**: prototype a word-level diff on two small markdown
    files using `difflib` and `diff-match-patch`; eyeball which produces
    cleaner opcodes for prose.

4.  **Author attribution**: decide on a single author string (e.g.
    `"Reuman (via Claude)"` plus the model name as a comment). Word's UI
    surfaces the author in the Review pane, so clarity matters.

## Proposed pipeline (after v2)

```         
paper.docx
   │
   ├─► [pandoc --track-changes=accept] ─► paper.md (accepted baseline)
   │                                         │
   │                                         ├─► pandoc ─► paper.accepted.docx   ◄── new v2 output
   │                                         │
   │                                         └─► Claude (-p) ─► paper.edited.md
   │                                                               │
   │                                                               ├─► pandoc ─► paper.edited.docx   ◄── new v2 output
   │                                                               │
   │                                                               └─► [B: LibreOffice compare] ─► paper.tracked.docx   ◄── the close-the-loop output
   │                                                                   or
   │                                                                  [C: diff+raw-openxml injection] ─► paper.tracked.docx
   │
   ├─► pandoc md→tex ×2 + latexdiff ─► three PDFs  (unchanged from v1)
   └─► preserve_tokens validator                    (unchanged from v1)
```

Only one new output file is genuinely novel: `paper.tracked.docx`.
Everything else either comes free from the v1 pipeline or is a
straightforward pandoc invocation.

## New dependencies

-   **If B**: `libreoffice` (apt), plus one small macro shipped in the
    repo. Probably `python3-uno` indirectly.
-   **If C**: `python3` (already present on the target system), `pip`
    install of `diff-match-patch` (optional — `difflib` in the stdlib is
    a viable fallback).

## Risks worth naming (new ones beyond v1)

-   **Round-trip formatting drift**: pandoc md→docx doesn't always
    produce a document visually identical to Word's own rendering of the
    original. Tables, figure placement, running headers can shift.
    Mitigation: use the original docx as the template via
    `pandoc   --reference-doc=paper.docx`. This carries over styles; it
    does *not* fix structural drift.
-   **Tracked-change noise on cosmetic-only differences**: if pandoc
    normalises quote marks or spacing, the compare step will flag those
    as edits even though Claude didn't touch the prose. Mitigation:
    normalise both baseline and edited files through the *same* md→docx
    path before comparing, so any pandoc-introduced cosmetic deltas
    cancel out.
-   **User confusion from author attribution**: revisions need to
    clearly identify Claude as the author, so the user can filter in
    Word. Use a single, obvious author string.
-   **LibreOffice reliability** (if B): worth a timeout wrapper and a
    per-run `--user-profile` dir so crashed instances don't poison
    subsequent runs.

## Other v2 features worth bundling (not the main ask)

These came up in v1 planning as "future extensions". Any or all could
ride along:

-   **LaTeX input path.** Skip pandoc-in; let Claude edit `.tex`
    directly when the manuscript is already LaTeX.
-   **Chunked editing for long manuscripts.** Split the manuscript by
    section, edit each in a separate Claude call, reassemble. Needed
    once manuscripts + supplements exceed what a single call handles
    well.
-   **Bibliography-aware editing.** Currently the system prompt treats
    citation tokens as opaque. v2 could parse a `.bib` or `.csl-json`
    and allow Claude to *check* (but not alter) citations for relevance,
    surfacing questions in a side-channel file.
-   **Multi-pass editing.** Run different prompt files on different
    sections (e.g., heavy copyedit for Discussion, light touch for
    Methods). Natural extension of the current single-prompt design.
-   **Preservation of Word comments from input.** v1 drops these at the
    pandoc step. v2 could extract them first, round-trip them as
    Markdown annotations, and reinject them at the md→docx step.

I do not recommend pursuing all of these in v2. The close-the-loop
feature is the one that substantively changes the tool's value; the
others are refinements and can ship independently.

## What stays unchanged from v1

-   Entry-point interface and flags (adding new optional flags, not
    breaking existing ones).
-   System prompt in `prompts/system.md`.
-   `preserve_tokens.sh` validator.
-   Markdown as Claude's editing substrate.
-   PDF triad as reviewable output.
-   Sonnet-default, `claude -p` headless invocation with stream-json
    progress reporting.
