#!/usr/bin/env python3
"""sanitize-post.py — escape bare `<word>`-style tokens in a generated post body.

Why this exists (production incident, PR #13): the model wrote a bullet
containing the literal text `bundle-mcp:<server>__<tool>`, not wrapped in
backticks. In Markdown, an un-backticked `<word>` is parsed as raw inline
HTML. `<server>`/`<tool>` aren't real elements and are never closed, so they
pass straight through into the built page's HTML as bare, unclosed tags.
Downstream, the site's astro-llms-md plugin parses each built page with
node-html-parser and does `root.querySelector('main')` to extract page
content for .md/llms.txt generation. The unclosed tags corrupt that parser's
tree construction badly enough that <body>/<main> disappear from the parsed
tree entirely — querySelector('main') returns null, so the extracted content
is silently empty. No build error. Only the frontmatter (title/url/
description, sourced from <h1>/<meta>) survives.

This script rewrites any such offending run into a single inline-code span
(backtick-wrapped), matching the hand-applied fix in the target site repo
(commit 3ee96d6, "post: minor backtick fix"). It:

  - only touches the BODY (everything after the closing frontmatter `---`
    fence); the frontmatter is copied through byte-for-byte, since it's YAML
    consumed by Astro and this pipeline's standing rule (see prepare-post.sh)
    is to never parse or rewrite it here.
  - never touches text already inside a fenced code block or an inline code
    span (idempotent: re-running it on an already-fixed post is a no-op).
  - leaves real HTML tags (a fixed allowlist), Markdown autolinks
    (`<https://...>`, `<user@host>`), and HTML comments alone.
  - expands the wrap to cover the whole adjoining identifier run (e.g.
    `bundle-mcp:<server>__<tool>`), not just the bracketed piece, so the
    reproduced output matches the hand-applied fix exactly.
  - never fails the job: it fixes and emits a `::warning::` per rewritten
    line so the run is visible without blocking the PR (this pipeline
    deliberately favors lenient extraction + human review over hard gates,
    per commit 359613c).

Usage:
    python3 sanitize-post.py <infile> <outfile>
    python3 sanitize-post.py --self-test
"""
from __future__ import annotations

import re
import string
import sys
from pathlib import Path

# Real HTML element names we leave alone when seen as `<name ...>` or
# `</name>`. Deliberately conservative — anything not on this list is
# presumed to be a code identifier / placeholder, not markup.
ALLOWED_TAGS = {
    "a", "abbr", "b", "blockquote", "br", "code", "del", "details", "div",
    "em", "h1", "h2", "h3", "h4", "h5", "h6", "hr", "i", "img", "ins",
    "kbd", "li", "mark", "ol", "p", "pre", "q", "s", "small", "span",
    "strong", "sub", "summary", "sup", "table", "tbody", "td", "th",
    "thead", "tr", "ul",
}

AUTOLINK_RE = re.compile(
    r"^<(?:https?|ftp)://[^\s<>]+>$"
    r"|^<mailto:[^\s<>@]+@[^\s<>@]+>$"
    r"|^<[^\s<>@]+@[^\s<>@]+\.[^\s<>@]+>$",
    re.IGNORECASE,
)
TAG_NAME_RE = re.compile(r"^/?([a-zA-Z][a-zA-Z0-9-]*)")
ANGLE_TOKEN_RE = re.compile(r"<[^<>\n]*>")
FENCE_RE = re.compile(r"^ {0,3}(`{3,}|~{3,})")
BACKTICK_RUN_RE = re.compile(r"`+")

# Characters absorbed while expanding an offending span outward so the whole
# adjoining identifier (e.g. `bundle-mcp:` or `main/IDENTITY.md`) is wrapped,
# not just the bracketed token itself.
LEFT_CHARS = set(string.ascii_letters + string.digits + "_-/:.@")
RIGHT_CHARS = set(string.ascii_letters + string.digits + "_-/")


def _is_comment(content: str) -> bool:
    return content.startswith("!--") and content.endswith("--")


def _is_real_tag(content: str) -> bool:
    m = TAG_NAME_RE.match(content)
    if not m:
        return False
    return m.group(1).lower() in ALLOWED_TAGS


