#!/usr/bin/env bash
# push-post.sh — push the generated post to the personal site repo.
#
# Inputs (env):
#   POSTS_PAT     — PAT with contents:write on giacchetta/giacchetta.github.io
#   POST_PATH     — target path in the personal repo (e.g. post/2026-08-11-foo.md)
#   POST_FILENAME — filename only (e.g. 2026-08-11-foo.md)
#   POST_TITLE    — post title (for the commit message)
#   PR_NUMBER     — source PR number (for the commit message + idempotency)
#
# Idempotency: if a post with the same filename already exists in the personal
# repo's post/ directory AND its frontmatter carries the same pr: <number>,
# we overwrite it (safe re-run). Otherwise we add a new file.
set -euo pipefail

: "${POSTS_PAT:?POSTS_PAT env is required}"
: "${POST_PATH:?POST_PATH env is required}"
: "${POST_FILENAME:?POST_FILENAME env is required}"
: "${POST_TITLE:?POST_TITLE env is required}"
: "${PR_NUMBER:?PR_NUMBER env is required}"

TARGET_REPO="giacchetta/giacchetta.github.io"
CLONE_DIR="$(mktemp -d)"
trap 'rm -rf "$CLONE_DIR"' EXIT

echo "::group::Clone ${TARGET_REPO}"
git clone --depth 1 "https://x-access-token:${POSTS_PAT}@github.com/${TARGET_REPO}.git" "$CLONE_DIR"
cd "$CLONE_DIR"
git config user.name "github-actions[bot]"
git config user.email "41898282+github-actions[bot]@users.noreply.github.com"
echo "::endgroup::"

# Ensure the post/ directory exists.
mkdir -p "$(dirname "$POST_PATH")"

# Idempotency check: if the file exists and already references this PR, it's a
# re-run — overwrite. If it exists with a DIFFERENT pr: number, abort to avoid
# clobbering an unrelated post.
if [ -f "$POST_PATH" ]; then
  EXISTING_PR="$(awk '/^pr:/{print $2; exit}' "$POST_PATH" || true)"
  if [ -n "$EXISTING_PR" ] && [ "$EXISTING_PR" != "$PR_NUMBER" ]; then
    echo "::error::${POST_PATH} already exists with pr: ${EXISTING_PR}, refusing to overwrite (this PR is ${PR_NUMBER})."
    exit 1
  fi
  echo "::notice::Overwriting existing ${POST_PATH} (re-run for PR ${PR_NUMBER})."
fi

# Copy the cleaned post from the workflow workspace. The validate step wrote it
# to a temp path exposed via cleaned_file; fall back to the ai-inference
# response-file if cleaned_file is unset (defensive).
CLEANED_FILE="${CLEANED_FILE:-}"
if [ -z "$CLEANED_FILE" ] || [ ! -f "$CLEANED_FILE" ]; then
  echo "::error::Cleaned post file not found (CLEANED_FILE='${CLEANED_FILE}')."
  exit 1
fi

cp "$CLEANED_FILE" "$POST_PATH"

git add "$POST_PATH"

# Commit only if there's a change (re-run with identical content = no-op).
if git diff --cached --quiet; then
  echo "::notice::No content change vs existing ${POST_PATH}; skipping commit."
  exit 0
fi

COMMIT_MSG="post: ${POST_TITLE} (PR #${PR_NUMBER})"
git commit -m "$COMMIT_MSG"

echo "::group::Push to ${TARGET_REPO}"
git push origin HEAD:main
echo "::endgroup::"

echo "::notice::Published ${POST_PATH} to ${TARGET_REPO}. The repo's static.yaml workflow will rebuild and deploy."
