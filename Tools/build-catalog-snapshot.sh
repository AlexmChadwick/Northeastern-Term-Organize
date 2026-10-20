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
# macOS has Apple's LZFSE in Foundation. Linux swiftc emits plain JSON; the file is
# compressed afterwards with the lzfse reference library, which decodes with the same
# LZFSE stream the apps and the Linux/Windows ports already read.
if command -v xcrun >/dev/null 2>&1 && xcrun --sdk macosx --show-sdk-path >/dev/null 2>&1; then
  xcrun --sdk macosx swiftc -O -swift-version 5 \
    "${SOURCES[@]}" "$ROOT/Tools/CatalogSnapshot/main.swift" \
    -o "$BUILD_DIR/catalog-snapshot"
  COMPRESS_JSON=0
else
  command -v swiftc >/dev/null 2>&1 || { echo "swiftc not found (Xcode on macOS, or a Swift toolchain on Linux)." >&2; exit 1; }
  command -v lzfse >/dev/null 2>&1 || { echo "lzfse not found. Install https://github.com/lzfse/lzfse so the snapshot can be compressed." >&2; exit 1; }
  swiftc -O -swift-version 5 \
    "${SOURCES[@]}" "$ROOT/Tools/CatalogSnapshot/main.swift" \
    -o "$BUILD_DIR/catalog-snapshot"
  COMPRESS_JSON=1
fi

TERM_CODE="${1:-}"
if [[ -z "$TERM_CODE" || "$TERM_CODE" == --* ]]; then
  TERM_CODE="$(curl -s 'https://nubanner.neu.edu/StudentRegistrationSsb/ssb/classSearch/getTerms?offset=1&max=1&searchTerm=' \
    | /usr/bin/python3 -c 'import json,sys; print(json.load(sys.stdin)[0]["code"])')"
else
  shift
fi

echo "Building snapshot for term $TERM_CODE…"
"$BUILD_DIR/catalog-snapshot" "$TERM_CODE" --out "$ROOT/NEUClassSearch/Resources/Catalog" "$@"

OUT_FILE="$ROOT/NEUClassSearch/Resources/Catalog/term-${TERM_CODE}.catalog"
if [[ "${COMPRESS_JSON:-0}" == 1 && -f "$OUT_FILE" ]]; then
  first="$(head -c 1 "$OUT_FILE" || true)"
  if [[ "$first" == "{" ]]; then
    echo "Compressing $OUT_FILE with lzfse…"
    tmp="$(mktemp)"
    lzfse -encode -i "$OUT_FILE" -o "$tmp"
    mv "$tmp" "$OUT_FILE"
  fi
fi
