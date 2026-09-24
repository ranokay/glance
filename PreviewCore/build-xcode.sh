#!/bin/sh

set -eu

if [ "$(uname -m)" != "arm64" ]; then
	echo "Apple silicon is required to build PreviewCore" >&2
	exit 1
fi

PROJECT_ROOT="${PROJECT_DIR:-$(cd "$(dirname "$0")/.." && pwd)}"
CORE_ROOT="$PROJECT_ROOT/PreviewCore"
TARGET="aarch64-apple-darwin"
OUTPUT_DIRECTORY="$CORE_ROOT/build/${CONFIGURATION:-Debug}"
export CARGO_TARGET_DIR="$CORE_ROOT/target"
# Xcode 27 (LD 27037.1, SDK 27.0) mis-links release proc-macro dylibs when
# MACOSX_DEPLOYMENT_TARGET is 26.0 or newer: dyld then rejects them with
# "mis-aligned LINKEDIT string pool" and the release build fails with
# "can't find crate for zerofrom_derive/thiserror_impl/serde_derive".
# Pin the Rust/C build to 11.0 (Rust's default, known-good with LTO thin);
# the final minos 26.0 is still enforced by Xcode when it links this
# staticlib into the app bundle (verified by `mise run verify:app`),
# and 11.0 objects link into the 26.0 app without "built for newer"
# warnings.
export MACOSX_DEPLOYMENT_TARGET="11.0"

MISE_BIN="${MISE_BIN:-}"
if [ -z "$MISE_BIN" ]; then
	if command -v mise >/dev/null 2>&1; then
		MISE_BIN="$(command -v mise)"
	elif [ -x "$HOME/.local/bin/mise" ]; then
		MISE_BIN="$HOME/.local/bin/mise"
	elif [ -x "/opt/homebrew/bin/mise" ]; then
		MISE_BIN="/opt/homebrew/bin/mise"
	elif [ -x "/usr/local/bin/mise" ]; then
		MISE_BIN="/usr/local/bin/mise"
	fi
fi
if [ -z "$MISE_BIN" ]; then
	echo "mise is required to build PreviewCore with the pinned Rust toolchain" >&2
	exit 1
fi

export MISE_TRUSTED_CONFIG_PATHS="$PROJECT_ROOT${MISE_TRUSTED_CONFIG_PATHS:+:$MISE_TRUSTED_CONFIG_PATHS}"

PROFILE="debug"
set --
case "${CONFIGURATION:-Debug}" in
	Release|Profile)
		PROFILE="release"
		set -- --release
		;;
esac

if ! "$MISE_BIN" exec -- rustup target list --installed | /usr/bin/grep -Fxq "$TARGET"; then
	echo "Rust target $TARGET is not installed; run 'mise exec -- rustup target add $TARGET'" >&2
	exit 1
fi

"$MISE_BIN" exec -- cargo build \
	--locked \
	--manifest-path "$CORE_ROOT/Cargo.toml" \
	--target "$TARGET" \
	"$@"

/usr/bin/install -d "$OUTPUT_DIRECTORY"
/usr/bin/install -m 0644 \
	"$CARGO_TARGET_DIR/$TARGET/$PROFILE/libglance_preview_core.a" \
	"$OUTPUT_DIRECTORY/libglance_preview_core.a"
