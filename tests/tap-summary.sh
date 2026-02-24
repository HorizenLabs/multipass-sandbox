#!/usr/bin/env bash
# TAP summary filter — reads TAP from stdin, passes it through verbatim,
# then appends a summary block with pass/fail/skip counts.

passed=0
failed=0
skipped=0
failed_lines=()

while IFS= read -r line; do
    printf '%s\n' "$line"

    case "$line" in
        "ok "*)
            if printf '%s' "$line" | grep -q '# skip'; then
                skipped=$((skipped + 1))
            else
                passed=$((passed + 1))
            fi
            ;;
        "not ok "*)
            failed=$((failed + 1))
            failed_lines+=("$line")
            ;;
    esac
done

printf '# ---\n'
printf '# %d passed, %d failed, %d skipped\n' "$passed" "$failed" "$skipped"

if [ "$failed" -gt 0 ]; then
    printf '# FAILED:\n'
    for fl in ${failed_lines[@]+"${failed_lines[@]}"}; do
        printf '#   %s\n' "$fl"
    done
    exit 1
fi

exit 0
