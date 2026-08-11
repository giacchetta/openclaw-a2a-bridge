#!/usr/bin/env bash
# validate-post.sh — validate the AI-generated post and extract frontmatter.
#
# Inputs (env):
#   RESPONSE_FILE  — path to the model response (from actions/ai-inference output)
#   PR_NUMBER      — the PR number (for idempotency metadata)
#   MERGE_DATE     — YYYY-MM-DD (the post's filename date)
#
# Outputs (GITHUB_ENV-style, written to $GITHUB_OUTPUT):
#   path        — target path in the personal repo: post/<YYYY-MM-DD>-<slug>.md
#   filename    — <YYYY-MM-DD>-<slug>.md
#   title       — frontmatter title (for the commit message)
#   slug        — frontmatter slug
#
# Validation gates (any failure exits non-zero so the workflow stops):
#   1. File is non-empty.
#   2. Starts with frontmatter fence "---".
#   3. Frontmatter parses as YAML and contains slug, title, date, authors, tags.
#   4. slug is lowercase, kebab-case, no spaces.
#   5. Body (after frontmatter) is non-empty and >= 80 chars.
set -euo pipefail

: "${RESPONSE_FILE:?RESPONSE_FILE env is required}"
: "${PR_NUMBER:?PR_NUMBER env is required}"
: "${MERGE_DATE:?MERGE_DATE env is required}"

if [ ! -s "$RESPONSE_FILE" ]; then
  echo "::error::Generated post is empty."
  exit 1
fi

# The model may wrap the markdown file in a ``` fence or prepend prose. Extract
# the first frontmatter block (--- ... ---) and everything after it.
CONTENT="$(cat "$RESPONSE_FILE")"

# Strip a leading ```markdown / ``` fence if present.
CONTENT="$(printf '%s\n' "$CONTENT" | sed -E '1{/^```(markdown|md)?$/d}')"
# Strip a trailing ``` fence if present (last non-empty line).
CONTENT="$(printf '%s\n' "$CONTENT" | sed -E '${/^```$/d}')"

if ! printf '%s\n' "$CONTENT" | head -1 | grep -qx '---'; then
  echo "::error::Post does not start with frontmatter fence '---'."
  echo "::error::First 5 lines:"
  printf '%s\n' "$CONTENT" | head -5 | sed 's/^/  /'
  exit 1
fi

# Split frontmatter and body.
FM="$(printf '%s\n' "$CONTENT" | awk 'NR==1{next} /^---$/{exit} {print}')"
BODY="$(printf '%s\n' "$CONTENT" | awk 'found{print} /^---$/{if(NR>1){found=1}}')"

if [ -z "$FM" ]; then
  echo "::error::Frontmatter is empty (no closing '---' fence found)."
  exit 1
fi

if [ -z "$(printf '%s\n' "$BODY" | tr -d '[:space:]')" ]; then
  echo "::error::Post body is empty."
  exit 1
fi

BODY_LEN="$(printf '%s\n' "$BODY" | tr -d '[:space:]' | wc -c)"
if [ "$BODY_LEN" -lt 80 ]; then
  echo "::error::Post body is too short (${BODY_LEN} chars). Expected a full LinkedIn post."
  exit 1
fi

# Parse frontmatter fields. Use python3 (preinstalled on ubuntu-latest) for
# safe YAML parsing rather than fragile grep/sed.
read -r SLUG TITLE DATE AUTHORS_TAGS_OK <<< "$(python3 - <<'PY' "$FM"
import sys, yaml, re
fm = yaml.safe_load(sys.stdin.read())
errors = []
for k in ("slug", "title", "date", "authors", "tags"):
    if k not in fm:
        errors.append(f"missing key: {k}")
if errors:
    print("ERRORS:" + "|".join(errors))
    sys.exit(0)
slug = str(fm["slug"])
title = str(fm["title"])
date = str(fm["date"])
authors_ok = isinstance(fm["authors"], list) and len(fm["authors"]) > 0
tags_ok = isinstance(fm["tags"], list) and len(fm["tags"]) > 0
if not re.fullmatch(r"[a-z0-9-]+", slug):
    errors.append("slug must be lowercase kebab-case")
if not authors_ok:
    errors.append("authors must be a non-empty list")
if not tags_ok:
    errors.append("tags must be a non-empty list")
if errors:
    print("ERRORS:" + "|".join(errors))
    sys.exit(0)
print(f"{slug}\t{title}\t{date}\t{authors_ok and tags_ok}")
PY
)"

if [[ "$SLUG" == ERRORS:* ]]; then
  echo "::error::Frontmatter validation failed: ${SLUG#ERRORS:}"
  exit 1
fi

if [ -z "$TITLE" ] || [ -z "$SLUG" ]; then
  echo "::error::Could not extract slug/title from frontmatter."
  exit 1
fi

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

echo "::notice::Validated post -> ${POST_PATH} (title: ${TITLE})"
