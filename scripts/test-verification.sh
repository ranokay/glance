#!/bin/sh
# Exercise launch-verification boundaries without launching Glance.
set -eu

repo_root="$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd -P)"
launch_script="$repo_root/scripts/check-app-launch.sh"
work_dir="$(mktemp -d "${TMPDIR:-/tmp}/glance-verification-tests.XXXXXX")"
work_dir="$(CDPATH='' cd -- "$work_dir" && pwd -P)"
trap 'rm -rf "$work_dir"' EXIT
trap 'exit 1' HUP INT TERM
mkdir "$work_dir/bin" "$work_dir/tmp" "$work_dir/Glance.app"
mkdir -p "$work_dir/Glance.app/Contents/MacOS"
printf '#!/bin/sh\nexit 99\n' > "$work_dir/Glance.app/Contents/MacOS/Glance"
chmod +x "$work_dir/Glance.app/Contents/MacOS/Glance"

cat > "$work_dir/bin/open" <<'OPEN'
#!/bin/sh
set -eu
printf 'open\n' >> "$TEST_TRACE"
if [ "$#" -ne 11 ] || [ "$1" != -n ] || [ "$2" != -g ] || [ "$3" != -W ] ||
	[ "$4" != --stdout ] || [ "$6" != --stderr ] || [ "$8" != "$TEST_BUNDLE" ] ||
	[ "$9" != --args ] || [ "${10}" != --verify-launch ] || [ -z "${11}" ]; then
	printf 'UNHANDLED open operation\n' >> "$TEST_TRACE"
	exit 99
fi
stdout="$5"
token="${11}"
case "$OPEN_MODE" in
	valid) printf 'GLANCE_LAUNCH_OK %s\n' "$token" > "$stdout" ;;
	missing) : ;;
	wrong) printf 'GLANCE_LAUNCH_OK stale-token\n' > "$stdout" ;;
	failed) printf 'GLANCE_LAUNCH_FAILED %s\n' "$token" > "$stdout" ;;
	launch-error) exit 13 ;;
	receipt-error) printf 'GLANCE_LAUNCH_OK %s\n' "$token" > "$stdout"; exit 14 ;;
	hang) exec sleep 30 ;;
	receipt-hang) printf 'GLANCE_LAUNCH_OK %s\n' "$token" > "$stdout"; exec sleep 30 ;;
	*) exit 99 ;;
esac
OPEN

# Cleanup must not search for or signal any real user process.
printf '#!/bin/sh\nexit 1\n' > "$work_dir/bin/pgrep"
chmod +x "$work_dir/bin/open" "$work_dir/bin/pgrep"
PATH="$work_dir/bin:$PATH"
TMPDIR="$work_dir/tmp"
TEST_BUNDLE="$work_dir/Glance.app"
export PATH TMPDIR TEST_BUNDLE
case_count=0

start_case() {
	case_count=$((case_count + 1))
	case_label="$1"
	case_dir="$work_dir/case-$case_count"
	mkdir "$case_dir"
	TEST_TRACE="$case_dir/trace"
	OPEN_MODE=valid
	APP_NAME=Glance
	LAUNCH_TIMEOUT=3
	export TEST_TRACE OPEN_MODE APP_NAME LAUNCH_TIMEOUT
	: > "$TEST_TRACE"
}
fail() {
	echo "FAIL: $case_label: $*" >&2
	if [ -f "$case_dir/output" ]; then tail -15 "$case_dir/output" >&2; fi
	exit 1
}
expect_success() {
	if ! "$@" > "$case_dir/output" 2>&1; then fail 'expected success'; fi
	if grep -q '^UNHANDLED' "$TEST_TRACE"; then fail 'unexpected external operation'; fi
}
expect_failure() {
	if "$@" > "$case_dir/output" 2>&1; then fail 'expected failure'; fi
	if grep -q '^UNHANDLED' "$TEST_TRACE"; then fail 'unexpected external operation'; fi
}
expect_no_call() {
	if grep -q "$1" "$TEST_TRACE"; then fail "unexpected $1 operation"; fi
}

start_case 'matching launch receipt and successful exit'
expect_success sh "$launch_script" "$work_dir/Glance.app"
grep -q '^OK:' "$case_dir/output" || fail 'missing success verdict'

for launch_mode in missing wrong failed launch-error receipt-error hang receipt-hang; do
	start_case "launch $launch_mode"
	OPEN_MODE="$launch_mode"
	LAUNCH_TIMEOUT=1
	expect_failure sh "$launch_script" "$work_dir/Glance.app"
done
for invalid_timeout in 0 -1 121 abc 1.5; do
	start_case "invalid timeout $invalid_timeout"
	LAUNCH_TIMEOUT="$invalid_timeout"
	expect_failure sh "$launch_script" "$work_dir/Glance.app"
	expect_no_call open
done
start_case 'missing app bundle'
expect_failure sh "$launch_script" "$work_dir/missing.app"
expect_no_call open

echo "Verification script tests passed: $case_count cases"
