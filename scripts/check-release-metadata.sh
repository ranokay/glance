#!/bin/sh
# Release-metadata lint: version/build/platform/pin strings live here, not in unit tests.
# Fails fast in CI; update the literals here when intentionally bumping versions.
set -eu
cd "$(dirname "$0")/.."
fail=0
check() { # $1 = description, rest = grep args
	desc=$1; shift
	if "$@" >/dev/null 2>&1; then
		echo "ok: $desc"
	else
		echo "FAIL: $desc" >&2
		fail=1
	fi
}
count() { # $1 = file, $2 = literal, $3 = expected, $4 = description
	n=$(grep -c -F "$2" "$1" || true)
	if [ "$n" = "$3" ]; then
		echo "ok: $4 ($n)"
	else
		echo "FAIL: $4 (found $n, want $3)" >&2
		fail=1
	fi
}
PBX=Glance.xcodeproj/project.pbxproj
check "pbxproj pins macOS 26 target" grep -q -F "MACOSX_DEPLOYMENT_TARGET = 26.0;" "$PBX"
check "pbxproj has no macOS 15 target" sh -c "! grep -q -F 'MACOSX_DEPLOYMENT_TARGET = 15.0;' '$PBX'"
check "rust build script defaults to macOS 26" grep -q -F "MACOSX_DEPLOYMENT_TARGET:-26.0" PreviewCore/build-xcode.sh
check "release runs on macos-26" grep -q -F "runs-on: macos-26" .github/workflows/release.yml
check "release uses shared setup" grep -q -F "./.github/actions/setup" .github/workflows/release.yml
check "setup asserts Xcode 26" grep -q -F "Release builds require Xcode 26" .github/actions/setup/action.yml
check "pinned rust" grep -q -F 'rust = "1.97.1"' mise.toml
check "pinned swiftformat" grep -q -F 'swiftformat = "0.61.1"' mise.toml
check "pinned swiftlint" grep -q -F 'swiftlint = "0.63.3"' mise.toml
check "no latest pins" sh -c "! grep -q -F '= \"latest\"' mise.toml"
count "$PBX" "MARKETING_VERSION = 1.6.2;" 4 "marketing version occurrences"
count "$PBX" "CURRENT_PROJECT_VERSION = 22;" 4 "build version occurrences"
check "README version line" grep -q -F "Version 1.6.2 (build 22)" README.md
check "README bold version line" grep -q -F "Version **1.6.2** (build **22**)" README.md
check "listing version" grep -q -F "Version 1.6.2" AppStore/Listing/Description.txt
exit $fail
