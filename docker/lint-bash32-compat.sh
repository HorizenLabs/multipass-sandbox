#!/usr/bin/env bash
# lint-bash32-compat.sh — Check client-side scripts for Bash 4+ constructs
#
# Phase 1 (primary): Pattern grep for known Bash 4+ features (skips comments).
# Phase 2 (secondary): bash-3.2 -n syntax check (catches parse-level errors).
#
# Usage: lint-bash32-compat.sh file1.sh file2.sh ...

set -euo pipefail

if [ $# -eq 0 ]; then
    echo "Usage: lint-bash32-compat.sh FILE..." >&2
    exit 1
fi

exit_code=0

# ---------- Phase 1: Pattern grep for Bash 4+ constructs ----------
# Each pattern: <regex> <description>
patterns=(
    # Associative arrays (Bash 4.0+)
    'declare[[:space:]]+-A'           'declare -A (associative arrays, Bash 4.0+)'
    'local[[:space:]]+-A'             'local -A (associative arrays, Bash 4.0+)'
    # Case modification (Bash 4.0+)
    '\$\{[a-zA-Z_][a-zA-Z_0-9]*,,'   '${var,,} (lowercase, Bash 4.0+)'
    '\$\{[a-zA-Z_][a-zA-Z_0-9]*\^\^' '${var^^} (uppercase, Bash 4.0+)'
    '\$\{[a-zA-Z_][a-zA-Z_0-9]*,[^,]' '${var,} (lowercase first char, Bash 4.0+)'
    '\$\{[a-zA-Z_][a-zA-Z_0-9]*\^[^^]' '${var^} (uppercase first char, Bash 4.0+)'
    # Auto-case attributes (Bash 4.0+)
    '(declare|local)[[:space:]]+-[a-zA-Z]*l' 'declare/local -l (auto-lowercase attribute, Bash 4.0+)'
    '(declare|local)[[:space:]]+-[a-zA-Z]*u' 'declare/local -u (auto-uppercase attribute, Bash 4.0+)'
    # Builtins / keywords (Bash 4.0+)
    '\bmapfile\b'                     'mapfile (Bash 4.0+)'
    '\breadarray\b'                   'readarray (Bash 4.0+)'
    '\bcoproc\b'                      'coproc (Bash 4.0+)'
    # Pipe stderr (Bash 4.0+)
    '\|\&'                            '|& (pipe stderr shorthand, Bash 4.0+)'
    # Append-redirect both streams (Bash 4.0+)
    '&>>'                             '&>> (append stdout+stderr, Bash 4.0+)'
    # Namerefs (Bash 4.3+)
    'declare[[:space:]]+-[a-zA-Z]*n'  'declare -n (nameref, Bash 4.3+)'
    'local[[:space:]]+-[a-zA-Z]*n'    'local -n (nameref, Bash 4.3+)'
    # Global scope from function (Bash 4.2+)
    '(declare|local)[[:space:]]+-[a-zA-Z]*g' 'declare -g (global scope from function, Bash 4.2+)'
    # GNU-only (macOS lacks it)
    '\breadlink[[:space:]]+-f\b'      'readlink -f (GNU-only, macOS lacks it)'
)

for f in "$@"; do
    if [ ! -f "$f" ]; then
        echo "WARN: $f not found, skipping" >&2
        continue
    fi

    i=0
    while [ $i -lt ${#patterns[@]} ]; do
        regex="${patterns[$i]}"
        desc="${patterns[$((i + 1))]}"
        i=$((i + 2))

        # grep -n for line numbers, skip comment-only lines (leading #)
        while IFS= read -r match; do
            # Strip leading whitespace from the matched line content to check for comment
            line_content="${match#*:}"
            stripped="${line_content#"${line_content%%[![:space:]]*}"}"
            if [[ "$stripped" == \#* ]]; then
                continue
            fi
            echo "FAIL: $f:${match%%:*}: $desc"
            echo "  $line_content"
            exit_code=1
        done < <(grep -nE "$regex" "$f" 2>/dev/null || true)
    done
done

# ---------- Phase 1b: Silent-failure patterns (parse OK in 3.2, wrong behavior) ----------
# These are NOT caught by bash-3.2 -n, making them especially dangerous.

# [[ -v varname ]] — Bash 3.2 treats -v as non-empty string test (always true)
for f in "$@"; do
    [ -f "$f" ] || continue

    while IFS= read -r match; do
        lineno="${match%%:*}"
        line="${match#*:}"
        stripped="${line#"${line%%[![:space:]]*}"}"
        [[ "$stripped" == \#* ]] && continue

        echo "FAIL: $f:$lineno: [[ -v var ]] (variable-existence test, Bash 4.2+; silently wrong on 3.2)"
        echo "  $line"
        echo "  Fix: use [[ -n \"\${var:-}\" ]] or [[ -z \"\${var+x}\" ]] instead"
        exit_code=1
    done < <(grep -nE '\[\[[[:space:]]+-v[[:space:]]' "$f" 2>/dev/null || true)
done

# ${arr[-N]} — Bash 3.2 evaluates as arithmetic, silently wrong index
for f in "$@"; do
    [ -f "$f" ] || continue

    while IFS= read -r match; do
        lineno="${match%%:*}"
        line="${match#*:}"
        stripped="${line#"${line%%[![:space:]]*}"}"
        [[ "$stripped" == \#* ]] && continue

        echo "FAIL: $f:$lineno: \${arr[-N]} (negative array index, Bash 4.2+; silently wrong on 3.2)"
        echo "  $line"
        echo "  Fix: use \${arr[\${#arr[@]}-1]} instead of \${arr[-1]}"
        exit_code=1
    done < <(grep -nE '\$\{[a-zA-Z_][a-zA-Z_0-9]*\[-[0-9]+\]\}' "$f" 2>/dev/null || true)
done

# ---------- Phase 1c: Unguarded array expansions under set -u ----------
# In Bash 3.2, "${arr[@]}" on an empty array with set -u triggers
# "unbound variable".  The fix is ${arr[@]+"${arr[@]}"} (+ guard).
# Flag any "${name[@]}" not preceded by ${name[@]+ on the same line.
for f in "$@"; do
    [ -f "$f" ] || continue

    while IFS= read -r match; do
        lineno="${match%%:*}"
        line="${match#*:}"
        stripped="${line#"${line%%[![:space:]]*}"}"
        [[ "$stripped" == \#* ]] && continue

        # Extract all unguarded variable names from this line.
        # Strategy: remove all guarded expansions first, then look for bare ones.
        scrubbed="$line"
        # Strip ${name[@]+"${name[@]}"} patterns (both + and :+ variants)
        scrubbed=$(echo "$scrubbed" | sed -E 's/\$\{[a-zA-Z_][a-zA-Z_0-9]*\[@\]:?\+"[^"]*"\}//g')
        # Check if any bare "${name[@]}" remains
        if echo "$scrubbed" | grep -qE '"\$\{[a-zA-Z_][a-zA-Z_0-9]*\[@\]\}"'; then
            echo "FAIL: $f:$lineno: unguarded \${arr[@]} (empty array + set -u crashes Bash 3.2)"
            echo "  $line"
            echo "  Fix: use \${arr[@]+\"\${arr[@]}\"} instead of \"\${arr[@]}\""
            exit_code=1
        fi
    done < <(grep -nE '"\$\{[a-zA-Z_][a-zA-Z_0-9]*\[@\]\}"' "$f" 2>/dev/null || true)
done

if [ $exit_code -ne 0 ]; then
    echo ""
    echo "Bash 3.2 compatibility errors found."
    echo "Client scripts (bin/, lib/, commands/, install.sh, uninstall.sh) must"
    echo "work on macOS Bash 3.2. See CLAUDE.md Cross-platform conventions."
fi

# ---------- Phase 2: bash-3.2 -n syntax check ----------
if command -v bash-3.2 >/dev/null 2>&1; then
    for f in "$@"; do
        if [ ! -f "$f" ]; then
            continue
        fi
        echo "bash-3.2 -n: $f"
        if ! bash-3.2 -n "$f" 2>&1; then
            echo "FAIL: $f: bash-3.2 syntax check failed"
            exit_code=1
        fi
    done
else
    echo "WARN: bash-3.2 binary not available, skipping syntax check phase" >&2
fi

exit $exit_code
