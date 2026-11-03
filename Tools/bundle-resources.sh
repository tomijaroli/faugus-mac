#!/bin/sh
# Copies upstream translations (.po only) and assets into the app bundle.
# Runs as an Xcode post-build phase, before code signing.
set -eu

DEST="${TARGET_BUILD_DIR}/${UNLOCALIZED_RESOURCES_FOLDER_PATH}"
mkdir -p "${DEST}/languages" "${DEST}/assets"

# Upstream catalogs: languages/<lang>/faugus-launcher.po
rsync -a --delete --include='*/' --include='*.po' --exclude='*' \
    "${SRCROOT}/upstream/languages/" "${DEST}/languages/"

# Mac-only catalogs (domain faugus-mac): App/Resources/Localization/faugus-mac/<lang>/faugus-mac.po
if [ -d "${SRCROOT}/App/Resources/Localization/faugus-mac" ]; then
    rsync -a --include='*/' --include='*.po' --exclude='*' \
        "${SRCROOT}/App/Resources/Localization/faugus-mac/" "${DEST}/languages/"
fi

# Upstream icons and sounds (CC BY 4.0, see NOTICE.md and assets/LICENSE).
rsync -a --delete --exclude='meson.build' "${SRCROOT}/upstream/assets/" "${DEST}/assets/"
