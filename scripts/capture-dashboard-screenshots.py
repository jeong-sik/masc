#!/usr/bin/env python3
"""Capture the dashboard screen inventory from a live loopback runtime.

The 2026-08-21 inventory was captured by hand and no script was kept, so the
next recapture started from nothing. This walks the same routes, redacts
operational identifiers in the page before each shot, and writes both the PNGs
and the inventory README.

Redaction replaces identifiers, not content: Keeper names collapse to
`demo-keeper`, absolute home paths become `/home/demo/project`, and long
numeric channel ids become zeros. A badge on every frame says the frame was
redacted, so a reader never mistakes a placeholder for a real name.

Usage:
    python3 scripts/capture-dashboard-screenshots.py \
        --base-path ~/me --out docs/screenshots/dashboard/$(date -u +%Y-%m-%d)
"""

from __future__ import annotations

import argparse
from datetime import datetime, timezone
import json
from pathlib import Path
import re
import subprocess
import sys
import urllib.request

from playwright.sync_api import sync_playwright

# (order, label, hash route, file stem). The order is the inventory's order and
# the file stem carries it, so a reader sorting by name walks the same path the
# capture did.
ROUTES: list[tuple[str, str, str]] = [
    ("Overview", "#overview", "01-overview"),
    ("Keepers", "#keepers", "02-keepers"),
    ("Registry", "#registry", "03-registry"),
    ("Monitor / Keeper Fleet", "#monitoring?section=agents", "04-monitor-keeper-fleet"),
    ("Work", "#workspace?section=work", "05-work"),
    ("Gate", "#approvals", "06-gate"),
    ("Schedule", "#schedule", "07-schedule"),
    ("Board", "#board", "08-board"),
    ("Fusion", "#fusion", "09-fusion"),
    ("Logs", "#logs", "10-logs"),
    ("IDE", "#code?section=ide-shell", "11-ide"),
    ("Connectors", "#connectors?section=connector-status", "12-connectors"),
    ("Settings", "#settings", "13-settings"),
    ("Internal Agents", "#monitoring?section=internal-agents", "14-monitor-internal-agents"),
    ("Tool Monitor", "#monitoring?section=fleet-health", "15-monitor-tool-monitor"),
    ("Runtime", "#monitoring?section=runtime", "16-monitor-runtime"),
    ("Observatory", "#monitoring?section=observatory", "17-monitor-observatory"),
    ("Plans & Goals", "#workspace?section=planning", "18-work-plans-goals"),
    ("Repositories", "#workspace?section=repositories", "19-work-repositories"),
    ("Verification", "#workspace?section=verification", "20-work-verification"),
    ("Tools", "#lab?section=tools", "21-lab-tools"),
    ("Safety Harness", "#lab?section=harness", "22-lab-safety-harness"),
    ("Performance", "#lab?section=performance", "23-lab-performance"),
    ("Keeper memory health", "#lab?section=keeper-memory-health", "24-lab-keeper-memory-health"),
]

SECTION_TITLES = [
    ("Primary navigation", 0, 13),
    ("Monitor and Work sections", 13, 20),
    ("Lab sections", 20, 24),
]

REDACT_JS = r"""
(config) => {
  const names = config.keeperNames.slice().sort((a, b) => b.length - a.length);
  const extra = config.extraLiterals.slice().sort((a, b) => b.length - a.length);
  const escape = (s) => s.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
  // One pass per rule, longest literal first, so `keeper-taskmaster-agent`
  // is not half-replaced by the shorter `taskmaster`.
  const rules = [
    [new RegExp('/Users/[A-Za-z0-9._/-]+', 'g'), '/home/demo/project'],
    ...names.map((n) => [new RegExp('\\b' + escape(n) + '\\b', 'g'), 'demo-keeper']),
    ...extra.map((n) => [new RegExp(escape(n), 'g'), 'demo-org']),
    [/\b\d{15,20}\b/g, '000000000000000000'],
  ];
  const scrub = (text) => rules.reduce((acc, [re, to]) => acc.replace(re, to), text);

  const walk = (root) => {
    const it = document.createTreeWalker(root, NodeFilter.SHOW_TEXT);
    const pending = [];
    while (it.nextNode()) pending.push(it.currentNode);
    for (const node of pending) {
      const next = scrub(node.nodeValue);
      if (next !== node.nodeValue) node.nodeValue = next;
    }
    // Titles and aria labels leak the same names into tooltips.
    for (const el of root.querySelectorAll ? root.querySelectorAll('[title],[aria-label]') : []) {
      for (const attr of ['title', 'aria-label']) {
        const v = el.getAttribute(attr);
        if (v) {
          const next = scrub(v);
          if (next !== v) el.setAttribute(attr, next);
        }
      }
    }
  };

  walk(document.body);
  if (window.__mascRedactObserver) window.__mascRedactObserver.disconnect();
  const obs = new MutationObserver(() => walk(document.body));
  obs.observe(document.body, { childList: true, subtree: true, characterData: true });
  window.__mascRedactObserver = obs;
};
"""

