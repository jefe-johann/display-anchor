#!/usr/bin/env bash
set -euo pipefail

if [[ "${ACTION:-build}" == "clean" ]]; then
    exit 0
fi

if [[ -z "${SRCROOT:-}" || -z "${TARGET_BUILD_DIR:-}" || -z "${FULL_PRODUCT_NAME:-}" ]]; then
    echo "warning: Missing Xcode build environment; skipping dist sync."
    exit 0
fi

SOURCE_APP="$TARGET_BUILD_DIR/$FULL_PRODUCT_NAME"
DIST_DIR="$SRCROOT/dist"
DIST_APP="$DIST_DIR/$FULL_PRODUCT_NAME"

if [[ ! -d "$SOURCE_APP" ]]; then
    echo "warning: Built app not found at $SOURCE_APP; skipping dist sync."
    exit 0
fi

case "$DIST_APP" in
    "$SRCROOT"/dist/*.app) ;;
    *)
        echo "error: Refusing to remove unexpected dist path: $DIST_APP" >&2
        exit 1
        ;;
esac

mkdir -p "$DIST_DIR"
rm -rf "$DIST_APP"
/usr/bin/ditto "$SOURCE_APP" "$DIST_APP"

echo "Updated $DIST_APP"
