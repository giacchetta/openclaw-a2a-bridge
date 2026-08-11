#!/usr/bin/env bash
# push-post.sh — push the generated post to the personal site repo via a
# short-lived branch + pull request (NOT a direct push to main). The repo's
# CODEOWNER reviews and merges the PR; the repo's static.yaml workflow then
# rebuilds and deploys on push to main.
#
# Inputs (env):
#   POSTS_PAT     — PAT with contents:write + pull-requests:write on
#                  giacchetta/giacchetta.github.io
#   POST_PATH     — target path in the personal repo (e.g. post/2026-08-11-foo.md)
#   POST_FILENAME — filename only (e.g. 2026-08-11-foo.md)
#   POST_TITLE    — post title (for the commit message + PR title)
#   PR_NUMBER     — source PR number (for the commit message + idempotency)
#   SOURCE_REPO   — source repo in owner/name form (for the PR body link);
#                   defaults to the current GITHUB_REPOSITORY env var
#
# Branch model: one branch per post, named post/<YYYY-MM-DD>-<slug> (derived
# from POST_FILENAME by stripping the .md suffix). Re-runs of the same source
# PR (or backfill of the same post) reuse the same branch and PR.
#
# Idempotency: if a post with the same filename already exists on the branch
# AND its frontmatter carries the same pr: <number>, we overwrite it (safe
# re-run). If it exists with a DIFFERENT pr: number, we abort to avoid
# clobbering an unrelated post.
set -euo pipefail

: "${POSTS_PAT:?POSTS_PAT env is required}"
: "${POST_PATH:?POST_PATH env is required}"
: "${POST_FILENAME:?POST_FILENAME env is required}"
: "${POST_TITLE:?POST_TITLE env is required}"
: "${PR_NUMBER:?PR_NUMBER env is required}"

TARGET_REPO="giacchetta/giacchetta.github.io"
SOURCE_REPO="${SOURCE_REPO:-${GITHUB_REPOSITORY:-}}"
BRANCH_NAME="post/${POST_FILENAME%.md}"

export GH_TOKEN="$POSTS_PAT"
export GH_HOST="github.com"

CLONE_DIR="$(mktemp -d)"
trap 'rm -rf "$CLONE_DIR"' EXIT

echo "::group::Clone ${TARGET_REPO}"
git clone --depth 1 "https://x-access-token:${POSTS_PAT}@github.com/${TARGET_REPO}.git" "$CLONE_DIR"
cd "$CLONE_DIR"
git config user.name "Luciano Giacchetta"
git config user.email "ldgiacchetta@gmail.com"
echo "::endgroup::"

# Switch to the post branch. If a remote branch with the same name already
# exists (a previous run for this post), fetch and check it out so the re-run
# adds a commit to the existing PR. Otherwise, branch off main.
EXISTING_BRANCH_SHA="$(git ls-remote --heads origin "${BRANCH_NAME}" | awk '{print $1}')"
if [ -n "$EXISTING_BRANCH_SHA" ]; then
  echo "::notice::Branch ${BRANCH_NAME} already exists in ${TARGET_REPO}; fetching for re-run."
  git fetch --depth 1 origin "${BRANCH_NAME}"
  git checkout -B "${BRANCH_NAME}" "origin/${BRANCH_NAME}"
else
  echo "::notice::Creating new branch ${BRANCH_NAME} from main."
  git checkout -b "${BRANCH_NAME}"
fi

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
else
  COMMIT_MSG="post: ${POST_TITLE} (PR #${PR_NUMBER})"
  git commit -m "$COMMIT_MSG"
fi

echo "::group::Push branch ${BRANCH_NAME} to ${TARGET_REPO}"
# Normal push to our own automation branch (never force-push). On a re-run the
# branch is already checked out from origin, so this is a fast-forward.
git push -u origin "${BRANCH_NAME}"
echo "::endgroup::"

# Open a pull request for the branch, or surface the existing one if it's
# already open. gh CLI is preinstalled on ubuntu-latest and authenticated via
# GH_TOKEN (the same PAT, scoped to the target repo).
PR_TITLE="post: ${POST_TITLE} (PR #${PR_NUMBER})"
PR_BODY="$(cat <<EOF
Auto-generated LinkedIn post from merged PR.

- **Post:** \`${POST_PATH}\`
- **Title:** ${POST_TITLE}
- **Source PR:** $([ -n "$SOURCE_REPO" ] && echo "https://github.com/${SOURCE_REPO}/pull/${PR_NUMBER}" || echo "#${PR_NUMBER} in source repo")

Review and merge to publish. The repo's \`static.yaml\` workflow will rebuild
and deploy on push to \`main\`.
EOF
)"

EXISTING_PR_URL="$(gh pr list \
  --repo "${TARGET_REPO}" \
  --head "${BRANCH_NAME}" \
  --base main \
  --state open \
  --json url \
  --jq '.[0].url // empty' 2>/dev/null || true)"

if [ -n "$EXISTING_PR_URL" ]; then
  echo "::notice::Pull request already open for ${BRANCH_NAME}: ${EXISTING_PR_URL}"
else
  echo "::group::Create pull request for ${BRANCH_NAME}"
  PR_URL="$(gh pr create \
    --repo "${TARGET_REPO}" \
    --base main \
    --head "${BRANCH_NAME}" \
    --title "${PR_TITLE}" \
    --body "${PR_BODY}")"
  echo "::endgroup::"
  echo "::notice::Opened pull request: ${PR_URL}"
fi