BADGE_JS = r"""
(label) => {
  const id = 'masc-capture-badge';
  document.getElementById(id)?.remove();
  const el = document.createElement('div');
  el.id = id;
  el.textContent = label;
  el.style.cssText = [
    'position:fixed', 'left:12px', 'bottom:12px', 'z-index:2147483647',
    'font:12px/1.4 ui-monospace,SFMono-Regular,Menlo,monospace',
    'color:#f0c674', 'background:rgba(20,18,14,0.92)',
    'border:1px solid #6b5a2e', 'border-radius:4px', 'padding:4px 8px',
    'pointer-events:none',
  ].join(';');
  document.body.appendChild(el);
};
"""


def discover_keeper_names(base_path: Path) -> list[str]:
    keepers = base_path / ".masc" / "keepers"
    if not keepers.is_dir():
        return []
    return sorted(
        d.name for d in keepers.iterdir() if d.is_dir() and not d.name.startswith(".")
    )


def read_health(base_url: str) -> dict:
    with urllib.request.urlopen(f"{base_url}/health?full=1", timeout=10) as resp:
        return json.loads(resp.read())


def git_head() -> str:
    return subprocess.run(
        ["git", "rev-parse", "HEAD"], capture_output=True, text=True, check=True
    ).stdout.strip()


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--base-url", default="http://127.0.0.1:8935")
    ap.add_argument("--base-path", default=None, help="runtime root holding .masc")
    ap.add_argument("--out", required=True, type=Path)
    ap.add_argument("--width", type=int, default=1440)
    ap.add_argument("--height", type=int, default=1000)
    ap.add_argument(
        "--redact",
        action="append",
        default=[],
        help="extra literal string to replace with demo-org; repeatable",
    )
    ap.add_argument("--settle-ms", type=int, default=2500)
    args = ap.parse_args()

    health = read_health(args.base_url)
    paths = health.get("paths", {})
    base_path = Path(args.base_path or paths.get("effective_base_path") or ".").expanduser()
    keeper_names = discover_keeper_names(base_path)
    if not keeper_names:
        print(f"no keepers found below {base_path}/.masc/keepers", file=sys.stderr)

    args.out.mkdir(parents=True, exist_ok=True)
    badge = f"Live port {args.base_url.rsplit(':', 1)[-1]} capture · operational identifiers redacted"
    config = {"keeperNames": keeper_names, "extraLiterals": args.redact}

    captured: list[tuple[str, str, str]] = []
    with sync_playwright() as pw:
        browser = pw.chromium.launch()
        page = browser.new_page(
            viewport={"width": args.width, "height": args.height},
            device_scale_factor=1,
        )
        page.goto(f"{args.base_url}/dashboard/", wait_until="networkidle", timeout=60_000)
        page.wait_for_timeout(args.settle_ms)

        for label, route, stem in ROUTES:
            page.goto(
                f"{args.base_url}/dashboard/{route}",
                wait_until="networkidle",
                timeout=60_000,
            )
            page.wait_for_timeout(args.settle_ms)
            actual = page.evaluate("() => location.hash")
            if actual.lstrip("#") != route.lstrip("#"):
                print(f"route drift: asked {route}, landed {actual}", file=sys.stderr)
            page.evaluate(REDACT_JS, config)
            page.evaluate(BADGE_JS, badge)
            page.wait_for_timeout(300)
            target = args.out / f"{stem}.png"
            page.screenshot(path=str(target))
            captured.append((label, route, stem))
            print(f"captured {target}")

        browser.close()

    write_inventory(args, health, captured, keeper_names)
    return 0


def write_inventory(args, health, captured, keeper_names) -> None:
    build = health.get("build", {})
    now = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    day = args.out.name
    lines = [
        f"# Dashboard screenshots — {day}",
        "",
        "These screenshots were captured from the live loopback dashboard at",
        f"`{args.base_url}/dashboard/`.",
        "",
        f"- Captured: `{now}`",
        f"- Runtime: MASC `{health.get('version', '?')}`, commit `{build.get('commit', '?')}`",
        f"- Documentation source: `{git_head()}`",
        f"- Viewport: `{args.width} × {args.height}`, device scale factor `1`",
        f"- Keeper names redacted: {len(keeper_names)}",
        f"- Reproduce: `python3 scripts/capture-dashboard-screenshots.py --out {args.out}`",
        "",
        "The capture walked each hash route, verified the route it landed on, then",
        "replaced Keeper names, absolute home paths, and long numeric channel ids with",
        "documentation-safe placeholders before saving. Every frame carries a badge",
        "saying so. No write action was performed.",
        "",
    ]
    for title, start, end in SECTION_TITLES:
        lines += [f"## {title}", "", "| # | Screen | Route | Screenshot |", "|---:|---|---|---|"]
        for index, (label, route, stem) in enumerate(captured[start:end], start=start + 1):
            lines.append(f"| {index} | {label} | `{route}` | [PNG]({stem}.png) |")
        lines.append("")
    (args.out / "README.md").write_text("\n".join(lines), encoding="utf-8")
    print(f"wrote {args.out / 'README.md'}")


if __name__ == "__main__":
    raise SystemExit(main())
