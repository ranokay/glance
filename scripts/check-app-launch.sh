#!/bin/sh
# Probe a new instance of the given artifact. The app reports its own delegate,
# menu, and registered status item after one second, then exits. No AX permission
# or visible menu-bar space is required; a missing receipt is always a failure.
# Usage: check-app-launch.sh [path-to-app-bundle]
set -eu

APP_NAME="${APP_NAME:-Glance}"
APP_PATH="${1:-build/Build/Products/Release/$APP_NAME.app}"
TIMEOUT="${LAUNCH_TIMEOUT:-15}"
case "$TIMEOUT" in ''|*[!0-9]*) echo "LAUNCH_TIMEOUT must be a positive integer" >&2; exit 1 ;; esac
if [ "$TIMEOUT" -lt 1 ] || [ "$TIMEOUT" -gt 120 ]; then
	echo "LAUNCH_TIMEOUT must be between 1 and 120 seconds" >&2
	exit 1
fi
if [ ! -x "$APP_PATH/Contents/MacOS/$APP_NAME" ]; then
	echo "App executable not found: $APP_PATH/Contents/MacOS/$APP_NAME" >&2
	exit 1
fi
APP_PATH="$(cd "$APP_PATH" && pwd -P)"
probe_dir="$(mktemp -d "${TMPDIR:-/tmp}/glance-launch.XXXXXX")"
token="$(uuidgen)"
launcher_pid=""
# shellcheck disable=SC2329 # Invoked by the EXIT trap, including timeout cleanup.
cleanup() {
	# The unique argument belongs only to this probe and its open helper.
	for pid in $(pgrep -f -- "--verify-launch $token" || true); do
		kill -KILL "$pid" 2>/dev/null || true
	done
	if [ -n "$launcher_pid" ]; then
		kill -KILL "$launcher_pid" 2>/dev/null || true
		wait "$launcher_pid" 2>/dev/null || true
	fi
	rm -rf "$probe_dir"
}
trap "cleanup" EXIT
trap 'exit 1' HUP INT TERM

open -n -g -W --stdout "$probe_dir/stdout" --stderr "$probe_dir/stderr" \
	"$APP_PATH" --args --verify-launch "$token" >"$probe_dir/open.log" 2>&1 &
launcher_pid=$!
deadline=$(( $(date +%s) + TIMEOUT ))
while [ "$(date +%s)" -lt "$deadline" ]; do
	if ! kill -0 "$launcher_pid" 2>/dev/null; then
		if wait "$launcher_pid" && grep -Fxq "GLANCE_LAUNCH_OK $token" "$probe_dir/stdout" 2>/dev/null; then
			launcher_pid=""
			echo "OK: $APP_PATH launched with a live delegate, menu, and registered status item"
			exit 0
		fi
		break
	fi
	sleep 0.1
done

echo "FAIL: $APP_PATH did not complete launch verification within ${TIMEOUT}s" >&2
for log in "$probe_dir/stdout" "$probe_dir/stderr" "$probe_dir/open.log"; do
	if [ -f "$log" ]; then tail -20 "$log" >&2; fi
done
exit 1
