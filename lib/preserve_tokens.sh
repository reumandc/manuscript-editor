#!/usr/bin/env bash
# preserve_tokens.sh ORIGINAL.tex EDITED.tex
#
# Warn-only validator. Extracts citation / cross-reference / superscript-citation
# tokens from both .tex files and reports any drift (added, removed, or altered
# tokens). Exit status is always 0 — the pipeline should continue even when
# drift is found — but a clear warning is printed so the user can inspect the
# diff PDF with extra care.

set -u

if [[ $# -ne 2 ]]; then
    echo "usage: preserve_tokens.sh ORIGINAL.tex EDITED.tex" >&2
    exit 2
fi

orig="$1"
edit="$2"

if [[ ! -f "$orig" ]]; then
    echo "preserve_tokens: original file not found: $orig" >&2
    exit 2
fi
if [[ ! -f "$edit" ]]; then
    echo "preserve_tokens: edited file not found: $edit" >&2
    exit 2
fi

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# Regex patterns for the tokens we want preserved.
# -o prints only the matching part; -E uses extended regex.
# The citation pattern matches \cite, \citet, \citep, \autocite, \parencite, \textcite, etc.
cite_pat='\\[A-Za-z]*cite[A-Za-z]*(\[[^]]*\])?(\[[^]]*\])?\{[^}]*\}'
ref_pat='\\(auto|C|c|page|eq|name|v)?ref\{[^}]*\}'
sup_pat='\\textsuperscript\{[^}]*\}'

extract() {
    local in="$1" kind="$2" out="$3"
    case "$kind" in
        cite) grep -oE "$cite_pat" "$in" 2>/dev/null | LC_ALL=C sort > "$out" ;;
        ref)  grep -oE "$ref_pat"  "$in" 2>/dev/null | LC_ALL=C sort > "$out" ;;
        sup)  grep -oE "$sup_pat"  "$in" 2>/dev/null | LC_ALL=C sort > "$out" ;;
    esac
}

warn_count=0
report_kind() {
    local kind="$1" label="$2"
    extract "$orig" "$kind" "$tmp/orig.$kind"
    extract "$edit" "$kind" "$tmp/edit.$kind"

    if ! diff -q "$tmp/orig.$kind" "$tmp/edit.$kind" > /dev/null; then
        warn_count=$((warn_count + 1))
        echo ""
        echo "⚠  preserve_tokens: drift detected in $label tokens"
        echo "    (- only in original, + only in edited)"
        diff -u "$tmp/orig.$kind" "$tmp/edit.$kind" | tail -n +3 | sed 's/^/    /'
    fi
}

report_kind cite "citation (\\cite…)"
report_kind ref  "cross-reference (\\ref/\\eqref/…)"
report_kind sup  "numbered superscript (\\textsuperscript{…})"

if [[ $warn_count -eq 0 ]]; then
    echo "preserve_tokens: no drift in citation / reference / superscript tokens ✓"
else
    echo ""
    echo "preserve_tokens: $warn_count token class(es) showed drift — inspect the diff PDF carefully."
fi

exit 0
