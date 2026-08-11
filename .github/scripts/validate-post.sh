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

if ! printf '%s\n' "$CONTENT" | head -1 | grep -qx -e '---'; then
  echo "::error::Post does not start with frontmatter fence '---'."
  echo "::error::First 5 lines:"
  printf '%s\n' "$CONTENT" | head -5 | sed 's/^/  /'
  exit 1
fi

# Split frontmatter and body. Fence lines may carry trailing whitespace
# (already CRLF-normalized above), so match `---` followed by optional spaces.
FM="$(printf '%s\n' "$CONTENT" | awk 'NR==1{next} /^---[[:space:]]*$/{exit} {print}')"
BODY="$(printf '%s\n' "$CONTENT" | awk 'found{print} /^---[[:space:]]*$/{if(NR>1){found=1}}')"

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
# safe YAML parsing rather than fragile grep/sed. The frontmatter text is
# passed as argv[1] (the heredoc supplies the script on stdin, so sys.stdin
# is already consumed — reading from it returns "" and yields None).
#
# Fields are delimited by \x1f (ASCII unit separator) so a title containing
# spaces (or even newlines) survives intact into the bash variables. NUL
# can't be used because bash truncates variables at the first NUL byte.
FM_PARSE_OUT="$(python3 - "$FM" <<'PY'
import sys, yaml, re
SEP = "\x1f"
fm = yaml.safe_load(sys.argv[1])
if not isinstance(fm, dict):
    sys.stdout.write("ERRORS:frontmatter did not parse as a YAML mapping" + SEP)
    sys.exit(0)
errors = []
for k in ("slug", "title", "date", "authors", "tags"):
    if k not in fm:
        errors.append(f"missing key: {k}")
if errors:
    sys.stdout.write("ERRORS:" + "|".join(errors) + SEP)
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
    sys.stdout.write("ERRORS:" + "|".join(errors) + SEP)
    sys.exit(0)
sys.stdout.write(f"{slug}{SEP}{title}{SEP}{date}{SEP}{authors_ok and tags_ok}{SEP}")
PY
)"

# Split on the unit separator. The first field may be an ERRORS: marker.
SLUG="${FM_PARSE_OUT%%$'\x1f'*}"
if [[ "$SLUG" == ERRORS:* ]]; then
  echo "::error::Frontmatter validation failed: ${SLUG#ERRORS:}"
  exit 1
fi
# Drop the first field, then extract each subsequent field.
REST="${FM_PARSE_OUT#*$'\x1f'}"
TITLE="${REST%%$'\x1f'*}"
REST="${REST#*$'\x1f'}"
DATE="${REST%%$'\x1f'*}"
REST="${REST#*$'\x1f'}"
AUTHORS_TAGS_OK="${REST%%$'\x1f'*}"

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
