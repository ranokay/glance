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
check "release runs on macos-26" grep -q -F "runs-on: macos-26" .github/workflows/release.yaml
check "release uses shared setup" grep -q -F "./.github/actions/setup" .github/workflows/release.yaml
check "setup asserts Xcode 26" grep -q -F "Release builds require Xcode 26" .github/actions/setup/action.yaml
check "pinned rust" grep -q -F 'rust = { version = "1.99.1", mr_boxington = true }' mise.toml
check "pinned mr-boxington" grep -q -F 'mr-boxington = "1.27.0"' mise.toml
check "pinned hk" grep -q -F 'hk = "2.8.1"' mise.toml
check "pinned jactionlint" grep -q -F 'jactionlint = "2.3.0"' mise.toml
check "pinned shellcheck" grep -q -F 'shellcheck = "0.11.0"' mise.toml
check "pinned swiftformat" grep -q -F 'swiftformat = "0.64.1"' mise.toml
check "pinned swiftlint" grep -q -F 'swiftlint = "0.65.1"' mise.toml
check "no latest pins" sh -c "! grep -q -F '= \"latest\"' mise.toml"
count "$PBX" "MARKETING_VERSION = 1.8.2;" 4 "marketing version occurrences"
count "$PBX" "CURRENT_PROJECT_VERSION = 26;" 4 "build version occurrences"
check "README version line" grep -q -F "Version 1.8.2 (build 26)" README.md
check "README bold version line" grep -q -F "Version **1.8.2** (build **26**)" README.md
check "listing version" grep -q -F "Version 1.8.2" AppStore/Listing/Description.txt
exit $fail
