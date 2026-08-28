#!/usr/bin/env python3
"""Capture the TUI Lanes drill-down (standalone lane -> run list -> run detail)
from a live runtime, as proof material for the drill-down's behaviour.

This is a proof-style sibling of capture-tui-screenshots.py, not part of its
README surface walk: run prompts and outputs are operational data, so these
frames go to a scratch/proof directory, not docs/. ttyd serves masc-tui over
HTTP and Chromium screenshots the terminal element, same as the other
capture-tui-* scripts. Keeper names and absolute paths are redacted before
each shot with the same length-preserving rule (run prompts can embed both).

Frames:
    01-lanes-overview-standalone.png — Lanes overview, cursor band on the
        Board Attention standalone row (k clamps at the first standalone row).
    02-lane-run-list.png — Enter on Board Attention: "MASC Lanes · Board
        Attention (N runs)", STARTED/ACTOR/STATUS/ELAPSED/SLOT/RUN ID columns.
    03-lane-run-detail.png — Enter on a run: "MASC Lane Run", RUN meta block,
        INPUT (prompt payload) / OUTPUT pretty JSON. If OUTPUT is below the
        fold the view pages down until the OUTPUT header is visible.
    04-verifier-no-llm.png — Enter on the Verifier lane: the notice that
        verifier runs record no LLM prompt/output. Matched on the substring
        "no LLM prompt/output" so the capture holds whether the notice is a
        one-line action error or a full pane.

Usage:
    python3 scripts/capture-tui-lane-runs.py \
        --base-path ~/me --out /tmp/tui-lane-runs

Requires the live server on --api-port (default 8935) and a built
_build/default/bin/masc_tui.exe (scripts/dune-local.sh build bin/masc_tui.exe).
"""

from __future__ import annotations

import argparse
from contextlib import contextmanager
from datetime import datetime, timezone
import json
import os
from pathlib import Path
import re
import socket
import subprocess
import sys
import time
from typing import Iterator

from playwright.sync_api import Browser, Page, sync_playwright

WORKTREE = Path(__file__).resolve().parents[1]
TTYD = Path("/opt/homebrew/bin/ttyd")
EXECUTABLE = WORKTREE / "_build/default/bin/masc_tui.exe"

# The whole capture is one connected trip through the drill-down; the frame
# list documents what each shot must prove, and main() walks it in order.
VERIFIER_NOTICE = "no LLM prompt/output"
# A whole line that is only the box border and the OUTPUT header; payload
# lines always carry JSON text after the indent, so this cannot match one.
OUTPUT_HEADER_RE = re.compile(r"│\s*OUTPUT\s*│")

# Length-preserving placeholder: a terminal row is a grid, so a replacement
# that is shorter than the name it covers moves every cell after it.
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


# A prefix shorter than this is too generic to redact safely; no keeper column
# truncates a name above ~18 cells, so 12 covers every truncation in practice.
MIN_PREFIX_LEN = 12


def redaction_pairs(names: list[str]) -> list[list[str]]:
    """(from, to) pairs for REDACT_JS, longest first.

    Besides each full name, every displayable prefix is covered: a table column
    truncates a long name to fit (the actor column swaps the last cell for
    "~"), and a truncated name no longer matches the full-name rule.
    """
    pairs: list[list[str]] = []
    for index, name in enumerate(names):
        placeholder = placeholder_for(name, index + 1)
        pairs.append([name, placeholder])
        for cut in range(MIN_PREFIX_LEN, len(name)):
            pairs.append([name[:cut], placeholder[:cut]])
    pairs.sort(key=lambda pair: len(pair[0]), reverse=True)
    return pairs


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
    # The operator shell exports NO_COLOR=1; inherited, it blanks every colour
    # the TUI draws, and the frames come out monochrome. Force colour for the
    # captured child only.
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


class WaitFailed(TimeoutError):
    """A marker never appeared; carries the screen text for the debug dump."""


def wait_text(page: Page, *needles: str, timeout: float = 20.0) -> str:
    """Poll the screen until every needle is visible; return the screen text.

    Run lists and run details load over HTTP, so this waits on rendered text
    instead of sleeping a fixed guess.
    """
    deadline = time.monotonic() + timeout
    text = ""
    while time.monotonic() < deadline:
        text = screen_text(page)
        if all(needle in text for needle in needles):
            return text
        page.wait_for_timeout(400)
    raise WaitFailed(
        f"markers {needles!r} not visible after {timeout:.0f}s\n--- screen ---\n{text}"
    )


def press(page: Page, key: str, times: int = 1) -> None:
    box = page.locator(".xterm-helper-textarea")
    box.focus()
    for _ in range(times):
        page.keyboard.press(key)
        page.wait_for_timeout(150)


def goto_lanes(page: Page) -> None:
    """Open the command palette and land on the Lanes overview."""
    box = page.locator(".xterm-helper-textarea")
    box.focus()
    page.keyboard.press("Escape")
    page.wait_for_timeout(200)
    page.keyboard.press(":")
    page.wait_for_timeout(400)
    page.keyboard.type("go lanes", delay=25)
    page.wait_for_timeout(500)
    page.keyboard.press("Enter")
    # "Board Attention" only renders once the standalone-lane snapshot has
    # loaded over HTTP, so this also covers the observation fetch.
    wait_text(page, "MASC Lanes", "Standalone LLM lanes", "Board Attention")
    page.wait_for_timeout(1_000)


