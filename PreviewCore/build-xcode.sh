#!/bin/sh

set -eu

if [ "$(uname -m)" != "arm64" ]; then
	echo "Apple silicon is required to build PreviewCore" >&2
	exit 1
fi

PROJECT_ROOT="${PROJECT_DIR:-$(cd "$(dirname "$0")/.." && pwd)}"
CORE_ROOT="$PROJECT_ROOT/PreviewCore"
TARGET="aarch64-apple-darwin"
OUTPUT_DIRECTORY="$CORE_ROOT/build"
export CARGO_TARGET_DIR="$CORE_ROOT/target"
export MACOSX_DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-26.0}"

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
PROFILE_ARGUMENT=""
case "${CONFIGURATION:-Debug}" in
	Release|Profile)
		PROFILE="release"
		PROFILE_ARGUMENT="--release"
		;;
esac

"$MISE_BIN" exec -- cargo build \
	--locked \
	--manifest-path "$CORE_ROOT/Cargo.toml" \
	--target "$TARGET" \
	$PROFILE_ARGUMENT

/usr/bin/install -d "$OUTPUT_DIRECTORY"
/usr/bin/install -m 0644 \
	"$CARGO_TARGET_DIR/$TARGET/$PROFILE/libglance_preview_core.a" \
	"$OUTPUT_DIRECTORY/libglance_preview_core.a"