def _is_ignorable(match_text: str) -> bool:
    """True if this `<...>` run should be left exactly as-is."""
    inner = match_text[1:-1]
    if _is_comment(inner):
        return True
    if _is_real_tag(inner):
        return True
    if AUTOLINK_RE.match(match_text):
        return True
    return False


def _protected_ranges(line: str) -> list[bool]:
    """Per-character mask: True where the char sits inside an inline code
    span (a backtick run matched with a same-length closing run), per the
    CommonMark rule of pairing the first same-length run found."""
    protected = [False] * len(line)
    ticks = list(BACKTICK_RUN_RE.finditer(line))
    i = 0
    while i < len(ticks):
        opening = ticks[i]
        n = len(opening.group())
        matched = False
        for j in range(i + 1, len(ticks)):
            if len(ticks[j].group()) == n:
                for k in range(opening.start(), ticks[j].end()):
                    protected[k] = True
                i = j + 1
                matched = True
                break
        if not matched:
            i += 1
    return protected


def _expand_left(line: str, protected: list[bool], start: int) -> int:
    while start > 0 and line[start - 1] in LEFT_CHARS and not protected[start - 1]:
        start -= 1
    return start


def _expand_right(line: str, protected: list[bool], end: int) -> int:
    n = len(line)
    while True:
        advanced = False
        while end < n and line[end] in RIGHT_CHARS and not protected[end]:
            end += 1
            advanced = True
        if (
            end < n
            and line[end] in ".:"
            and not protected[end]
            and end + 1 < n
            and line[end + 1].isalnum()
            and not protected[end + 1]
        ):
            end += 1
            advanced = True
        if not advanced:
            break
    return end


def _sanitize_line(line: str, line_no: int) -> tuple[str, list[str]]:
    """Wrap offending `<...>` runs (expanded to their full identifier) in
    backticks. Returns (new_line, warning_messages)."""
    protected = _protected_ranges(line)
    spans: list[tuple[int, int]] = []

    for m in ANGLE_TOKEN_RE.finditer(line):
        start, end = m.start(), m.end()
        if all(protected[start:end]):
            continue  # already inside an inline code span
        if any(protected[start:end]):
            continue  # partially inside a code span — don't risk corrupting it
        if _is_ignorable(m.group()):
            continue
        spans.append((_expand_left(line, protected, start), _expand_right(line, protected, end)))

    if not spans:
        return line, []

    spans.sort()
    merged: list[list[int]] = []
    for s, e in spans:
        if merged and s <= merged[-1][1]:
            merged[-1][1] = max(merged[-1][1], e)
        else:
            merged.append([s, e])

    warnings = []
    new_line = line
    for start, end in sorted(merged, reverse=True):
        raw = new_line[start:end]
        new_line = new_line[:start] + "`" + raw + "`" + new_line[end:]
        warnings.append(
            f"::warning::sanitize-post: wrapped raw HTML-like token on line {line_no}: "
            f"{raw!r} -> `{raw}`"
        )
    return new_line, list(reversed(warnings))


def _split_frontmatter(raw: str) -> tuple[list[str], list[str]]:
    """Return (header_lines, body_lines); header_lines includes both `---`
    fences and everything between (copied through untouched)."""
    lines = raw.split("\n")
    if lines and lines[0].rstrip() == "---":
        for i in range(1, len(lines)):
            if re.match(r"^---\s*$", lines[i]):
                return lines[: i + 1], lines[i + 1 :]
    return [], lines


def sanitize(raw: str) -> tuple[str, list[str]]:
    header_lines, body_lines = _split_frontmatter(raw)
    out_lines: list[str] = []
    all_warnings: list[str] = []

    in_fence = False
    fence_char = ""
    fence_len = 0

    for idx, line in enumerate(body_lines):
        abs_line_no = len(header_lines) + idx + 1

        if in_fence:
            out_lines.append(line)
            stripped = line.strip()
            if (
                stripped[: fence_len if fence_len else 0] == fence_char * fence_len
                and set(stripped) <= {fence_char}
                and len(stripped) >= fence_len
            ):
                in_fence = False
            continue

        m = FENCE_RE.match(line)
        if m:
            fence_char = m.group(1)[0]
            fence_len = len(m.group(1))
            in_fence = True
            out_lines.append(line)
            continue

        new_line, warnings = _sanitize_line(line, abs_line_no)
        out_lines.append(new_line)
        all_warnings.extend(warnings)

    return "\n".join(header_lines + out_lines), all_warnings


