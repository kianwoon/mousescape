#!/bin/zsh
# Re-sign a locally built Mousecape.app with a stable self-signed identity so
# macOS TCC (Accessibility) keys the grant on identifier + certificate leaf
# instead of the per-build cdhash an ad-hoc signature produces. Grant once;
# it survives rebuilds.
#
# Usage: Tools/sign-dev.sh /path/to/Mousecape.app
# Identity: MC_SIGN_IDENTITY (default GlanceDev) — any valid codesigning identity
#           listed by `security find-identity -v -p codesigning`.
set -euo pipefail
APP="${1:?usage: $0 /path/to/Mousecape.app}"
IDENTITY="${MC_SIGN_IDENTITY:-GlanceDev}"

# Inside-out: deepest nested bundles first, then the outer app.
find "$APP/Contents" \( -name '*.xpc' -o -name '*.app' -o -name '*.framework' \
                        -o -name '*.dylib' -o -name '*.appex' \) |
  awk '{ print gsub("/", "/") "\t" $0 }' | sort -rn | cut -f2- |
  while IFS= read -r bundle; do
    codesign --force --sign "$IDENTITY" --preserve-metadata=entitlements,flags "$bundle"
  done
codesign --force --sign "$IDENTITY" --preserve-metadata=entitlements,flags "$APP"
codesign --verify --strict --deep "$APP"
codesign -d -r- "$APP/Contents/Library/LoginItems/MousecapeHelper.app" 2>&1 | tail -1
