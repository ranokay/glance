#!/bin/bash
# Post-embed fixup for the Sparkle framework (scripts referenced by the
# "Embed Sparkle" build phase).
#
# - The SPM binary artifact ships a single universal arm64+x86_64 macos
#   variant; Glance is arm64-only, so x86_64 slices are stripped from every
#   nested Mach-O and every binary is re-signed ad hoc from the inside out
#   (per the Sparkle sandboxing guide for non-archive distributions).
set -e

SPARKLE_FRAMEWORK="${TARGET_BUILD_DIR}/${FRAMEWORKS_FOLDER_PATH}/Sparkle.framework"

if [ ! -d "$SPARKLE_FRAMEWORK" ]; then
	exit 0
fi

IDENTITY="${CODE_SIGN_IDENTITY:--}"

strip_x86_64() {
	local macho="$1"
	local info temp
	info="$(lipo -info "$macho" 2>/dev/null)" || return 0
	case "$info" in
		*x86_64*arm64*|*arm64*x86_64*)
			temp="$(mktemp)"
			if lipo -remove x86_64 "$macho" -output "$temp"; then
				mv -f "$temp" "$macho"
			else
				rm -f "$temp"
				echo "error: could not strip x86_64 from $macho" >&2
				exit 1
			fi
			;;
		*) ;;
	esac
}

while IFS= read -r -d '' macho; do
	strip_x86_64 "$macho"
done < <(find "$SPARKLE_FRAMEWORK" -type f -print0)

codesign -f -s "$IDENTITY" -o runtime --preserve-metadata=entitlements \
	"$SPARKLE_FRAMEWORK/Versions/B/XPCServices/Installer.xpc"
codesign -f -s "$IDENTITY" -o runtime --preserve-metadata=entitlements \
	"$SPARKLE_FRAMEWORK/Versions/B/XPCServices/Downloader.xpc"
codesign -f -s "$IDENTITY" -o runtime --preserve-metadata=entitlements \
	"$SPARKLE_FRAMEWORK/Versions/B/Autoupdate"
codesign -f -s "$IDENTITY" -o runtime --preserve-metadata=entitlements \
	"$SPARKLE_FRAMEWORK/Versions/B/Updater.app"
codesign -f -s "$IDENTITY" -o runtime --preserve-metadata=entitlements \
	"$SPARKLE_FRAMEWORK"

exit 0
