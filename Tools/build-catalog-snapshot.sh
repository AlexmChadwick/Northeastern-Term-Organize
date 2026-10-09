#!/bin/bash
#
# build-catalog-snapshot.sh — Term Organize
#
# Copyright (C) 2026 Term Organize contributors.
# SPDX-License-Identifier: AGPL-3.0-only
# See LICENSE and NOTICE.md in the project root for details.
#
# Compiles the catalog-snapshot tool from the app's shared Core sources and
# uses it to regenerate the offline catalog bundled with the app.
#
#   Tools/build-catalog-snapshot.sh [term-code] [--concurrency N]
#
# The default term is the newest term Banner lists. Output is written to
# NEUClassSearch/Resources/Catalog/term-<code>.catalog.
#
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="${TMPDIR:-/tmp}/neu-catalog-snapshot"
mkdir -p "$BUILD_DIR"

SOURCES=()
while IFS= read -r -d '' file; do SOURCES+=("$file"); done < <(find "$ROOT/NEUClassSearch/Core" -name '*.swift' -print0)

echo "Compiling catalog-snapshot (${#SOURCES[@]} core files)…"
xcrun --sdk macosx swiftc -O -swift-version 5 \
  "${SOURCES[@]}" "$ROOT/Tools/CatalogSnapshot/main.swift" \
  -o "$BUILD_DIR/catalog-snapshot"

TERM_CODE="${1:-}"
if [[ -z "$TERM_CODE" || "$TERM_CODE" == --* ]]; then
  TERM_CODE="$(curl -s 'https://nubanner.neu.edu/StudentRegistrationSsb/ssb/classSearch/getTerms?offset=1&max=1&searchTerm=' \
    | /usr/bin/python3 -c 'import json,sys; print(json.load(sys.stdin)[0]["code"])')"
else
  shift
fi

echo "Building snapshot for term $TERM_CODE…"
"$BUILD_DIR/catalog-snapshot" "$TERM_CODE" --out "$ROOT/NEUClassSearch/Resources/Catalog" "$@"
