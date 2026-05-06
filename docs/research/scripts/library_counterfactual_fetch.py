#!/usr/bin/env python3
"""Webfetch counterfactual measurement for Library MCP compaction claims.

Replicates the one-sheet's anchor methodology so successive runs are
apples-to-apples:

  - Python urllib fetch with a desktop-Firefox UA
  - regex HTML stripping (scripts/styles/comments/tags removed; basic
    entities decoded; no readability extractor)
  - chars / 4 token estimate

The regex strip is conservative -- it leaves nav/footer text that a
real readability extractor would drop -- so the counterfactual is a
lower bound, not an upper bound. That's the point: Library's reported
savings should hold up against a *generous* alternative.

Usage:
  Edit QUERIES below to a set of {label: [5 source urls]} mappings,
  then run. Output is per-source token counts, per-query totals, and
  the cross-query average.

Original anchor measurement (2026-05-02 session, captured in the
one-sheet):
  5 sources, 13,907 tokens, 42.8x compaction ratio against a 325-tok
  Library response.

Second measurement (2026-05-05 session, two queries from a 15-call
research funnel on WhatsApp Web automation):
  10 sources across 2 queries, average 9,167 tokens/query (range
  8,478-9,856), 21.5x-22.1x compaction ratio against ~420-tok
  Library responses. The lower ratio reflects topic-dependent source
  bloat -- the original anchor happened to hit heavier pages.
"""

import re
import urllib.error
import urllib.request

UA = "Mozilla/5.0 (X11; Linux x86_64) Gecko/20100101 Firefox/126.0"

# Edit this dict for each new measurement run. Five sources per query
# matches Library's default `count: 5`.
QUERIES = {
    "Q3 (wa-js + headless Firefox)": [
        "https://community.latenode.com/t/running-whatsapp-web-in-a-headless-browser-for-automation/12001",
        "https://osrepos.com/repo/wppconnect-team-wa-js",
        "https://github.com/wppconnect-team/wa-js",
        "https://wppconnect.io/wa-js/",
        "https://dev.to/syed_mudasseranayat_e251/automating-whatsapp-with-venom-bot-a-complete-guide-1npf",
    ],
    "Q13 (browser bg throttling)": [
        "https://www.ghacks.net/2020/07/06/chrome-javascript-throttling-experiment-improves-battery-significantly/",
        "https://support.google.com/chrome/thread/106318946",
        "https://aboutfrontend.blog/tab-throttling-in-browsers/",
        "https://www.likeitall.com/throttle",
        "https://bugzilla.mozilla.org/show_bug.cgi?id=1181073",
    ],
}


def strip_html(html: str) -> str:
    """Remove scripts/styles/comments, then all tags, then collapse whitespace."""
    html = re.sub(r"<script[^>]*>.*?</script>", " ", html, flags=re.DOTALL | re.IGNORECASE)
    html = re.sub(r"<style[^>]*>.*?</style>", " ", html, flags=re.DOTALL | re.IGNORECASE)
    html = re.sub(r"<!--.*?-->", " ", html, flags=re.DOTALL)
    html = re.sub(r"<[^>]+>", " ", html)
    html = (
        html.replace("&nbsp;", " ")
        .replace("&amp;", "&")
        .replace("&lt;", "<")
        .replace("&gt;", ">")
    )
    html = re.sub(r"\s+", " ", html).strip()
    return html


def fetch(url: str, timeout: int = 20) -> tuple[int, str]:
    req = urllib.request.Request(
        url,
        headers={"User-Agent": UA, "Accept": "text/html,application/xhtml+xml"},
    )
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            data = r.read()
            charset = r.headers.get_content_charset() or "utf-8"
            return r.status, data.decode(charset, errors="replace")
    except urllib.error.HTTPError as e:
        return e.code, ""
    except Exception as e:
        return 0, f"<error {type(e).__name__}: {e}>"


def main() -> None:
    grand_total = 0
    counts: dict[str, int] = {}
    for label, urls in QUERIES.items():
        print(f"\n=== {label} ===")
        per_query = 0
        for u in urls:
            status, html = fetch(u)
            text = strip_html(html) if status == 200 else ""
            chars = len(text)
            tokens = chars // 4
            per_query += tokens
            print(f"  [{status}] {tokens:>6} tok  {chars:>7} chars  {u}")
        print(f"  --> per-query total: {per_query} tokens")
        counts[label] = per_query
        grand_total += per_query
    print("\n=== Summary ===")
    for label, t in counts.items():
        print(f"  {label}: {t} tokens")
    if counts:
        print(f"  Average across {len(counts)} queries: {grand_total // len(counts)} tokens")


if __name__ == "__main__":
    main()
