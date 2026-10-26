#!/bin/sh
# Attach a Quick Look capture to a GitHub issue: commit the image to the repo's
# `verification-captures` branch and post it on the ticket as an inline image.
#
# Fulfills the "attach it to the ticket" step of the manual-capture convention
# in docs/agents/verification.md without a human dragging a file into the
# browser. Raw URLs of this public repo render inline in issue comments (the
# same pattern the AppStore asset images use).
#
# Usage: attach-capture.sh <issue-number> <image-file> [caption]
# Example: attach-capture.sh 119 build/verification/structured-json-quicklook.png "JSON preview"
set -eu

REPO="ranokay/glance"
BRANCH="verification-captures"
DIR="docs/verification"

ISSUE="${1:?issue number required}"
IMAGE="${2:?image file required}"
CAPTION="${3:-}"

case "$ISSUE" in ''|*[!0-9]*) echo "issue number must contain only digits" >&2; exit 1 ;; esac
case "$ISSUE" in *[1-9]*) ;; *) echo "issue number must be positive" >&2; exit 1 ;; esac
if [ ! -f "$IMAGE" ]; then
	echo "not a file: $IMAGE" >&2
	exit 1
fi
case "$IMAGE" in
	*.png|*.PNG|*.jpg|*.JPG|*.jpeg|*.JPEG|*.gif|*.GIF|*.webp|*.WEBP) ;;
	*) echo "capture must be a PNG, JPEG, GIF, or WebP image" >&2; exit 1 ;;
esac
size="$(wc -c < "$IMAGE" | tr -d ' ')"
if [ "$size" -eq 0 ] || [ "$size" -gt 10485760 ]; then
	echo "capture must be between 1 byte and 10 MiB" >&2
	exit 1
fi

# Resolve the target before creating a branch or uploading an image.
gh issue view "$ISSUE" --repo "$REPO" --json number >/dev/null
work_dir="$(mktemp -d "${TMPDIR:-/tmp}/glance-capture.XXXXXX")"
trap 'rm -rf "$work_dir"' EXIT
trap 'exit 1' HUP INT TERM

# Keep each command's failure observable under POSIX sh, before remote writes.
base64 < "$IMAGE" > "$work_dir/encoded"
tr -d '\n' < "$work_dir/encoded" > "$work_dir/content"

NAME="$(basename "$IMAGE")"
NAME="$(printf '%s' "$NAME" | LC_ALL=C tr -c 'A-Za-z0-9._-' '-')"
NAME="issue-$ISSUE/$(uuidgen)-$NAME"

# Ensure the capture branch exists (created from develop once, append-only).
if ! gh api "repos/$REPO/branches/$BRANCH" > /dev/null 2>"$work_dir/branch-error"; then
	if ! grep -q 'HTTP 404' "$work_dir/branch-error"; then
		cat "$work_dir/branch-error" >&2
		exit 1
	fi
	SHA="$(gh api "repos/$REPO/branches/develop" --jq .commit.sha)"
	if gh api --method POST "repos/$REPO/git/refs" -f ref="refs/heads/$BRANCH" -f sha="$SHA" \
		> /dev/null 2>"$work_dir/branch-create-error"; then
		echo "created branch $BRANCH from develop"
	elif ! gh api "repos/$REPO/branches/$BRANCH" \
		> /dev/null 2>"$work_dir/branch-recheck-error"; then
		# Another upload may have created the branch since our first read.
		# Continue only when a fresh read confirms it exists.
		cat "$work_dir/branch-create-error" "$work_dir/branch-recheck-error" >&2
		exit 1
	fi
fi

# Pass the encoded content through a file: a normal screenshot can exceed the
# OS argument-size limit long before GitHub's upload limit.
SHA="$(gh api --method PUT "repos/$REPO/contents/$DIR/$NAME" \
	-f message="Add verification capture $NAME for #$ISSUE" \
	-f branch="$BRANCH" \
	-F "content=@$work_dir/content" \
	--jq .commit.sha)"

if [ "${#SHA}" -ne 40 ] || printf '%s' "$SHA" | LC_ALL=C grep -q '[^0-9a-f]'; then
	echo "upload failed: no commit sha returned" >&2
	exit 1
fi
URL="https://raw.githubusercontent.com/$REPO/$SHA/$DIR/$NAME"

printf '%s\n![Quick Look capture](%s)\n' "$CAPTION" "$URL" > "$work_dir/comment.md"
if ! gh issue comment "$ISSUE" --repo "$REPO" --body-file "$work_dir/comment.md" >/dev/null; then
	echo "image uploaded but comment failed; retry attaching this URL: $URL" >&2
	exit 1
fi
echo "attached to #$ISSUE: $URL"
