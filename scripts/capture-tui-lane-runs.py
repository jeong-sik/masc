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
    03-lane-run-detail.png — Enter on an exact-output run: sticky decision,
        execution, and Tool summaries above side-by-side prompt/model JSON.
    04-verifier-run-list.png — Verifier's retained Task/Goal decisions with
        SUBJECT and STATUS columns.
    05-verifier-run-detail.png — A completed Verifier decision with its
        request beside the verdict and typed Tool evidence.

Usage:
    python3 scripts/capture-tui-lane-runs.py \
        --base-path ~/me --out /tmp/tui-lane-runs

Requires the live server on --api-port (default 8935) and a built TUI passed
with --executable (defaults to _build/default/bin/masc_tui.exe).
"""

from __future__ import annotations

import argparse
from contextlib import contextmanager
from datetime import datetime, timezone
import hashlib
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
DEFAULT_EXECUTABLE = WORKTREE / "_build/default/bin/masc_tui.exe"

# The whole capture is one connected trip through the drill-down; the frame
# list documents what each shot must prove, and main() walks it in order.
LANE_ROW_RE = re.compile(r"\bactive\s+\d+\s+runs\s+\d+\s+ok/fail/cancel\b")
TERMINAL_VERIFIER_STATUSES = (
    "approved",
    "rejected",
    "reviewed",
    "committed",
    "deferred",
    "review_cancelled",
    "infrastructure_unavailable",
    "not_reviewed",
    "commit_failed",
    "raised",
)
RUN_STATUS_COLUMN_CELLS = 11

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
        (
            d.name
            for d in keepers.iterdir()
            if d.is_dir() and not d.name.startswith(".")
        ),
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
    browser: Browser,
    base: Path,
    api_port: int,
    cols: int,
    rows: int,
    workspace: str,
    executable: Path,
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
        str(TTYD),
        "-p",
        str(web_port),
        "-i",
        "127.0.0.1",
        "-W",
        "-t",
        "rendererType=dom",
        "-t",
        "fontSize=14",
        "-t",
        "fontFamily=Menlo",
        "-T",
        "xterm-256color",
        str(executable),
        "--base-path",
        str(base),
        "--workspace",
        workspace,
        "--port",
        str(api_port),
        "--refresh",
        "60",
    ]
    process = subprocess.Popen(
        command,
        cwd=WORKTREE,
        env=env,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        start_new_session=True,
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


def standalone_lane_index(text: str, label: str) -> int:
    """Return the row index of an exact standalone label.

    The matrix rows own the `active/runs/ok/fail/cancel` tuple. Matching that
    typed projection keeps the selected-row detail prose from becoming a
    second, accidental lane list.
    """
    rows = [line for line in text.splitlines() if LANE_ROW_RE.search(line)]
    matches = [index for index, line in enumerate(rows) if label in line]
    if len(matches) != 1:
        raise WaitFailed(
            f"expected one standalone lane row for {label!r}, found {len(matches)}"
        )
    return matches[0]


def select_standalone_lane(page: Page, label: str) -> None:
    """Select a lane by the matrix the operator can see, not by a fixed count."""
    select_board_attention(page)
    index = standalone_lane_index(screen_text(page), label)
    if index:
        press(page, "j", times=index)
    wait_text(page, f"{label} ·")


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
        # Run rows own a timestamp in the STARTED column. The surface is
        # borderless, so a box glyph is not part of row identity.
        if re.search(r"\b\d{2}-\d{2} \d{2}:\d{2}:\d{2}\b", line):
            if "succeeded" in line:
                return index
            index += 1
    return 0


def first_terminal_verifier_row(text: str) -> tuple[int, str]:
    """Return the first completed Verifier row and its typed status label."""
    lines = text.splitlines()
    try:
        header = next(i for i, line in enumerate(lines) if "RUN ID" in line)
    except StopIteration as error:
        raise WaitFailed("Verifier run list has no RUN ID header") from error
    index = 0
    for line in lines[header + 1 :]:
        if re.search(r"\b\d{2}-\d{2} \d{2}:\d{2}:\d{2}\b", line):
            for status in TERMINAL_VERIFIER_STATUSES:
                displayed = (
                    status
                    if len(status) <= RUN_STATUS_COLUMN_CELLS
                    else status[: RUN_STATUS_COLUMN_CELLS - 1] + "~"
                )
                if displayed in line:
                    return index, status
            index += 1
    raise WaitFailed("Verifier has no retained terminal decision to capture")


def require_split_heading(text: str, left: str, right: str) -> None:
    if not any(
        left in line and "│" in line and right in line for line in text.splitlines()
    ):
        raise WaitFailed(
            f"Input/Output split heading is absent: left={left!r}, right={right!r}"
        )


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


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
    ap.add_argument("--executable", type=Path, default=DEFAULT_EXECUTABLE)
    args = ap.parse_args()

    if not TTYD.is_file():
        print(f"missing ttyd: {TTYD}", file=sys.stderr)
        return 1
    executable = args.executable.expanduser().resolve()
    if not executable.is_file():
        print(f"missing TUI executable: {executable}", file=sys.stderr)
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
                browser,
                base,
                args.api_port,
                args.cols,
                args.rows,
                args.workspace,
                executable,
            ) as page:
                dims = page.evaluate(
                    "() => ({cols: window.term.cols, rows: window.term.rows})"
                )

                goto_lanes(page)

                # 1. Overview, selection band on the first standalone row.
                select_standalone_lane(page, "Board Attention")
                saved.append(
                    capture(page, pairs, args.out, "01-lanes-overview-standalone")
                )
                saved[-1]["selected_row"] = "Board Attention"

                # 2. Enter opens the lane's run list over HTTP. Landing on
                # "Board Attention" here also proves frame 1's selection.
                press(page, "Enter")
                text = wait_text(
                    page, "Board Attention", "RUN ID", "Right / Enter:prompt"
                )
                page.wait_for_timeout(500)
                saved.append(capture(page, pairs, args.out, "02-lane-run-list"))
                saved[-1]["lane"] = "Board Attention"

                # 3. Enter on the first completed run (cursor starts on the
                # newest; a still-running run has no OUTPUT payload yet).
                run_index = first_succeeded_row_index(text)
                if run_index:
                    press(page, "j", times=run_index)
                press(page, "Enter")
                exact_detail = wait_text(
                    page,
                    "MASC Lane Run",
                    "DECISION  NOT A VERDICT",
                    "TOOLS  none",
                    "INPUT · PROMPT PAYLOAD",
                    "OUTPUT · MODEL RESPONSE",
                    "j/k:compare",
                )
                require_split_heading(
                    exact_detail, "INPUT · PROMPT PAYLOAD", "OUTPUT · MODEL RESPONSE"
                )
                page.wait_for_timeout(500)
                saved.append(capture(page, pairs, args.out, "03-lane-run-detail"))
                saved[-1]["run_cursor_index"] = run_index
                saved[-1]["decision"] = "not_a_verdict"
                saved[-1]["layout"] = "side_by_side"

                # 4. Back to the overview (Esc detail -> list, Esc list ->
                # overview), then open the Verifier decision ledger.
                press(page, "Escape")
                wait_text(page, "RUN ID")
                press(page, "Escape")
                wait_text(page, "Standalone LLM lanes", "Board Attention")
                select_standalone_lane(page, "Verifier")
                press(page, "Enter")
                verifier_list = wait_text(
                    page, "MASC Lanes", "Verifier", "SUBJECT", "RUN ID"
                )
                page.wait_for_timeout(500)
                saved.append(capture(page, pairs, args.out, "04-verifier-run-list"))
                verifier_index, verifier_status = first_terminal_verifier_row(
                    verifier_list
                )
                if verifier_index:
                    press(page, "j", times=verifier_index)
                press(page, "Enter")
                verifier_detail = wait_text(
                    page,
                    "MASC Lane Run",
                    "DECISION",
                    "TOOLS",
                    "INPUT · VERIFICATION REQUEST",
                    "OUTPUT · VERDICT + TOOL EVIDENCE",
                )
                require_split_heading(
                    verifier_detail,
                    "INPUT · VERIFICATION REQUEST",
                    "OUTPUT · VERDICT + TOOL EVIDENCE",
                )
                page.wait_for_timeout(500)
                saved.append(capture(page, pairs, args.out, "05-verifier-run-detail"))
                saved[-1]["run_cursor_index"] = verifier_index
                saved[-1]["verdict_status"] = verifier_status
                saved[-1]["layout"] = "side_by_side"
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
        "executable": {
            "path": str(executable),
            "bytes": executable.stat().st_size,
            "sha256": sha256_file(executable),
        },
        "terminal": dims,
        "api_port": args.api_port,
        "keeper_names_redacted": len(names),
        "frames": saved,
    }
    (args.out / "evidence.json").write_text(
        json.dumps(evidence, indent=2) + "\n", encoding="utf-8"
    )
    print(f"wrote {args.out / 'evidence.json'}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
