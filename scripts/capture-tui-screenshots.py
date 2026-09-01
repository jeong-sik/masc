#!/usr/bin/env python3
"""Capture terminal UI surfaces from a live runtime, for the README and docs.

ttyd serves masc-tui over HTTP and Chromium screenshots the terminal element,
which is how the existing capture-tui-* proofs work. This one is not a proof:
it walks a few surfaces and saves presentable frames.

Keeper names are replaced before each shot. The replacement keeps the original
length, because a terminal is a fixed-width grid and a shorter name would shift
every cell after it on that row.

Usage:
    python3 scripts/capture-tui-screenshots.py \
        --base-path ~/me --out docs/screenshots/tui/$(date -u +%Y-%m-%d)/surfaces
"""

from __future__ import annotations

import argparse
from contextlib import contextmanager
from datetime import datetime, timezone
import json
import os
from pathlib import Path
import socket
import subprocess
import sys
import time
from typing import Iterator

from playwright.sync_api import Browser, Page, sync_playwright

WORKTREE = Path(__file__).resolve().parents[1]
TTYD = Path("/opt/homebrew/bin/ttyd")
EXECUTABLE = WORKTREE / "_build/default/bin/masc_tui.exe"

# (file stem, palette query, text the header must show once we land there)
SURFACES: list[tuple[str, str, str]] = [
    ("01-overview", "go overview", "MASC Overview"),
    ("02-keepers", "go keepers", "MASC Keepers"),
    ("03-lanes", "go lanes", "MASC Lanes"),
    ("05-approvals", "go approvals", "MASC Approvals"),
    ("06-activity", "go activity", "MASC Activity"),
]
# Board is deliberately absent. Its rows are free-text post titles written by
# whoever posted them, and no name-and-path rule can promise a title carries
# nothing that should stay private. Structural surfaces are safe to publish
# because their cells are ids, states, and model names.
_UNCAPTURED = [
    ("board", "rows are operator-authored free text"),
]

# Length-preserving placeholder: a terminal row is a grid, so a replacement that
# is shorter than the name it covers moves every cell after it.
REDACT_JS = r"""
(pairs) => {
  const rules = pairs.map(([from, to]) => [new RegExp(from.replace(/[.*+?^${}()|[\]\\]/g, '\\$&'), 'g'), to]);
  // Same rule for the footer's base path: keep the width, drop the identity.
  const pad = (s, n) => (s.length >= n ? s.slice(0, n) : s + ' '.repeat(n - s.length));
  const scrubPaths = (t) => t.replace(/\/Users\/[A-Za-z0-9._-]+(?:\/[A-Za-z0-9._-]+)*/g,
    (m) => pad('/home/demo/project', m.length));
  const scrub = (t) => rules.reduce((acc, [re, to]) => acc.replace(re, to), scrubPaths(t));
  const it = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT);
  const nodes = [];
  while (it.nextNode()) nodes.push(it.currentNode);
  for (const n of nodes) {
    const next = scrub(n.nodeValue);
    if (next !== n.nodeValue) n.nodeValue = next;
  }
};
"""


def placeholder_for(name: str, index: int) -> str:
    """A distinct stand-in of exactly len(name) characters."""
    # `kpr-01` needs six cells. A shorter name gets the compact `k01` form so
    # two different keepers never truncate onto the same token.
    base = f"kpr-{index:02d}" if len(name) >= 6 else f"k{index:02d}"
    if len(base) >= len(name):
        return base[: len(name)]
    return base + " " * (len(name) - len(base))


def discover_keeper_names(base_path: Path) -> list[str]:
    keepers = base_path / ".masc" / "keepers"
    if not keepers.is_dir():
        return []
    return sorted(
        (d.name for d in keepers.iterdir() if d.is_dir() and not d.name.startswith(".")),
        key=len,
        reverse=True,
    )


def free_port() -> int:
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        return int(sock.getsockname()[1])


def wait_port(port: int, process: subprocess.Popen, timeout: float = 20.0) -> None:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if process.poll() is not None:
            raise RuntimeError(f"ttyd exited early with {process.returncode}")
        with socket.socket() as sock:
            sock.settimeout(0.5)
            if sock.connect_ex(("127.0.0.1", port)) == 0:
                return
        time.sleep(0.2)
    raise TimeoutError("ttyd did not listen")


