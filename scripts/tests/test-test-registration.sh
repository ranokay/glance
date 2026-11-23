#!/bin/sh
# Check real target membership, not just a matching filename in the project.
set -eu
repo_root="$(CDPATH='' cd -- "$(dirname -- "$0")/../.." && pwd -P)"
checker="$repo_root/scripts/check-test-registration.swift"
work_dir="$(mktemp -d "${TMPDIR:-/tmp}/glance-registration-tests.XXXXXX")"
trap 'rm -rf "$work_dir"' EXIT
trap 'exit 1' HUP INT TERM
case_count=0

new_project() {
	case_count=$((case_count + 1))
	case_dir="$work_dir/case-$case_count"
	mkdir -p "$case_dir/Glance.xcodeproj" "$case_dir/GlanceTests" "$case_dir/Other"
	printf 'import XCTest\n' > "$case_dir/GlanceTests/Case.swift"
}

write_project() {
	cat > "$case_dir/Glance.xcodeproj/project.pbxproj" <<PBX_FIXTURE
{
 archiveVersion = 1;
 objectVersion = 54;
 objects = {
  PROJECT = {isa = PBXProject; mainGroup = ROOT; targets = (${5:-TEST_TARGET, APP_TARGET});};
  ROOT = {isa = PBXGroup; children = (TESTS, OTHER); sourceTree = "<group>";};
  TESTS = {isa = PBXGroup; children = (TEST_FILE, NESTED); path = GlanceTests; sourceTree = "<group>";};
  OTHER = {isa = PBXGroup; children = (OTHER_FILE); path = Other; sourceTree = "<group>";};
  NESTED = {isa = PBXGroup; children = (NESTED_FILE); path = Nested; sourceTree = "<group>";};
  TEST_FILE = {isa = PBXFileReference; path = Case.swift; sourceTree = "<group>";};
  OTHER_FILE = {isa = PBXFileReference; path = Case.swift; sourceTree = "<group>";};
  NESTED_FILE = {isa = PBXFileReference; path = "Nested Tests.swift"; sourceTree = "<group>";};
  TEST_BUILD = {isa = PBXBuildFile; fileRef = TEST_FILE; ${3:-}};
  OTHER_BUILD = {isa = PBXBuildFile; fileRef = OTHER_FILE;};
  NESTED_BUILD = {isa = PBXBuildFile; fileRef = NESTED_FILE;};
  TEST_TARGET = {isa = PBXNativeTarget; name = ${4:-GlanceTests}; buildPhases = (TEST_SOURCES);};
  APP_TARGET = {isa = PBXNativeTarget; name = Glance; buildPhases = (APP_SOURCES);};
  TEST_SOURCES = {isa = PBXSourcesBuildPhase; files = ($1);};
  APP_SOURCES = {isa = PBXSourcesBuildPhase; files = ($2);};
 };
 rootObject = PROJECT;
}
PBX_FIXTURE
}

expect_success() {
	if ! xcrun swift "$checker" "$case_dir/Glance.xcodeproj/project.pbxproj" \
		"$case_dir/GlanceTests" > "$case_dir/output" 2>&1; then
		cat "$case_dir/output" >&2
		exit 1
	fi
}

expect_failure() {
	if xcrun swift "$checker" "$case_dir/Glance.xcodeproj/project.pbxproj" \
		"$case_dir/GlanceTests" > "$case_dir/output" 2>&1; then
		echo "Expected registration failure for case $case_count" >&2
		exit 1
	fi
	grep -Fq "$1" "$case_dir/output"
}

new_project
write_project TEST_BUILD ''
expect_success

new_project
write_project TEST_BUILD ''
printf 'import XCTest\n' > "$case_dir/GlanceTests/Orphan.swift"
expect_failure Orphan.swift

new_project
write_project '' ''
expect_failure Case.swift

new_project
write_project '' TEST_BUILD
expect_failure Case.swift

new_project
write_project OTHER_BUILD ''
printf 'import XCTest\n' > "$case_dir/Other/Case.swift"
expect_failure /GlanceTests/Case.swift

new_project
write_project 'TEST_BUILD, NESTED_BUILD' ''
mkdir "$case_dir/GlanceTests/Nested"
printf 'import XCTest\n' > "$case_dir/GlanceTests/Nested/Nested Tests.swift"
expect_success

new_project
write_project TEST_BUILD ''
mkdir "$case_dir/GlanceTests/TestFiles"
printf 'let preview = true\n' > "$case_dir/GlanceTests/TestFiles/fixture.swift"
expect_success

new_project
write_project TEST_BUILD '' 'platformFilter = ios;'
expect_failure Case.swift

new_project
write_project TEST_BUILD '' '' OtherTests
expect_failure 'exactly one GlanceTests target'

new_project
write_project TEST_BUILD '' '' GlanceTests APP_TARGET
expect_failure 'exactly one GlanceTests target'

new_project
write_project TEST_BUILD ''
mv "$case_dir/GlanceTests" "$case_dir/MissingTests"
expect_failure 'Test source directory does not exist'

echo "Test registration checker tests passed: $case_count cases"
