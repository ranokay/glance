#!/bin/sh
# Exercise verification boundaries without launching Glance or contacting GitHub.
set -eu

repo_root="$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd -P)"
launch_script="$repo_root/scripts/check-app-launch.sh"
capture_script="$repo_root/scripts/attach-capture.sh"
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
cat > "$work_dir/bin/gh" <<'GH'
#!/bin/sh
set -eu
bad_call() {
	printf 'UNHANDLED gh operation\n' >> "$TEST_TRACE"
	exit 99
}
if [ "$#" -eq 7 ] && [ "$1" = issue ] && [ "$2" = view ] &&
	[ "$3" = 42 ] && [ "$4" = --repo ] && [ "$5" = ranokay/glance ] &&
	[ "$6" = --json ] && [ "$7" = number ]; then
	printf 'issue-view\n' >> "$TEST_TRACE"
	[ "$GH_MODE" != issue-error ] || exit 20
	printf '{"number":42}\n'
	exit 0
fi
if [ "$#" -eq 2 ] && [ "$1" = api ] &&
	[ "$2" = repos/ranokay/glance/branches/verification-captures ]; then
	printf 'branch-read\n' >> "$TEST_TRACE"
	case "$GH_MODE" in
		branch-auth) echo 'HTTP 403: access denied' >&2; exit 21 ;;
		branch-missing) echo 'HTTP 404: not found' >&2; exit 22 ;;
		branch-race|branch-create-error|branch-recheck-auth)
			if ! grep -q '^branch-create$' "$TEST_TRACE"; then
				echo 'HTTP 404: not found' >&2
				exit 22
			fi
			case "$GH_MODE" in
				branch-create-error) echo 'HTTP 404: not found' >&2; exit 22 ;;
				branch-recheck-auth) echo 'HTTP 403: access denied' >&2; exit 21 ;;
			esac
			;;
	esac
	printf '{}\n'
	exit 0
fi
if [ "$#" -eq 4 ] && [ "$1" = api ] &&
	[ "$2" = repos/ranokay/glance/branches/develop ] &&
	[ "$3" = --jq ] && [ "$4" = .commit.sha ]; then
	printf 'base-read\n' >> "$TEST_TRACE"
	printf '%s\n' "$TEST_SHA"
	exit 0
fi
if [ "$#" -eq 8 ] && [ "$1" = api ] && [ "$2" = --method ] &&
	[ "$3" = POST ] && [ "$4" = repos/ranokay/glance/git/refs ] &&
	[ "$5" = -f ] && [ "$6" = ref=refs/heads/verification-captures ] &&
	[ "$7" = -f ] && [ "$8" = "sha=$TEST_SHA" ]; then
	printf 'branch-create\n' >> "$TEST_TRACE"
	case "$GH_MODE" in
		branch-race) echo 'HTTP 422: Reference already exists' >&2; exit 25 ;;
		branch-create-error|branch-recheck-auth) echo 'HTTP 403: cannot create reference' >&2; exit 25 ;;
	esac
	printf '{}\n'
	exit 0
