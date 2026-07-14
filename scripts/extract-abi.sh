#!/usr/bin/env bash
# Extracts ABI JSON for every non-blacklisted contract file under <input-dir> into <output-dir>
# via `forge inspect`. Assumes one contract per file with matching filename and contract name.
set -euo pipefail

if [ $# -lt 2 ]; then
    echo "usage: $0 <input-dir> <output-dir>" >&2
    exit 1
fi

IN_DIR="$1"
OUT_DIR="$2"

BLACKLIST_REGEX='(^|/)mocks?/|(^|/)tests?/|\.t\.sol$|\.s\.sol$'

rm -rf "$OUT_DIR"
mkdir -p "$OUT_DIR"

find "$IN_DIR" -name "*.sol" -type f | while read -r file; do
    if [[ "$file" =~ $BLACKLIST_REGEX ]]; then
        echo "skip  ${file}"
        continue
    fi
    name=$(basename "$file" .sol)
    forge inspect "$file:$name" abi --json > "${OUT_DIR}/${name}.json"
    echo "wrote ${OUT_DIR}/${name}.json"
done
