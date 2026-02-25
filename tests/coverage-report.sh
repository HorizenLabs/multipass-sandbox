#!/usr/bin/env bash
# coverage-report.sh — Generate lcov coverage report from xtrace hits
#
# Reads hits.log files produced by coverage-trap.sh, cross-references with
# source files, and generates:
#   - lcov-format coverage/lcov.info (for CI integration / Codecov)
#   - Terminal summary table with per-file and total coverage percentages
#
# Usage: coverage-report.sh <output-dir> <hits-dir>...
#
# Example:
#   coverage-report.sh coverage/ coverage/unit coverage/integration

set -euo pipefail

if [[ $# -lt 2 ]]; then
    echo "Usage: coverage-report.sh <output-dir> <hits-dir>..." >&2
    exit 1
fi

OUTPUT_DIR="$1"
shift
HITS_DIRS=("$@")

WORKDIR="${_MPS_COV_PREFIX:-/workdir}"

# ---------- Merge all hits.log files ----------
MERGED_HITS=$(mktemp)
trap 'rm -f "$MERGED_HITS"' EXIT

for dir in "${HITS_DIRS[@]}"; do
    if [[ -f "$dir/hits.log" ]]; then
        cat "$dir/hits.log" >> "$MERGED_HITS"
    fi
done

if [[ ! -s "$MERGED_HITS" ]]; then
    echo "WARNING: No coverage data found in hits directories." >&2
    echo "  Looked in: ${HITS_DIRS[*]}" >&2
    exit 1
fi

# ---------- Extract unique file:line pairs ----------
# Xtrace lines look like: + <PREFIX>/lib/common.sh:42: some_command args
# Extract file:line, strip prefix, deduplicate.
# Docker-generated hits use /workdir/ prefix; host-generated (e2e) use
# the real repo path. Strip both so hits merge correctly.
HIT_LINES=$(mktemp)
trap 'rm -f "$MERGED_HITS" "$HIT_LINES"' EXIT

sed -n 's/^+\+ \(\/[^:]*\):\([0-9]*\):.*/\1:\2/p' "$MERGED_HITS" \
    | sed "s|^${WORKDIR}/||" \
    | sed 's|^/workdir/||' \
    | sort -u > "$HIT_LINES"

# ---------- Collect source files ----------
# These are the files we track coverage for
SOURCE_FILES=()
while IFS= read -r f; do
    SOURCE_FILES+=("$f")
done < <(find bin/ lib/ commands/ completions/ -type f \( -name '*.sh' -o -name '*.bash' -o -name 'mps' \) 2>/dev/null | sort)
# Also track install.sh and uninstall.sh at project root
for root_file in install.sh uninstall.sh; do
    [[ -f "$root_file" ]] && SOURCE_FILES+=("$root_file")
done

# ---------- Count executable lines in a file ----------
# Executable = non-blank, non-comment-only lines that bash xtrace can trace.
# Xtrace only fires for commands, not:
#   - Syntactic constructs: fi/done/esac/}/;;/)/else/elif/then/do/{
#   - Function declarations: name() { ... }
#   - Case pattern labels: pattern|pattern)
#   - Heredoc content between <<WORD and WORD
#   - Continuation lines (previous line ends with \)
_is_executable_line() {
    local stripped="$1"
    # Skip blank lines
    [[ -z "$stripped" ]] && return 1
    # Skip comment-only lines (# ...)
    [[ "$stripped" == \#* ]] && return 1
    # Skip closing/structural constructs that xtrace never traces
    # Includes ) and )"-style closings for subshells/arrays/command-substitutions
    case "$stripped" in
        fi|fi\ *|done|done\ *|"esac"|"}"|\}\;|";;"|";;"\ *|else|else\ *|elif\ *|then|then\ *|do|do\ *|"{"|\{\ *|\)*)
            return 1 ;;
    esac
    # Skip function declarations: name() or name() { — xtrace doesn't trace these
    case "$stripped" in
        *"()"*)
            local _fn_name="${stripped%%\(\)*}"
            case "$_fn_name" in
                *[!A-Za-z0-9_]*) ;; # contains non-word chars — not a function decl
                "") ;;               # empty — not a function decl
                *) return 1 ;;       # pure word chars — function declaration
            esac
            ;;
    esac
    # Skip case pattern labels: lines ending with ) that aren't commands
    # Xtrace fires on commands inside case branches, not on pattern labels
    case "$stripped" in
        *\))
            case "$stripped" in
                *'$('*) ;;   # command substitution — not a pattern label
                *'=('*) ;;   # array operation (arr=() / arr+=("x")) — not a pattern label
                case\ *) ;;  # one-line case: "case $x in pat) ;; *)" — xtrace traces case
                *) return 1 ;;
            esac
            ;;
    esac
    return 0
}