@contextmanager
def ttyd_session(
    browser: Browser, base: Path, api_port: int, cols: int, rows: int, workspace: str
) -> Iterator[Page]:
    web_port = free_port()
    env = dict(os.environ)
    # An operator shell that exports NO_COLOR=1 would otherwise blank every
    # colour the TUI draws, and the README frames would come out monochrome.
    env.pop("NO_COLOR", None)
    env.update(
        {
            "MASC_BASE_PATH": str(base),
            "MASC_TUI_FORCE_COLOR": "1",
            "MASC_TUI_SYNC": "off",
            "TERM": "xterm-256color",
            "NO_PROXY": "127.0.0.1,localhost",
            "no_proxy": "127.0.0.1,localhost",
        }
    )
    command = [
        str(TTYD), "-p", str(web_port), "-i", "127.0.0.1", "-W",
        "-t", "rendererType=dom", "-t", "fontSize=14", "-t", "fontFamily=Menlo",
        "-T", "xterm-256color", str(EXECUTABLE), "--base-path", str(base),
        "--workspace", workspace, "--port", str(api_port), "--refresh", "60",
    ]
    process = subprocess.Popen(
        command, cwd=WORKTREE, env=env,
        stdout=subprocess.PIPE, stderr=subprocess.STDOUT, start_new_session=True,
    )
    context = None
    try:
        wait_port(web_port, process)
        # Character cell is about 8.4 x 17 at Menlo 14; pad so ttyd fits the grid.
        context = browser.new_context(
            viewport={"width": int(cols * 8.5) + 24, "height": int(rows * 17) + 24},
            device_scale_factor=2,
        )
        page = context.new_page()
        page.goto(f"http://127.0.0.1:{web_port}", wait_until="domcontentloaded")
        page.wait_for_selector(".xterm-helper-textarea", timeout=15_000)
        page.wait_for_function("window.term && window.term.rows > 0", timeout=15_000)
        page.wait_for_timeout(4_000)
        yield page
    finally:
        if context is not None:
            context.close()
        process.terminate()
        try:
            process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            process.kill()


def screen_text(page: Page) -> str:
    return page.locator(".xterm-screen").inner_text()


def goto_surface(page: Page, query: str, expect: str) -> bool:
    box = page.locator(".xterm-helper-textarea")
    box.focus()
    page.keyboard.press("Escape")
    page.wait_for_timeout(200)
    page.keyboard.press(":")
    page.wait_for_timeout(400)
    page.keyboard.type(query, delay=25)
    page.wait_for_timeout(500)
    page.keyboard.press("Enter")
    for _ in range(20):
        page.wait_for_timeout(500)
        if expect in screen_text(page):
            page.wait_for_timeout(1_500)
            return True
    return False


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--base-path", default=str(Path.home() / "me"))
    ap.add_argument("--api-port", type=int, default=8935)
    ap.add_argument("--out", required=True, type=Path)
    ap.add_argument("--cols", type=int, default=132)
    ap.add_argument("--rows", type=int, default=26)
    ap.add_argument("--workspace", default="demo-workspace")
    args = ap.parse_args()

    if not TTYD.is_file():
        print(f"missing ttyd: {TTYD}", file=sys.stderr)
        return 1
    if not EXECUTABLE.is_file():
        print(f"missing {EXECUTABLE}; run dune build --root . bin/masc_tui.exe", file=sys.stderr)
        return 1

    base = Path(args.base_path).expanduser()
    names = discover_keeper_names(base)
    pairs = [[n, placeholder_for(n, i + 1)] for i, n in enumerate(names)]
    args.out.mkdir(parents=True, exist_ok=True)

    saved: list[dict] = []
    with sync_playwright() as pw:
        browser = pw.chromium.launch()
        with ttyd_session(browser, base, args.api_port, args.cols, args.rows, args.workspace) as page:
            dims = page.evaluate("() => ({cols: window.term.cols, rows: window.term.rows})")
            for stem, query, expect in SURFACES:
                landed = goto_surface(page, query, expect)
                if not landed:
                    print(f"skipped {stem}: never showed {expect!r}", file=sys.stderr)
                    continue
                page.evaluate(REDACT_JS, pairs)
                page.wait_for_timeout(200)
                target = args.out / f"{stem}.png"
                page.locator(".xterm-screen").screenshot(path=str(target))
                saved.append({"file": target.name, "surface": expect, "query": query})
                print(f"captured {target}")
        browser.close()

    evidence = {
        "captured_utc": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "commit": subprocess.run(
            ["git", "rev-parse", "HEAD"], capture_output=True, text=True, check=True
        ).stdout.strip(),
        "terminal": dims,
        "api_port": args.api_port,
        "keeper_names_redacted": len(names),
        "frames": saved,
    }
    (args.out / "evidence.json").write_text(json.dumps(evidence, indent=2) + "\n", encoding="utf-8")
    print(f"wrote {args.out / 'evidence.json'}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