fi
if [ "$#" -eq 12 ] && [ "$1" = api ] && [ "$2" = --method ] && [ "$3" = PUT ]; then
	shift 3
	case "$1" in repos/ranokay/glance/contents/docs/verification/issue-42/*.png) ;; *) bad_call ;; esac
	shift
	[ "$1" = -f ] || bad_call
	case "$2" in 'message=Add verification capture '*) ;; *) bad_call ;; esac
	shift 2
	[ "$1" = -f ] && [ "$2" = branch=verification-captures ] || bad_call
	shift 2
	[ "$1" = -F ] || bad_call
	case "$2" in content=@*) content_file="${2#content=@}" ;; *) bad_call ;; esac
	shift 2
	[ "$1" = --jq ] && [ "$2" = .commit.sha ] || bad_call
	[ -f "$content_file" ] && cmp -s "$content_file" "$TEST_ENCODED" || bad_call
	printf 'upload-file\n' >> "$TEST_TRACE"
	[ "$GH_MODE" != upload-error ] || exit 23
	if [ "$GH_MODE" = invalid-sha ]; then echo invalid; else printf '%s\n' "$TEST_SHA"; fi
	exit 0
fi
if [ "$#" -eq 7 ] && [ "$1" = issue ] && [ "$2" = comment ] &&
	[ "$3" = 42 ] && [ "$4" = --repo ] && [ "$5" = ranokay/glance ] &&
	[ "$6" = --body-file ]; then
	cp "$7" "$TEST_COMMENT"
	printf 'comment\n' >> "$TEST_TRACE"
	[ "$GH_MODE" != comment-error ] || exit 24
	exit 0
fi
bad_call
GH
cat > "$work_dir/bin/base64" <<'BASE64'
#!/bin/sh
if [ "${ENCODING_MODE:-valid}" = fail ]; then exit 23; fi
exec /usr/bin/base64 "$@"
BASE64
chmod +x "$work_dir/bin/open" "$work_dir/bin/pgrep" "$work_dir/bin/gh" "$work_dir/bin/base64"
PATH="$work_dir/bin:$PATH"
TMPDIR="$work_dir/tmp"
TEST_SHA=0123456789abcdef0123456789abcdef01234567
TEST_ENCODED="$work_dir/encoded"
TEST_BUNDLE="$work_dir/Glance.app"
export PATH TMPDIR TEST_SHA TEST_ENCODED TEST_BUNDLE
printf 'capture bytes\n' > "$work_dir/capture.png"
base64 < "$work_dir/capture.png" | tr -d '\n' > "$TEST_ENCODED"
case_count=0

start_case() {
	case_count=$((case_count + 1))
	case_label="$1"
	case_dir="$work_dir/case-$case_count"
	mkdir "$case_dir"
	TEST_TRACE="$case_dir/trace"
	TEST_COMMENT="$case_dir/comment"
	OPEN_MODE=valid
	GH_MODE=valid
	ENCODING_MODE=valid
	APP_NAME=Glance
	LAUNCH_TIMEOUT=3
	export TEST_TRACE TEST_COMMENT OPEN_MODE GH_MODE ENCODING_MODE APP_NAME LAUNCH_TIMEOUT
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

start_case 'invalid issue'
expect_failure sh "$capture_script" invalid "$work_dir/capture.png"
[ ! -s "$TEST_TRACE" ] || fail 'contacted GitHub for invalid input'
start_case 'zero issue'
expect_failure sh "$capture_script" 0 "$work_dir/capture.png"
[ ! -s "$TEST_TRACE" ] || fail 'contacted GitHub for zero issue'
start_case 'missing capture'
expect_failure sh "$capture_script" 42 "$work_dir/missing.png"
[ ! -s "$TEST_TRACE" ] || fail 'contacted GitHub for missing file'
start_case 'unsupported capture extension'
cp "$work_dir/capture.png" "$work_dir/capture.txt"
expect_failure sh "$capture_script" 42 "$work_dir/capture.txt"
[ ! -s "$TEST_TRACE" ] || fail 'contacted GitHub for unsupported file'
start_case 'empty capture'
: > "$work_dir/empty.png"
expect_failure sh "$capture_script" 42 "$work_dir/empty.png"
[ ! -s "$TEST_TRACE" ] || fail 'contacted GitHub for empty file'
start_case 'oversize capture'
dd if=/dev/zero of="$work_dir/oversize.png" bs=1 count=0 seek=10485761 2> "$case_dir/dd.log"
expect_failure sh "$capture_script" 42 "$work_dir/oversize.png"
[ ! -s "$TEST_TRACE" ] || fail 'contacted GitHub for oversize file'

start_case 'encoding failure prevents all remote writes'
ENCODING_MODE=fail
expect_failure sh "$capture_script" 42 "$work_dir/capture.png"
expect_no_call branch-create
expect_no_call upload-file
expect_no_call comment

for gh_mode in issue-error branch-auth upload-error invalid-sha comment-error; do
	start_case "capture $gh_mode"
	GH_MODE="$gh_mode"
	expect_failure sh "$capture_script" 42 "$work_dir/capture.png" 'Preview capture'
	case "$gh_mode" in
		issue-error|branch-auth) expect_no_call branch-create; expect_no_call upload-file ;;
		upload-error|invalid-sha) expect_no_call comment ;;
		comment-error)
			grep -q "retry attaching this URL: https://raw.githubusercontent.com/ranokay/glance/$TEST_SHA/" \
				"$case_dir/output" || fail 'missing immutable recovery URL'
			;;
	esac
done
start_case 'capture creates branch only after 404'
GH_MODE=branch-missing
expect_success sh "$capture_script" 42 "$work_dir/capture.png" 'Preview capture'
grep -q '^branch-create$' "$TEST_TRACE" || fail 'missing branch creation'
grep -Fq "https://raw.githubusercontent.com/ranokay/glance/$TEST_SHA/" "$TEST_COMMENT" \
	|| fail 'comment did not pin upload commit'
if grep -Fq '/verification-captures/' "$TEST_COMMENT"; then fail 'comment links a mutable branch'; fi
grep -Fxq 'Preview capture' "$TEST_COMMENT" || fail 'caption lost'

start_case 'capture continues when another upload created the branch'
GH_MODE=branch-race
expect_success sh "$capture_script" 42 "$work_dir/capture.png" 'Preview capture'
[ "$(grep -c '^branch-read$' "$TEST_TRACE")" -eq 2 ] || fail 'missing branch recheck'
grep -q '^upload-file$' "$TEST_TRACE" || fail 'racing capture was not uploaded'
grep -q '^comment$' "$TEST_TRACE" || fail 'racing capture was not attached'

for gh_mode in branch-create-error branch-recheck-auth; do
	start_case "capture $gh_mode"
	GH_MODE="$gh_mode"
	expect_failure sh "$capture_script" 42 "$work_dir/capture.png"
	[ "$(grep -c '^branch-read$' "$TEST_TRACE")" -eq 2 ] || fail 'missing failed branch recheck'
	grep -q 'HTTP 403: cannot create reference' "$case_dir/output" || fail 'creation error lost'
	expect_no_call upload-file
	expect_no_call comment
done

start_case 'capture larger than ARG_MAX uses a content file'
arg_max="$(getconf ARG_MAX)"
blocks=$((arg_max / 65536 + 1))
dd if=/dev/zero of="$work_dir/large.png" bs=65536 count="$blocks" 2> "$case_dir/dd.log"
base64 < "$work_dir/large.png" | tr -d '\n' > "$TEST_ENCODED"
expect_success sh "$capture_script" 42 "$work_dir/large.png"
grep -q '^upload-file$' "$TEST_TRACE" || fail 'large payload was not read from a file'

echo "Verification script tests passed: $case_count cases"
