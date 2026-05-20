#!/usr/bin/env bash

set -euo pipefail

if [ $# -lt 1 ]; then
  echo "Usage: $0 <issuer-id>"
  exit 1
fi

ISSUER_ID="$1"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
VERSION="$(/usr/bin/plutil -extract CFBundleShortVersionString raw "$ROOT_DIR/Info.plist")"
TAG="v${VERSION}"
ZIP_PATH="$ROOT_DIR/release/AISwitcher-v${VERSION}-signed.zip"

extract_changelog_section() {
  local heading="$1"
  awk -v heading="$heading" '
    function matches_heading(line, heading) {
      prefix = "## [" heading "]"
      return line == prefix || index(line, prefix " - ") == 1
    }
    matches_heading($0, heading) { capture=1; next }
    /^## \[/ && capture { exit }
    capture { print }
  ' "$ROOT_DIR/CHANGELOG.md"
}

is_blank() {
  [ -z "$(printf "%s" "$1" | tr -d '[:space:]')" ]
}

extract_changelog() {
  local content
  content="$(extract_changelog_section "$VERSION")"
  if is_blank "$content"; then
    content="$(extract_changelog_section "Unreleased")"
  fi
  printf "%s\n" "$content"
}

CHANGELOG_CONTENT="$(extract_changelog)"
if is_blank "$CHANGELOG_CONTENT"; then
  echo "❌ CHANGELOG.md entry for ${TAG} or Unreleased not found."
  exit 1
fi

echo "==> Running tests"
cd "$ROOT_DIR"
swift test

echo "==> Building signed release"
"$ROOT_DIR/scripts/build_signed.sh" "$ISSUER_ID"

if [ ! -f "$ZIP_PATH" ]; then
  echo "❌ Signed asset not found at $ZIP_PATH"
  exit 1
fi

if git rev-parse "$TAG" >/dev/null 2>&1; then
  echo "==> Tag $TAG already exists"
else
  echo "==> Creating tag $TAG"
  git tag "$TAG"
  git push origin "$TAG"
fi

TMP_NOTES="$(mktemp)"
trap 'rm -f "$TMP_NOTES"' EXIT
{
  echo "## AI Switcher ${TAG}"
  echo
  printf "%s\n" "$CHANGELOG_CONTENT"
  echo
  echo "### Release"
  echo "- Developer ID signed"
  echo "- Apple notarized"
  echo "- Asset: \`$(basename "$ZIP_PATH")\`"
} > "$TMP_NOTES"

if gh release view "$TAG" >/dev/null 2>&1; then
  echo "==> Updating existing GitHub release $TAG"
  gh release upload "$TAG" "$ZIP_PATH" --clobber
  gh release edit "$TAG" --title "$TAG" --notes-file "$TMP_NOTES"
else
  echo "==> Creating GitHub release $TAG"
  gh release create "$TAG" "$ZIP_PATH" --title "$TAG" --notes-file "$TMP_NOTES"
fi

echo "✅ Release published: $(gh release view "$TAG" --json url -q .url)"
