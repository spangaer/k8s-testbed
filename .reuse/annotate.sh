#!/usr/bin/env bash

# SPDX-FileCopyrightText: Jean-Luc Deprez <https://github.com/spangaer>
# SPDX-License-Identifier: MIT

# Add an SPDX header to files without one. Use this, not reuse annotate --recursive, which can't
# exclude: Markdown, .gitignore and plain JSON are left to REUSE.toml, .reuse/ is skipped by
# reuse anyway, and user-data templates are done by hand, as #cloud-config must stay the first
# line.
# usage: annotate.sh <SPDX license> <copyright holder>
set -euo pipefail

license=$1 holder=$2

cd "$(dirname "$0")/.."

files=() justfiles=() jsonc=()
while IFS= read -r -d '' f; do
    # listed but deleted
    [[ -e $f ]] || continue
    # reuse doesn't know justfiles, and takes JSON for uncommentable; only VS Code's JSON is
    # JSONC, other JSON is left to REUSE.toml
    case $f in
        justfile | */justfile | *.just) justfiles+=("$f") ;;
        .devcontainer/*.json | */.devcontainer/*.json | .vscode/*.json | */.vscode/*.json | \
            *.code-workspace) jsonc+=("$f") ;;
        *.json) ;;
        *) files+=("$f") ;;
    esac
done < <(git ls-files -z --cached --others --exclude-standard -- ':!LICENSE' ':!LICENSES' \
    ':!.reuse' ':!*.md' ':!*.gitignore' ':!*user-data.yaml')
# compact: without the default's blank comment line between the tags
args=(--license "$license" --copyright "$holder" --copyright-prefix spdx --exclude-year
    --template compact --skip-existing)
if ((${#files[@]})); then reuse annotate "${args[@]}" --skip-unrecognised "${files[@]}"; fi
if ((${#justfiles[@]})); then reuse annotate "${args[@]}" --style python "${justfiles[@]}"; fi
# reuse would write a .license file for JSON(C), even with --style, so prepend the header here;
# the markers keep reuse from taking the tags below for this file's own
# REUSE-IgnoreStart
for f in "${jsonc[@]}"; do
    grep -q 'SPDX-License-Identifier:' "$f" && continue
    printf '%s\n' "// SPDX-FileCopyrightText: $holder" "// SPDX-License-Identifier: $license" '' |
        cat - "$f" > "$f.tmp"
    mv "$f.tmp" "$f"
    echo "Successfully changed header of $f"
done
# REUSE-IgnoreEnd
