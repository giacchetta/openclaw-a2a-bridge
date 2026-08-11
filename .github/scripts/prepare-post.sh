#!/usr/bin/env bash
# prepare-post.sh — clean the AI-generated post and derive its target path.
#
# NO YAML PARSING. The frontmatter is generated from a template we control, so
# routing metadata (filename, title) is derived deterministically from the
# gather step's PR_TITLE + MERGE_DATE — never read back out of the model
# response. The model occasionally injects code fences inside/around the
# frontmatter that crash yaml.safe_load (ScannerError on '`'); parsing the
# post for routing metadata was the fragile part, so we stopped doing it.
#
# The AI response is only cleaned textually: CRLF -> LF, leading/trailing code
# fences stripped, leading blank lines removed. The frontmatter is left
# untouched (the CODEOWNER reviews the PR before merge and catches any model
# formatting drift at build time on the personal repo).
#
# Inputs (env):
#   RESPONSE_FILE  — path to the model response (from actions/ai-inference output)
#   PR_TITLE       — the PR title (from gather; slugified for the filename + commit msg)
#   PR_NUMBER      — the PR number (for idempotency metadata + slug fallback)
#   MERGE_DATE     — YYYY-MM-DD (the post's filename date, from gather)
#
# Outputs (GITHUB_ENV-style, written to $GITHUB_OUTPUT):
#   path          — target path in the personal repo: post/<YYYY-MM-DD>-<slug>.md
#   filename      — <YYYY-MM-DD>-<slug>.md
#   title         — PR title (for the commit message)
#   slug          — slugified PR title
#   cleaned_file  — stable path to the cleaned content (frontmatter + body)
set -euo pipefail

: "${RESPONSE_FILE:?RESPONSE_FILE env is required}"
: "${PR_TITLE:?PR_TITLE env is required}"
: "${PR_NUMBER:?PR_NUMBER env is required}"
: "${MERGE_DATE:?MERGE_DATE env is required}"

if [ ! -s "$RESPONSE_FILE" ]; then
  echo "::error::Generated post is empty."
  exit 1
fi

CONTENT="$(cat "$RESPONSE_FILE")"

# Normalize CRLF -> LF. The Copilot CLI / model can emit Windows line endings,
# which breaks `grep -qx '---'` (the line becomes `---\r`) and YAML parsing.
CONTENT="$(printf '%s\n' "$CONTENT" | tr -d '\r')"

# Strip a leading ```markdown / ``` fence if present (model often wraps output),
# and a trailing ``` fence. Use awk (not sed) for portability across GNU/BSD.
# Tolerate trailing whitespace on the fence lines.
CONTENT="$(printf '%s\n' "$CONTENT" | awk '
  BEGIN { strip_lead=1 }
  strip_lead && /^```(markdown|md)?[[:space:]]*$/ { next }
  { strip_lead=0; print }
' | awk '
  { lines[NR]=$0 }
  END {
    # Drop trailing blank lines, then a trailing ``` fence if present.
    last=NR
    while (last>0 && lines[last] ~ /^[[:space:]]*$/) last--
    if (last>0 && lines[last] ~ /^```[[:space:]]*$/) last--
    for (i=1;i<=last;i++) print lines[i]
  }
')"

# Strip leading blank/whitespace-only lines before the frontmatter fence
# (preserves blank lines in the body).
CONTENT="$(printf '%s\n' "$CONTENT" | awk 'NF { p=1 } p { print }')"

# Derive the slug from the PR title (deterministic, from gather — never parsed
# back out of the model response). Lowercase, replace every non-alphanumeric
# run with a single '-', strip leading/trailing '-'. Fall back to pr-<N> if the
# title had no alphanumerics at all.
SLUG="$(printf '%s' "$PR_TITLE" \
  | tr '[:upper:]' '[:lower:]' \
  | tr -c '[:alnum:]' '-' \
  | sed 's/--*/-/g; s/^-*//; s/-*$//')"
if [ -z "$SLUG" ]; then
  SLUG="pr-${PR_NUMBER}"
fi

TITLE="$PR_TITLE"
FILENAME="${MERGE_DATE}-${SLUG}.md"
POST_PATH="post/${FILENAME}"

# Write the cleaned content (frontmatter + body, no code fences) to a stable
# path the push script reads.
CLEANED_FILE="$(mktemp -d)/${FILENAME}"
printf '%s\n' "$CONTENT" > "$CLEANED_FILE"

{
  echo "path=${POST_PATH}"
  echo "filename=${FILENAME}"
  echo "title=${TITLE}"
  echo "slug=${SLUG}"
  echo "cleaned_file=${CLEANED_FILE}"
} >> "$GITHUB_OUTPUT"

echo "::notice::Prepared post -> ${POST_PATH} (title: ${TITLE})"
