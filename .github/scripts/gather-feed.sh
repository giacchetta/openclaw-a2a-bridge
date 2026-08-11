#!/usr/bin/env bash
# gather-feed.sh — collect PR + linked-issues feed for post generation.
#
# Reads from the current repo (GH_TOKEN env) and emits a single JSON object on
# stdout with the shape the ai-inference prompt template expects:
#
#   {
#     "pr_number": 13,
#     "pr_title": "...",
#     "pr_body": "...",
#     "repo": "giacchetta/openclaw-a2a-bridge",
#     "repo_description": "...",
#     "merge_date": "2026-08-11",
#     "base_ref": "main",
#     "head_ref": "...",
#     "issues": [ { "number": 6, "title": "...", "body": "..." }, ... ],
#     "commits": [ { "headline": "...", "body": "..." }, ... ],
#     "files_changed": [ "AGENTS.md", "README.md", ... ],
#     "diffstat": "3 files changed, 40 insertions(+), 8 deletions(-)"
#   }
#
# Env: GH_TOKEN (auth), PR_NUMBER (required).
set -euo pipefail

: "${PR_NUMBER:?PR_NUMBER env is required}"

REPO="${GITHUB_REPOSITORY:-$(gh repo view --json nameWithOwner -q .nameWithOwner)}"

# --- PR metadata -------------------------------------------------------------
PR_JSON="$(gh pr view "$PR_NUMBER" --json number,title,body,baseRefName,headRefName,mergedAt,mergeCommit,files,commits)"

PR_TITLE="$(echo "$PR_JSON" | jq -r '.title')"
PR_BODY="$(echo "$PR_JSON" | jq -r '.body // ""')"
BASE_REF="$(echo "$PR_JSON" | jq -r '.baseRefName')"
HEAD_REF="$(echo "$PR_JSON" | jq -r '.headRefName')"
MERGED_AT="$(echo "$PR_JSON" | jq -r '.mergedAt // ""')"

# Merge date in UTC YYYY-MM-DD (the post's filename date). For workflow_dispatch
# on an already-merged PR, mergedAt is present. Fall back to today if missing.
if [ -n "$MERGED_AT" ] && [ "$MERGED_AT" != "null" ]; then
  MERGE_DATE="$(date -u -d "$MERGED_AT" +%Y-%m-%d)"
else
  MERGE_DATE="$(date -u +%Y-%m-%d)"
fi

# --- Repo description --------------------------------------------------------
REPO_DESCRIPTION="$(gh repo view "$REPO" --json description -q '.description // ""')"

# --- Linked issues (parent + sub-issues) ------------------------------------
# Parse "closes #N" / "fixes #N" / "resolves #N" / "refs #N" from the PR body.
# Also pull the PR's closingIssuesReferences (GitHub's own linkage) as a backstop.
ISSUE_NUMBERS="$(echo "$PR_JSON" | jq -r '
  (.closingIssuesReferences // []) | map(.number | tostring) | .[]
')"

# Also scan the PR body for issue references (catches "refs #N" which GitHub
# doesn't surface in closingIssuesReferences).
BODY_REFS="$(printf '%s\n' "$PR_BODY" | grep -oE '(closes|fixes|resolves|refs|closed|fix) #[0-9]+' | grep -oE '[0-9]+' || true)"

ALL_NUMBERS="$(printf '%s\n%s\n' "$ISSUE_NUMBERS" "$BODY_REFS" | sort -un | grep -E '^[0-9]+$' || true)"

ISSUES_JSON="[]"
if [ -n "$ALL_NUMBERS" ]; then
  ISSUES_JSON="$(for n in $ALL_NUMBERS; do
    gh issue view "$n" --json number,title,body 2>/dev/null || true
  done | jq -s '
    map({number, title, body: (.body // "")})
    | sort_by(.number)
  ')"
fi

# --- Commits (headline + body) ----------------------------------------------
COMMITS_JSON="$(echo "$PR_JSON" | jq '[.commits[] | {headline: .messageHeadline, body: (.messageBody // "")}]')"

# --- Files changed + diffstat -----------------------------------------------
FILES_CHANGED="$(echo "$PR_JSON" | jq -r '[.files[].path]')"
# gh pr view --json files gives per-file additions/deletions; synthesize a diffstat.
DIFFSTAT="$(echo "$PR_JSON" | jq -r '
  [.files[] | "\(.path) | \(.additions)+ \(.deletions)-"] | join("\n")
')"

# --- Assemble ----------------------------------------------------------------
jq -n \
  --arg pr_number "$PR_NUMBER" \
  --arg pr_title "$PR_TITLE" \
  --arg pr_body "$PR_BODY" \
  --arg repo "$REPO" \
  --arg repo_description "$REPO_DESCRIPTION" \
  --arg merge_date "$MERGE_DATE" \
  --arg base_ref "$BASE_REF" \
  --arg head_ref "$HEAD_REF" \
  --argjson issues "${ISSUES_JSON:-[]}" \
  --argjson commits "${COMMITS_JSON:-[]}" \
  --argjson files_changed "${FILES_CHANGED:-[]}" \
  --arg diffstat "$DIFFSTAT" \
  '{
    pr_number: ($pr_number | tonumber),
    pr_title: $pr_title,
    pr_body: $pr_body,
    repo: $repo,
    repo_description: $repo_description,
    merge_date: $merge_date,
    base_ref: $base_ref,
    head_ref: $head_ref,
    issues: $issues,
    commits: $commits,
    files_changed: $files_changed,
    diffstat: $diffstat
  }'