# --------------------------------------------------------------------------
# Self-tests (no external framework/deps — none exist in this repo).
# --------------------------------------------------------------------------

_SELF_TESTS: list[tuple[str, str, str]] = [
    (
        "real bug: bundle-mcp tool token, with sentence-ending period",
        "---\nslug: x\n---\n"
        "- 🧰 Local MCPs: added filesystem MCP for Coder and memory MCP for "
        "Researcher; tools surface as bundle-mcp:<server>__<tool>.\n",
        "---\nslug: x\n---\n"
        "- 🧰 Local MCPs: added filesystem MCP for Coder and memory MCP for "
        "Researcher; tools surface as `bundle-mcp:<server>__<tool>`.\n",
    ),
    (
        "idempotent on already-backticked form",
        "---\nslug: x\n---\n"
        "- tools surface as `bundle-mcp:<server>__<tool>`.\n",
        "---\nslug: x\n---\n"
        "- tools surface as `bundle-mcp:<server>__<tool>`.\n",
    ),
    (
        "markdown autolink left untouched",
        "---\nslug: x\n---\nSee <https://example.com/path> for details.\n",
        "---\nslug: x\n---\nSee <https://example.com/path> for details.\n",
    ),
    (
        "real html tags left untouched",
        "---\nslug: x\n---\nA line with <br> and some <strong>bold</strong> text.\n",
        "---\nslug: x\n---\nA line with <br> and some <strong>bold</strong> text.\n",
    ),
    (
        "fenced code block left untouched",
        "---\nslug: x\n---\n```\nraw <not><escaped> here\n```\nnormal <token> outside\n",
        "---\nslug: x\n---\n```\nraw <not><escaped> here\n```\nnormal `<token>` outside\n",
    ),
    (
        "bold-wrapped placeholder: stars stay outside the backticks",
        "---\nslug: x\n---\nSet **<placeholder>** before running.\n",
        "---\nslug: x\n---\nSet **`<placeholder>`** before running.\n",
    ),
    (
        "adjoining path-like identifier absorbed on both sides",
        "---\nslug: x\n---\nSee main/<agent>/IDENTITY.md for the prompt.\n",
        "---\nslug: x\n---\nSee `main/<agent>/IDENTITY.md` for the prompt.\n",
    ),
    (
        "frontmatter passed through byte-for-byte, even if it looks odd",
        '---\nslug: x\ntitle: "A <weird> Title"\n---\nBody text.\n',
        '---\nslug: x\ntitle: "A <weird> Title"\n---\nBody text.\n',
    ),
    (
        "no frontmatter at all — whole doc treated as body",
        "Just a line with a <bare> token.\n",
        "Just a line with a `<bare>` token.\n",
    ),
]


def run_self_tests() -> int:
    passed = 0
    failed = 0
    for name, given, expected in _SELF_TESTS:
        got, _warnings = sanitize(given)
        if got == expected:
            passed += 1
        else:
            failed += 1
            print(f"FAIL: {name}", file=sys.stderr)
            print(f"  expected: {expected!r}", file=sys.stderr)
            print(f"  got:      {got!r}", file=sys.stderr)
    total = passed + failed
    print(f"sanitize-post: {passed}/{total} self-tests passed")
    return 0 if failed == 0 else 1


def main() -> int:
    if len(sys.argv) == 2 and sys.argv[1] == "--self-test":
        return run_self_tests()
    if len(sys.argv) != 3:
        print(
            "usage: sanitize-post.py <infile> <outfile>  |  sanitize-post.py --self-test",
            file=sys.stderr,
        )
        return 2

    infile, outfile = sys.argv[1], sys.argv[2]
    raw = Path(infile).read_text(encoding="utf-8")
    sanitized, warnings = sanitize(raw)
    Path(outfile).write_text(sanitized, encoding="utf-8")
    for w in warnings:
        print(w)
    return 0


if __name__ == "__main__":
    sys.exit(main())
