#!/bin/bash
# Prints the CHANGELOG.md entries of one version (without the "## [x.y.z]" heading line).
# Fails when the version has no section or the section is empty.
#
# Usage: scripts/changelog_notes.sh 0.2.0 [CHANGELOG.md]
set -euo pipefail

version="${1:?usage: changelog_notes.sh VERSION [CHANGELOG.md]}"
file="${2:-$(dirname "$0")/../CHANGELOG.md}"

# Plain string comparison instead of a regex, so the dots in 0.2.0 are not wildcards and
# 0.2.0 does not match 0.2.01. Accepted headings: "## [0.2.0] - date", "## [0.2.0]", "## 0.2.0".
notes="$(V="$version" awk '
    /^## / {
        on = (index($0, "## [" ENVIRON["V"] "]") == 1 || $0 == "## " ENVIRON["V"] || index($0, "## " ENVIRON["V"] " ") == 1)
        next
    }
    on' "$file")"

if [[ -z "$(printf '%s' "$notes" | tr -d '[:space:]')" ]]; then
    echo "error: $file has no notes for version $version. Add a section '## [$version] - YYYY-MM-DD' with entries." >&2
    exit 1
fi
printf '%s\n' "$notes"
