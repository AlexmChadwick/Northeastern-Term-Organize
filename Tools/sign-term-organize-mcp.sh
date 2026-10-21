#!/bin/sh
# Signs term-organize-mcp with the Mac app's signing identity and the plans app group.
# The helper is not app-sandboxed. Ad hoc local builds (CODE_SIGN_IDENTITY empty or "-")
# print a note and exit 0 so a profile-free xcodebuild still succeeds. A team-signed
# Term Organize build must codesign this binary or the build fails.
#
# Team 832J6JB4V7 has to register the app group 832J6JB4V7.com.alexchadwick.termorganize
# for the Mac App ID. Until that group exists in the developer portal, automatic signing fails.
set -eu

ROOT="${SRCROOT:-$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)}"
IDENTITY="${EXPANDED_CODE_SIGN_IDENTITY:-}"

if [ -z "$IDENTITY" ] || [ "$IDENTITY" = "-" ]; then
  echo "note: term-organize-mcp was not signed for team 832J6JB4V7 because CODE_SIGN_IDENTITY is ad hoc or empty. A team-signed Term Organize build signs this helper with app group 832J6JB4V7.com.alexchadwick.termorganize so macOS does not prompt. Register that group for the Mac App ID or signing will fail."
  exit 0
fi

PACKAGE="$ROOT/TermOrganizeKit"
ENTITLEMENTS="$PACKAGE/term-organize-mcp.entitlements"
xcrun --sdk macosx swift build -c release --package-path "$PACKAGE"

BIN="$PACKAGE/.build/release/term-organize-mcp"
if [ ! -x "$BIN" ]; then
  BIN=$(find "$PACKAGE/.build" -type f -name term-organize-mcp -path '*release*' | head -n 1)
fi
if [ -z "$BIN" ] || [ ! -x "$BIN" ]; then
  echo "error: term-organize-mcp binary was not produced" >&2
  exit 1
fi

codesign --force --sign "$IDENTITY" --identifier "com.alexchadwick.termorganize.mcp" --entitlements "$ENTITLEMENTS" "$BIN"
if [ -n "${BUILT_PRODUCTS_DIR:-}" ]; then
  cp "$BIN" "$BUILT_PRODUCTS_DIR/term-organize-mcp"
  codesign --force --sign "$IDENTITY" --identifier "com.alexchadwick.termorganize.mcp" --entitlements "$ENTITLEMENTS" "$BUILT_PRODUCTS_DIR/term-organize-mcp"
fi
echo "signed term-organize-mcp as com.alexchadwick.termorganize.mcp"