# Return line numbers of executable lines (context-aware).
# Tracks heredoc blocks and line continuations to avoid counting
# untraceable lines as executable.
executable_line_numbers() {
    local file="$1"
    local line_num=0
    local heredoc_terminator=""
    local in_continuation=false

    while IFS= read -r line || [[ -n "$line" ]]; do
        line_num=$((line_num + 1))
        local stripped="${line#"${line%%[![:space:]]*}"}"

        # ---- Inside heredoc: skip until terminator ----
        if [[ -n "$heredoc_terminator" ]]; then
            if [[ "$stripped" == "$heredoc_terminator" ]]; then
                heredoc_terminator=""
            fi
            continue
        fi

        # ---- Continuation of a previous line: skip ----
        if [[ "$in_continuation" == true ]]; then
            case "$stripped" in
                *\\) in_continuation=true ;;
                *)   in_continuation=false ;;
            esac
            continue
        fi

        # ---- Check if this line starts a continuation ----
        case "$stripped" in
            *\\) in_continuation=true ;;
        esac

        # ---- Check for heredoc start ----
        case "$stripped" in
            *'<<'*)
                local _hd_after="${stripped#*<<}"
                _hd_after="${_hd_after#-}"
                _hd_after="${_hd_after#"${_hd_after%%[![:space:]]*}"}"
                case "$_hd_after" in \'*|\"*) _hd_after="${_hd_after#?}" ;; esac
                local _hd_word="${_hd_after%%[!A-Za-z0-9_]*}"
                [[ -n "$_hd_word" ]] && heredoc_terminator="$_hd_word"
                ;;
        esac

        # ---- Normal executable check ----
        # Use if/then (not &&) so the while body always exits 0;
        # otherwise pipefail + set -e kills the script when the
        # last file line is non-executable.
        if _is_executable_line "$stripped"; then
            echo "$line_num"
        fi
    done < "$file"
}

count_executable_lines() {
    local file="$1"
    executable_line_numbers "$file" | wc -l | tr -d ' '
}

# ---------- Generate lcov.info and summary ----------
mkdir -p "$OUTPUT_DIR"
LCOV_FILE="$OUTPUT_DIR/lcov.info"
: > "$LCOV_FILE"

TOTAL_EXECUTABLE=0
TOTAL_HIT=0

# Minimum coverage threshold (override with MPS_MIN_COVERAGE env var)
MIN_COVERAGE="${MPS_MIN_COVERAGE:-90}"

# Arrays for summary table
declare -a SUMMARY_FILES=()
declare -a SUMMARY_EXEC=()
declare -a SUMMARY_HIT=()
declare -a SUMMARY_PCT=()

