#!/usr/bin/env bash
set -euo pipefail

# images/generate-index.sh — Generate autoindex HTML pages from manifest and upload to B2
#
# Produces Apache/nginx-style directory listings for the image registry:
#   /index.html                         — Root: lists flavors + manifest.json link
#   /<flavor>/index.html                — Per-flavor: lists versions, [latest] annotation
#   /<flavor>/<version>/index.html      — Per-version: lists arch images + .sha256 sidecars
#
# Usage:
#   ./images/generate-index.sh <manifest-json-file> <bucket-name>
#
# Called automatically by publish.sh and update-manifest.sh after manifest upload.
# Not called from publish.sh --upload-only (no manifest = no index).
#
# Requires: b2 CLI v4, jq

# shellcheck source=lib/publish-common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/publish-common.sh"
publish_init

MANIFEST="${1:?Usage: generate-index.sh <manifest-json-file> <bucket-name>}"
BUCKET="${2:?Usage: generate-index.sh <manifest-json-file> <bucket-name>}"

if [[ ! -f "$MANIFEST" ]]; then
    echo "ERROR: Manifest file not found: $MANIFEST"
    exit 1
fi

TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

# ---------- CSS (shared across all pages) ----------
CSS='
    body { font-family: monospace; margin: 20px; background: #fafafa; color: #333; }
    h1 { font-size: 1.2em; border-bottom: 1px solid #ccc; padding-bottom: 8px; }
    table { border-collapse: collapse; width: 100%; max-width: 900px; }
    th, td { text-align: left; padding: 4px 16px 4px 0; }
    th { border-bottom: 2px solid #ccc; font-size: 0.9em; color: #666; }
    td { border-bottom: 1px solid #eee; }
    a { color: #0366d6; text-decoration: none; }
    a:hover { text-decoration: underline; }
    .tag { font-size: 0.8em; color: #666; margin-left: 8px; }
    address { margin-top: 24px; font-size: 0.85em; color: #999; border-top: 1px solid #ccc; padding-top: 8px; }
'

# ---------- Helper: write HTML header ----------
_html_header() {
    local title="$1"
    local heading="$2"
    cat <<HEADER
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>${title}</title>
<style>${CSS}</style>
</head>
<body>
<h1>${heading}</h1>
HEADER
}

# ---------- Helper: write HTML footer ----------
_html_footer() {
    cat <<'FOOTER'
<address>mps image registry</address>
</body>
</html>
FOOTER
}

# ---------- Helper: upload an index.html to B2 ----------
_upload_index() {
    local local_file="$1"
    local b2_key="$2"

    b2 file upload --content-type "text/html" \
        "${BUCKET}" "$local_file" "$b2_key" >/dev/null
    _b2_cleanup_old_versions "$b2_key"
}

# ---------- Root index: / ----------
_generate_root_index() {
    local outfile="${TMPDIR}/index.html"

    {
        _html_header "Index of /" "Index of /"
        echo '<table>'
        echo '<tr><th>Name</th><th>Description</th></tr>'

        # Flavor directories
        jq -r '.images | to_entries[] | [.key, .value.description] | @tsv' "$MANIFEST" \
        | sort | while IFS=$'\t' read -r name desc; do
            echo "<tr><td><a href=\"${name}/\">${name}/</a></td><td>${desc}</td></tr>"
        done

        echo "<tr><td><a href=\"manifest.json\">manifest.json</a></td><td>Image registry manifest</td></tr>"
        echo '</table>'
        _html_footer
    } > "$outfile"

    echo "  Uploading index.html"
    _upload_index "$outfile" "index.html"
}

# ---------- Per-flavor index: /<flavor>/ ----------
_generate_flavor_index() {
    local flavor="$1"
    local outfile="${TMPDIR}/${flavor}-index.html"

    local latest
    latest="$(jq -r --arg f "$flavor" '.images[$f].latest // ""' "$MANIFEST")"

    {
        _html_header "Index of /${flavor}/" "Index of /${flavor}/"
        echo '<table>'
        echo '<tr><th>Name</th><th>Last Modified</th><th>Description</th></tr>'
        echo "<tr><td><a href=\"../\">../</a></td><td></td><td></td></tr>"

        # Versions (sorted descending by SemVer — newest first)
        jq -r --arg f "$flavor" '
            .images[$f].versions | to_entries[]
            | .key as $ver
            | (.value | to_entries | map(.value.build_date) | sort | last // "-") as $date
            | [$ver, $date]
            | @tsv
        ' "$MANIFEST" | sort -t. -k1,1nr -k2,2nr -k3,3nr | while IFS=$'\t' read -r ver date; do
            local tag=""
            if [[ "$ver" == "$latest" ]]; then
                tag='<span class="tag">[latest]</span>'
            fi
            # Truncate date to just the date portion for display
            local short_date="${date%%T*}"
            echo "<tr><td><a href=\"${ver}/\">${ver}/</a>${tag}</td><td>${short_date}</td><td></td></tr>"
        done

        echo '</table>'
        _html_footer
    } > "$outfile"

    echo "  Uploading ${flavor}/index.html"
    _upload_index "$outfile" "${flavor}/index.html"
}

# ---------- Per-version index: /<flavor>/<version>/ ----------
_generate_version_index() {
    local flavor="$1"
    local version="$2"
    local outfile="${TMPDIR}/${flavor}-${version}-index.html"

    {
        _html_header "Index of /${flavor}/${version}/" "Index of /${flavor}/${version}/"
        echo '<table>'
        echo '<tr><th>Name</th><th>Last Modified</th><th>Size</th></tr>'
        echo "<tr><td><a href=\"../\">../</a></td><td></td><td></td></tr>"

        # Architecture entries
        jq -r --arg f "$flavor" --arg v "$version" '
            .images[$f].versions[$v] // {}
            | to_entries[]
            | [.key, .value.build_date // "-", (.value.file_size // "" | tostring)]
            | @tsv
        ' "$MANIFEST" | sort | while IFS=$'\t' read -r arch date size; do
            local short_date="${date%%T*}"
            local formatted_size
            formatted_size="$(_format_size "$size")"

            # Image file
            echo "<tr><td><a href=\"${arch}.img\">${arch}.img</a></td><td>${short_date}</td><td>${formatted_size}</td></tr>"
            # SHA256 sidecar
            echo "<tr><td><a href=\"${arch}.img.sha256\">${arch}.img.sha256</a></td><td>${short_date}</td><td>-</td></tr>"
            # .meta.json sidecar
            echo "<tr><td><a href=\"${arch}.img.meta.json\">${arch}.img.meta.json</a></td><td>${short_date}</td><td>-</td></tr>"
        done

        echo '</table>'
        _html_footer
    } > "$outfile"

    echo "  Uploading ${flavor}/${version}/index.html"
    _upload_index "$outfile" "${flavor}/${version}/index.html"
}

# ---------- Main ----------
echo "=== Generating index pages ==="

_generate_root_index

# Iterate flavors and versions
jq -r '.images | to_entries[] | .key' "$MANIFEST" | sort | while IFS= read -r flavor; do
    _generate_flavor_index "$flavor"

    jq -r --arg f "$flavor" '.images[$f].versions | keys[]' "$MANIFEST" \
    | while IFS= read -r version; do
        _generate_version_index "$flavor" "$version"
    done
done

echo "=== Index pages complete ==="
