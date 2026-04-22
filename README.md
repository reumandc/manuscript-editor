# manuscript-editor

A small bash tool that runs a `.docx` manuscript through Claude Code for
low-level copyediting (sentence tightening, word choice, topic-sentence
repair) and emits three PDFs — the original, the edited version, and a
side-by-side `latexdiff` — so you can visually review the changes before
applying accepted edits by hand in Word.

Scope is deliberately narrow: v1 does not round-trip edits back into Word
as tracked changes. See `manuscript_editor_plan.md` for the full design
rationale.

## Install

### Dependencies

```bash
sudo apt install pandoc latexdiff latexmk texlive-latex-extra
```

Claude Code must be installed and authenticated (`claude --version`
should work from your shell).

### Put `editmanuscript` on your PATH

```bash
cd ~/Projects/manuscript-editor
ln -s "$PWD/editmanuscript" ~/bin/editmanuscript   # assuming ~/bin is on PATH
```

## Usage

```bash
editmanuscript DOCUMENT.docx PROMPT_FILE [options]
```

where `PROMPT_FILE` is a plain-text file describing the kinds of edits
you want. See `examples/sample_prompt.txt` for a starting point.

### Options

| Flag | Description | Default |
|---|---|---|
| `--out DIR` | Output folder | same directory as `DOCUMENT` |
| `--model sonnet\|opus` | Claude model | `sonnet` |
| `--incoming-tc accept\|reject\|all` | How to handle pre-existing tracked changes in the input .docx | `accept` |
| `--no-pdf` | Stop after producing `.tex` files | off |
| `--keep-intermediates` | Don't clean LaTeX aux files after compile | off |
| `--max-budget-usd N` | Cap Claude API spend per run (API-key auth only) | `5` |

### What you get

For input `paper.docx`, the output directory will contain:

- `paper.md`, `paper.edited.md` — human-readable drafts
- `paper.tex`, `paper.edited.tex`, `paper.diff.tex` — the `latexdiff` inputs and output
- `paper.pdf`, `paper.edited.pdf`, `paper.diff.pdf` — for visual review

The diff PDF is the one you will mostly look at. Insertions are shown in
blue and deletions in red (the `latexdiff` default).

## Example

```bash
cd ~/some_paper/
editmanuscript draft.docx ~/Projects/manuscript-editor/examples/sample_prompt.txt
open draft.diff.pdf
```

## How it works

1. `pandoc` converts the `.docx` to Markdown, accepting any prior
   tracked changes so the baseline is clean.
2. `claude -p` (headless Claude Code) applies your prompt to the
   Markdown, with a tightly scoped system prompt that forbids changes to
   citations, cross-references, equations, tables, figure labels, and
   numbered superscript citations.
3. `pandoc` converts both Markdown files to LaTeX.
4. `latexdiff` produces a third `.tex` with visible insertions and
   deletions.
5. `latexmk -pdf` compiles all three to PDF.
6. A post-edit validator (`lib/preserve_tokens.sh`) checks that citation
   keys, `\ref{...}` tokens, and `\textsuperscript{...}` blocks have not
   drifted between the original and edited LaTeX; it warns (but does not
   fail) if they have.

## Known limitations

- `.docx` input only. A LaTeX input path is a plausible future extension.
- `pandoc` docx→md can lose fidelity on nested tables, MS Equation Editor
  objects, and Word comments. Simple prose and formatting convert cleanly.
- Claude can occasionally drift on structural tokens despite the system
  prompt; the validator will flag obvious cases but you should still
  sanity-check the diff PDF.
- Very long manuscripts plus supplementary material may exceed what
  works well in a single editing pass. Chunked editing is a future
  extension.

## Repo layout

```
editmanuscript              bash entry point
prompts/system.md           system prompt enforcing structural preservation
lib/preserve_tokens.sh      post-edit token drift validator
examples/sample_prompt.txt  representative user prompt
```
