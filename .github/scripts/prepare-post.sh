#!/usr/bin/env bash
# prepare-post.sh — lenient extraction of the AI-generated post.
#
# Replaces the strict validate-post.sh gates (body length, kebab-case, non-empty
# fields) with a permissive pass: strip code fences + CRLF, parse the frontmatter
# for slug + title, and write the cleaned content to a stable path. Only fails
# when the frontmatter is truly unparseable (no slug/title to derive a filename
# from). The strict gates were disabled because the model occasionally adds
# stray characters the gates rejected, blocking the whole pipeline.
#
# Inputs (env):
#   RESPONSE_FILE  — path to the model response (from actions/ai-inference output)
#   PR_NUMBER      — the PR number (for idempotency metadata)
#   MERGE_DATE     — YYYY-MM-DD (the post's filename date)
#
# Outputs (GITHUB_ENV-style, written to $GITHUB_OUTPUT):
#   path          — target path in the personal repo: post/<YYYY-MM-DD>-<slug>.md
#   filename      — <YYYY-MM-DD>-<slug>.md
#   title         — frontmatter title (for the commit message)
#   slug          — frontmatter slug
#   cleaned_file  — stable path to the cleaned content (frontmatter + body)
set -euo pipefail

: "${RESPONSE_FILE:?RESPONSE_FILE env is required}"
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

# Parse frontmatter fields with python3 (preinstalled on ubuntu-latest) for
# safe YAML parsing. Fields are delimited by \x1f (ASCII unit separator) so a
# title containing spaces (or even newlines) survives intact into bash vars.
# NUL can't be used because bash truncates variables at the first NUL byte.
FM_PARSE_OUT="$(python3 - "$FM" <<'PY'
import sys, yaml, re
SEP = "\x1f"
fm = yaml.safe_load(sys.argv[1])
if not isinstance(fm, dict):
    sys.stdout.write("ERRORS:frontmatter did not parse as a YAML mapping" + SEP)
    sys.exit(0)
slug = str(fm.get("slug", "") or "")
title = str(fm.get("title", "") or "")
if not slug:
    sys.stdout.write("ERRORS:missing slug" + SEP)
    sys.exit(0)
if not title:
    sys.stdout.write("ERRORS:missing title" + SEP)
    sys.exit(0)
# Lenient: do NOT enforce kebab-case on the slug. If it contains spaces or
# uppercase chars, normalize to lowercase kebab-case so the filename is safe.
slug = slug.strip().lower()
slug = re.sub(r"[^a-z0-9]+", "-", slug)
slug = slug.strip("-")
if not slug:
    sys.stdout.write("ERRORS:slug normalized to empty" + SEP)
    sys.exit(0)
sys.stdout.write(f"{slug}{SEP}{title}{SEP}")
PY
)"

SLUG="${FM_PARSE_OUT%%$'\x1f'*}"
if [[ "$SLUG" == ERRORS:* ]]; then
  echo "::error::Frontmatter extraction failed: ${SLUG#ERRORS:}"
  exit 1
fi
REST="${FM_PARSE_OUT#*$'\x1f'}"
TITLE="${REST%%$'\x1f'*}"

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
