"""Fetch each URL and report whether each expected phrase appears verbatim.

Whitespace is collapsed and HTML tags/entities are stripped before matching,
so a phrase split across inline tags still matches. Curly quotes are folded
to straight quotes on both sides. Nothing is written to disk.
"""

from __future__ import annotations

import html
import json
import re
import sys
import urllib.error
import urllib.request

USER_AGENT = "Mozilla/5.0 (compatible; quote-check)"
TIMEOUT_SECONDS = 25
TAG_RE = re.compile(r"<[^>]+>")
SPACE_RE = re.compile(r"\s+")
QUOTE_FOLD = str.maketrans({"‘": "'", "’": "'", "“": '"', "”": '"', " ": " "})


def normalize(text: str) -> str:
    text = TAG_RE.sub(" ", text)
    text = html.unescape(text)
    text = text.translate(QUOTE_FOLD)
    return SPACE_RE.sub(" ", text).strip().lower()


def fetch(url: str) -> tuple[int, str]:
    request = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
    try:
        with urllib.request.urlopen(request, timeout=TIMEOUT_SECONDS) as response:
            return response.status, response.read().decode("utf-8", errors="replace")
    except urllib.error.HTTPError as error:
        return error.code, ""
    except (urllib.error.URLError, TimeoutError) as error:
        print(f"  fetch error: {error}")
        return 0, ""


def main(path: str) -> int:
    with open(path, encoding="utf-8") as handle:
        cases = json.load(handle)
    missing = 0
    for case in cases:
        status, body = fetch(case["url"])
        page = normalize(body)
        print(f"{case['url']} -> HTTP {status}, {len(page)} chars")
        for phrase in case["phrases"]:
            found = normalize(phrase) in page
            missing += 0 if found else 1
            print(f"  [{'OK' if found else 'MISSING'}] {phrase}")
    return 1 if missing else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1]))
