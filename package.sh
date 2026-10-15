#!/usr/bin/env bash
set -euo pipefail

cd -- "$(dirname -- "${BASH_SOURCE[0]}")"

# Build a fresh archive from runtime sources only, never compiled schemas.
archive="$(python3 -c 'import json; print(json.load(open("metadata.json"))["uuid"])').shell-extension.zip"
staging=$(mktemp -d)
trap 'rm -rf -- "$staging"' EXIT

glib-compile-schemas --strict --dry-run schemas
zip -q "$staging/$archive" ./*.js metadata.json stylesheet.css LICENSE schemas/*.gschema.xml
mv -- "$staging/$archive" "$archive"
echo "Created $archive"
