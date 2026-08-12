#!/usr/bin/env bash
# prepare-post.sh — clean the AI-generated post and derive its target path.
#
# NO YAML PARSING. The frontmatter is generated from a template we control,
# and the model occasionally injects code fences inside/around it that crash
# yaml.safe_load (ScannerError on '`') — parsing the whole document was the
# fragile part, so we don't. Instead we read a single `slug:` line out of the
# frontmatter with a targeted grep/sed (bounded to between the two `---`
# fences), validate it against a strict charset, and fall back to a
# slugified PR_TITLE (from gather, never from the model) if it's missing or
# invalid. That slug IS the filename, and the filename is the post's public
# URL (src/content/blog/<slug>.md -> /blog/<slug>), so title/date/description
# still come only from gather / the frontmatter template — never trusted for
# routing beyond that one grepped line.
#
# The AI response is only cleaned textually: CRLF -> LF, leading/trailing code
# fences stripped, leading blank lines removed. The frontmatter is otherwise
# left untouched (the CODEOWNER reviews the PR before merge and catches any
# model formatting drift at build time on the personal repo).
#
# Inputs (env):
#   RESPONSE_FILE  — path to the model response (from actions/ai-inference output)
#   PR_TITLE       — the PR title (from gather; slug fallback + commit msg)
#   PR_NUMBER      — the PR number (for idempotency metadata + slug fallback)
#
# Outputs (GITHUB_ENV-style, written to $GITHUB_OUTPUT):
#   path          — target path in the personal repo: src/content/blog/<slug>.md
#   filename      — <slug>.md
#   title         — PR title (for the commit message)
#   slug          — the post's slug (from frontmatter, or slugified PR title)
#   cleaned_file  — stable path to the cleaned content (frontmatter + body)
set -euo pipefail

: "${RESPONSE_FILE:?RESPONSE_FILE env is required}"
: "${PR_TITLE:?PR_TITLE env is required}"
: "${PR_NUMBER:?PR_NUMBER env is required}"

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

# Try to read the model's own `slug:` line first — it becomes the public
# post URL, so a human-readable, on-topic slug beats the PR-title fallback.
# Bounded to the frontmatter block (between the two leading `---` fences) so
# a stray "slug:"-looking line in the body can't be picked up; this is a
# single targeted line-read, not a YAML parse.
MODEL_SLUG=""
if [ "$(printf '%s' "$CONTENT" | sed -n '1p')" = "---" ]; then
  MODEL_SLUG="$(printf '%s\n' "$CONTENT" \
    | awk 'NR==1{next} /^---[[:space:]]*$/{exit} {print}' \
    | sed -n 's/^slug:[[:space:]]*//p' \
    | head -n1 \
    | sed 's/^["'"'"']//; s/["'"'"'][[:space:]]*$//; s/[[:space:]]*$//' \
    | tr '[:upper:]' '[:lower:]')"
fi
case "$MODEL_SLUG" in
  '' | -* | *-) MODEL_SLUG="" ;;
  *[!a-z0-9-]*) MODEL_SLUG="" ;;
esac

# Fall back to a slug derived from the PR title (deterministic, from gather —
# never parsed back out of the model response). Lowercase, replace every
# non-alphanumeric run with a single '-', strip leading/trailing '-'. Fall
# back further to pr-<N> if the title had no alphanumerics at all.
if [ -n "$MODEL_SLUG" ]; then
  SLUG="$MODEL_SLUG"
else
  SLUG="$(printf '%s' "$PR_TITLE" \
    | tr '[:upper:]' '[:lower:]' \
    | tr -c '[:alnum:]' '-' \
    | sed 's/--*/-/g; s/^-*//; s/-*$//')"
  if [ -z "$SLUG" ]; then
    SLUG="pr-${PR_NUMBER}"
  fi
  echo "::notice::No usable frontmatter slug; falling back to PR-title slug '${SLUG}'."
fi

TITLE="$PR_TITLE"
FILENAME="${SLUG}.md"
POST_PATH="src/content/blog/${FILENAME}"

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
