# Post-on-merge pipeline

Generates a LinkedIn-style post from a merged PR and pushes it to the personal
site (`giacchetta/giacchetta.github.io`) under
`src/content/blog/<slug>.md` — an Astro content collection, where the
filename is the post's public URL (`/blog/<slug>`). The personal repo's
`static.yaml` workflow rebuilds and deploys on push to `main`, so the post
goes live automatically.

**One merged PR == one post.** The PR's closing issues (parent + sub-issues)
are gathered as narrative feed alongside the PR title/body/commits/diffstat,
then `actions/ai-inference@v1` (Copilot CLI, `claude-haiku-4.5`) writes the
post from a calibrated system prompt.

## Files

```
.github/
├── workflows/
│   └── post-on-merge.yml        # trigger: pull_request closed + merged; workflow_dispatch backfill
├── scripts/
│   ├── gather-feed.sh          # gh + jq → feed.json (PR + linked issues + commits + diffstat)
│   ├── prepare-post.sh        # strips fences/CRLF; slug from a grepped frontmatter line, PR-title fallback
│   └── push-post.sh            # clone personal repo, write src/content/blog/, commit, push via PR (idempotent)
└── prompts/
    ├── linkedin-post.system.md # voice + hard rules (calibrated against 2 existing posts)
    └── linkedin-post.prompt.yml # user-message template ({{repo}}, {{pr_body}}, {{issues}}, …)
```

## Trigger

- **Automatic:** `pull_request` → `closed` → `merged == true` on `main`.
- **Backfill:** `workflow_dispatch` with `pr_number` input regenerates a post
  from any past merged PR.

## Secrets (repo Actions secrets)

| Secret | Purpose | Scope |
|--------|---------|-------|
| `COPILOT_PAT` | `COPILOT_GITHUB_TOKEN` for `actions/ai-inference` (Copilot CLI auth) | A user PAT with a Copilot seat |
| `POSTS_PAT` | Cross-repo push to `giacchetta/giacchetta.github.io` | `contents: write` on that repo (fine-grained) |

`GITHUB_TOKEN` is used only to read this repo's PR/issues via `gh`.

## Output

- **Personal repo** (`giacchetta/giacchetta.github.io`): `src/content/blog/<slug>.md`
  — always, via a short-lived `post/<slug>` branch + pull request (never a direct
  push to `main`). Merging that PR is what deploys it, via the repo's `static.yaml`.
- **Company repo** (`gianet-us/www_gianet_us`): not wired yet (Phase 2). Posts
  are re-posted manually for now.

## Idempotency

The post's frontmatter carries `pr: <number>`. The filename (slug) is
model-chosen, so it can differ between runs of the same PR: on re-run,
`push-post.sh` first looks for an existing post under `src/content/blog/`
carrying the same `pr:` and, if its filename differs, renames it into place
(`git mv`) rather than publishing a duplicate. It then overwrites that file if
its `pr:` matches (safe re-run), aborts if `pr:` differs (an unrelated post
happens to have the same slug), and no-ops if the content is unchanged.

## Model

`claude-haiku-4.5` (free tier). Configurable in `post-on-merge.yml` →
`ai-inference` `model:` input.

## Phase 2 (planned)

- Extract this workflow into a **reusable workflow** in `giacchetta/.github`
  so every `lab`-topic PoC repo gets the pipeline by calling
  `uses: giacchetta/.github/.github/workflows/post-on-merge.yml@v1`.
- Add the company repo (`www_gianet_us`) as a second target, gated by a PR
  label (default on; suppress with `personal-only`).