for src_file in "${SOURCE_FILES[@]}"; do
    [[ -f "$src_file" ]] || continue

    exec_count=$(count_executable_lines "$src_file")
    [[ "$exec_count" -eq 0 ]] && continue

    # Get hit lines for this file
    hit_count=0
    declare -A file_hits=()
    while IFS= read -r entry; do
        line_num="${entry##*:}"
        file_hits[$line_num]=1
    done < <(grep "^${src_file}:" "$HIT_LINES" 2>/dev/null || true)

    # Write lcov record
    echo "SF:${src_file}" >> "$LCOV_FILE"

    while IFS= read -r lnum; do
        if [[ -n "${file_hits[$lnum]:-}" ]]; then
            echo "DA:${lnum},1" >> "$LCOV_FILE"
            hit_count=$((hit_count + 1))
        else
            echo "DA:${lnum},0" >> "$LCOV_FILE"
        fi
    done < <(executable_line_numbers "$src_file")

    echo "LF:${exec_count}" >> "$LCOV_FILE"
    echo "LH:${hit_count}" >> "$LCOV_FILE"
    echo "end_of_record" >> "$LCOV_FILE"

    unset file_hits

    TOTAL_EXECUTABLE=$((TOTAL_EXECUTABLE + exec_count))
    TOTAL_HIT=$((TOTAL_HIT + hit_count))

    if [[ "$exec_count" -gt 0 ]]; then
        pct=$((hit_count * 100 / exec_count))
    else
        pct=0
    fi

    SUMMARY_FILES+=("$src_file")
    SUMMARY_EXEC+=("$exec_count")
    SUMMARY_HIT+=("$hit_count")
    SUMMARY_PCT+=("$pct")
done

# ---------- Compute total ----------
if [[ "$TOTAL_EXECUTABLE" -gt 0 ]]; then
    TOTAL_PCT=$((TOTAL_HIT * 100 / TOTAL_EXECUTABLE))
else
    TOTAL_PCT=0
fi

# ---------- Print terminal summary table ----------
echo ""
echo "Coverage Summary"
echo "================"
echo ""
printf "%-40s %8s %8s %8s\n" "File" "Lines" "Hit" "Cover"
printf "%-40s %8s %8s %8s\n" "----" "-----" "---" "-----"

for i in "${!SUMMARY_FILES[@]}"; do
    printf "%-40s %8s %8s %7s%%\n" \
        "${SUMMARY_FILES[$i]}" \
        "${SUMMARY_EXEC[$i]}" \
        "${SUMMARY_HIT[$i]}" \
        "${SUMMARY_PCT[$i]}"
done

echo ""
printf "%-40s %8s %8s %7s%%\n" "TOTAL" "$TOTAL_EXECUTABLE" "$TOTAL_HIT" "$TOTAL_PCT"
echo ""
echo "LCOV report: ${LCOV_FILE}"

# ---------- Write total coverage for CI consumption ----------
echo "$TOTAL_PCT" > "${OUTPUT_DIR}/total.txt"

# ---------- Write markdown summary for GitHub Actions job summary ----------
{
    echo "## Coverage Summary"
    echo ""
    echo "| File | Lines | Hit | Cover |"
    echo "|------|------:|----:|------:|"
    for i in "${!SUMMARY_FILES[@]}"; do
        echo "| \`${SUMMARY_FILES[$i]}\` | ${SUMMARY_EXEC[$i]} | ${SUMMARY_HIT[$i]} | ${SUMMARY_PCT[$i]}% |"
    done
    echo "| **TOTAL** | **${TOTAL_EXECUTABLE}** | **${TOTAL_HIT}** | **${TOTAL_PCT}%** |"
    echo ""
    echo "_Minimum required: ${MIN_COVERAGE}%_"
} > "${OUTPUT_DIR}/summary.md"

echo "Markdown summary: ${OUTPUT_DIR}/summary.md"

# ---------- Enforce minimum coverage threshold ----------
if [[ "$TOTAL_PCT" -lt "$MIN_COVERAGE" ]]; then
    echo ""
    echo "FAIL: Coverage ${TOTAL_PCT}% is below minimum threshold of ${MIN_COVERAGE}%." >&2
    exit 1
fi
