# Plan: manuscript-edit CLI tool

## Context

You supervise many junior scientists and routinely receive Word-with-track-changes drafts that need a lot of low-level copyediting — sentence tightening, word choice, topic-sentence repair — before you get to the higher-level review. You want a bash tool you invoke from a folder with two arguments (the manuscript file and a prompt file describing the edits), and you want it to emit side-by-side artifacts you can review visually as PDFs. Round-tripping Claude's edits back into Word as tracked changes is explicitly out of scope for v1.

## Practicality verdict

This is very practical. Every piece of the pipeline exists as a mature, free, command-line tool. The weakest link — getting edits back into a Word-tracked-changes document — is correctly scoped out; visible-diff PDFs are enough for you to review, then apply accepted edits by hand in Word. That manual re-entry step is unavoidable without a much heavier tool.

## Recommended pipeline

v1 is `.docx`-only. End-to-end:

1. **Accept prior tracked changes** → clean baseline (pandoc `--track-changes=accept`)
2. **docx → Markdown** via pandoc (Claude's editing substrate)
3. **Claude Code headless** applies your prompt → `edited.md`
4. **Convert both `.md`s → `.tex`** via pandoc (deterministic, structurally stable)
5. **`latexdiff`** produces a third `.tex` with visible red/blue insertions/deletions
6. **Compile all three `.tex` → PDF** via `latexmk`
7. You review the diff PDF, apply accepted edits by hand back into the Word doc

## Key design choices (the ones that actually matter)

- **Markdown as Claude's editing substrate.** pandoc docx→md is dramatically cleaner than docx→tex, and Claude preserves Markdown structure better than LaTeX. LaTeX is still used for the *diff rendering* step because `latexdiff` is the best-in-class tool for this and produces publication-quality PDFs. You suggested LaTeX as intermediate in cp.txt — we're deviating on this point.
- **Accept incoming tracked changes by default.** Matches your stated workflow ("add my changes on top"). Overridable per-run.
- **`claude -p` headless, not the raw Anthropic API.** You already have Claude Code configured; keeps one auth path. Allowed tools restricted to Read/Write; tight system prompt enforces prose-only edits with structural preservation (no touching `\cite`, `\ref`, figure refs, equations, tables, superscripts).
- **Default model: Sonnet 4.6.** Plenty for copyedit-level work, ~5× cheaper than Opus. Overridable with `--model opus`.
- **v1 output = three PDFs only.** No docx round-trip, no `.tex`-input path. Future extensions noted.
- **`latexmk -pdf` for compilation.** Handles multi-pass runs automatically.

## Interface shape

Install as a git repo at `~/Projects/manuscript-editor/` with a single executable entry point `editmanuscript` (symlinked into `~/bin` or added to PATH).

```bash
editmanuscript DOCUMENT.docx PROMPT_FILE [options]

  --out DIR                output folder (default: same as DOCUMENT)
  --model sonnet|opus      default: sonnet
  --incoming-tc accept|reject|all    default: accept
  --no-pdf                 stop after producing .tex files
  --keep-intermediates     don't clean pandoc/latex aux files
```

For input `paper.docx`, outputs in `--out`:

- `paper.md`, `paper.edited.md` — human-readable drafts
- `paper.tex`, `paper.edited.tex`, `paper.diff.tex` — latexdiff inputs/output
- `paper.pdf`, `paper.edited.pdf`, `paper.diff.pdf` — for review

## Dependencies to install

- `pandoc` (apt)
- `latexdiff` (apt, standalone package — **not** in `texlive-extra-utils`)
- `latexmk` (apt)

You already have Claude Code and TeX Live.

## Risks worth naming

- **pandoc docx→md lossy edges**: complex nested tables, Word comments, equation objects created in MS Equation Editor (vs typed-LaTeX), embedded images with captions. Straight prose and simple formatting convert cleanly. Worth a small test-run on a representative junior-scientist doc before committing.
- **Claude over-editing**: silent changes to structure, citations, figure/table labels, or numbered superscript references. Mitigation: tight system prompt naming specific tokens to preserve (`^1,2^`, `^12--14^`, `Fig. S4`, equation blocks, etc.) + a post-edit validator that greps for preserved tokens and warns on drift. Worth including in v1.
- **latexdiff noise on math/tables**: flags `--math-markup=whole` and `--graphics-markup=0` tame this.

## Repo layout (proposed)

```
~/Projects/manuscript-editor/
  editmanuscript              # bash entry point (~200 lines)
  prompts/
    system.md                 # system prompt enforcing structural preservation
  lib/
    preserve_tokens.sh        # post-edit validator (grep for \cite, \ref, ^n^, etc.)
  examples/
    sample_prompt.txt
  README.md
  .gitignore
```

## Future extensions (not v1)

- LaTeX input path (skip pandoc-in, edit tex directly)
- `.docx` output with tracked changes via a md→docx-with-changes tool (e.g. a `redlines`-style diff renderer) — would let junior scientists open the edits directly in Word
- Chunked editing for very long manuscripts + supplementary materials
- Bibliography-aware editing (currently treats numeric superscript refs as opaque tokens)

## Prerequisite setup (to do before running the plan)

1. `sudo apt install pandoc latexdiff latexmk`
2. `mkdir -p ~/Projects/manuscript-editor && cd ~/Projects/manuscript-editor && git init`
3. Ensure `~/bin` exists and is on `$PATH` (or decide where the `editmanuscript` symlink goes)
4. Confirm `claude --version` works from the shell (it does — Claude Code is already installed)

## Verification plan (after implementation)

- Run against the existing `MS3_Gresse_et_al.docx` in this folder with a sample prompt file reproducing the kind of copyedits you want. Compare the resulting `*.diff.pdf` against your existing `MS3_Gresse_et_al.diff` to sanity-check that the automated pipeline produces something at least as useful as your manual run.
- Check preservation: diff the `\cite{}`/`\ref{}`/superscript-citation tokens between `paper.tex` and `paper.edited.tex`; flag any additions or deletions.
- Visual review of all three PDFs.