def select_board_attention(page: Page) -> None:
    """k clamps at the first standalone row no matter where the cursor started
    (up past the first keeper row crosses onto the last standalone row)."""
    press(page, "k", times=10)
    page.wait_for_timeout(400)


def first_succeeded_row_index(text: str) -> int:
    """Index of the first run-list row whose STATUS reads succeeded, or 0.

    Rows sit below the RUN ID column header; a header/footer line never
    carries the status word.
    """
    lines = text.splitlines()
    try:
        header = next(i for i, line in enumerate(lines) if "RUN ID" in line)
    except StopIteration:
        return 0
    index = 0
    for line in lines[header + 1 :]:
        if "succeeded" in line:
            return index
        # Run rows are box lines with a timestamp in the STARTED column.
        if re.search(r"│\s*\d{2}-\d{2} \d{2}:\d{2}:\d{2}", line):
            index += 1
    return 0


def capture(page: Page, pairs: list[list[str]], out: Path, stem: str) -> dict:
    page.evaluate(REDACT_JS, pairs)
    page.wait_for_timeout(200)
    target = out / f"{stem}.png"
    page.locator(".xterm-screen").screenshot(path=str(target))
    print(f"captured {target}")
    return {"file": target.name, "frame": stem}


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--base-path", default=str(Path.home() / "me"))
    ap.add_argument("--api-port", type=int, default=8935)
    ap.add_argument("--out", required=True, type=Path)
    ap.add_argument("--cols", type=int, default=170)
    ap.add_argument("--rows", type=int, default=48)
    ap.add_argument("--workspace", default="demo-workspace")
    args = ap.parse_args()

    if not TTYD.is_file():
        print(f"missing ttyd: {TTYD}", file=sys.stderr)
        return 1
    if not EXECUTABLE.is_file():
        print(f"missing {EXECUTABLE}; run scripts/dune-local.sh build bin/masc_tui.exe", file=sys.stderr)
        return 1

    base = Path(args.base_path).expanduser()
    names = discover_keeper_names(base)
    pairs = redaction_pairs(names)
    args.out.mkdir(parents=True, exist_ok=True)

    saved: list[dict] = []
    with sync_playwright() as pw:
        browser = pw.chromium.launch()
        try:
            with ttyd_session(
                browser, base, args.api_port, args.cols, args.rows, args.workspace
            ) as page:
                dims = page.evaluate("() => ({cols: window.term.cols, rows: window.term.rows})")

                goto_lanes(page)

                # 1. Overview, selection band on the first standalone row.
                select_board_attention(page)
                saved.append(capture(page, pairs, args.out, "01-lanes-overview-standalone"))
                saved[-1]["selected_row"] = "Board Attention"

                # 2. Enter opens the lane's run list over HTTP. Landing on
                # "Board Attention" here also proves frame 1's selection.
                press(page, "Enter")
                text = wait_text(page, "Board Attention", "RUN ID", "Right / Enter:prompt")
                page.wait_for_timeout(500)
                saved.append(capture(page, pairs, args.out, "02-lane-run-list"))
                saved[-1]["lane"] = "Board Attention"

                # 3. Enter on the first completed run (cursor starts on the
                # newest; a still-running run has no OUTPUT payload yet).
                run_index = first_succeeded_row_index(text)
                if run_index:
                    press(page, "j", times=run_index)
                press(page, "Enter")
                wait_text(page, "MASC Lane Run", "INPUT (prompt payload)", "j/k:scroll")
                page.wait_for_timeout(500)
                # INPUT sits at the top; page down until the OUTPUT header is
                # visible too, so one frame shows both payloads' brackets.
                for _ in range(8):
                    if any(OUTPUT_HEADER_RE.search(line) for line in screen_text(page).splitlines()):
                        break
                    press(page, "PageDown")
                    page.wait_for_timeout(300)
                saved.append(capture(page, pairs, args.out, "03-lane-run-detail"))
                saved[-1]["run_cursor_index"] = run_index

                # 4. Back to the overview (Esc detail -> list, Esc list ->
                # overview), then onto the Verifier row for its notice.
                press(page, "Escape")
                wait_text(page, "RUN ID")
                press(page, "Escape")
                wait_text(page, "Standalone LLM lanes", "Board Attention")
                select_board_attention(page)
                press(page, "j", times=4)  # Board Attention -> Verifier
                press(page, "Enter")
                # Substring, not a mode title: the notice may be a one-line
                # action error in the overview or a full pane.
                wait_text(page, VERIFIER_NOTICE)
                page.wait_for_timeout(500)
                saved.append(capture(page, pairs, args.out, "04-verifier-no-llm"))
                saved[-1]["notice"] = VERIFIER_NOTICE
        except WaitFailed as error:
            dump = args.out / "debug-screen-dump.txt"
            dump.write_text(str(error), encoding="utf-8")
            print(f"capture failed; screen dump at {dump}\n{error}", file=sys.stderr)
            return 1
        finally:
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
