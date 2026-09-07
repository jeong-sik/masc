# Browser screenshot terminal input diagnosis — 2026-09-07

The compiled macOS arm64 TUI at source `df69a3d94492d5618976b7ad43f8a5eb34d795a3`
failed the matching `browser-screenshot` PTY scenario before its first PNG placement.
Binary SHA-256: `89a369c11f82242acbe2418639308362da2de3ecc3f37eb959097c57531edf69`.

The live PTY reported `VDISCARD = 0x0f` and `IEXTEN = true`. Disabling only
VDISCARD through the PTY descriptor let the same, unchanged binary handle Ctrl-O
and emit its PNG image placement. The capability response was unchanged; its early
echo was not the cause of this failure. Apple's [tty input implementation](https://github.com/apple-oss-distributions/xnu/blob/main/bsd/kern/tty.c)
handles VDISCARD under IEXTEN before canonical input processing.

The diagnostic run then exposed two fixture assumptions: waiting for a URL row did
not guarantee that the footer had arrived, and closing the URL editor did not emit
its unchanged page body. The fixture now waits for the deferred-Enter footer and
the changed navigation banner respectively.

With the PTY-only VDISCARD intervention and those two fixture corrections, the
unchanged compiled binary completed all four capture requests, cancellation while
editing a URL, preserved draft after busy Enter, subsequent capture, closed-tab
refusal, explicit refresh, and terminal-restoration comparison:

```text
VDISCARD before capture b'\x0f' IEXTEN True
INITIAL CAPTURE PASSED WITH ONLY VDISCARD DISABLED
ALL FOUR CAPTURE REQUESTS AND URL PRESERVATION PASSED
tui Browser screenshot regression: PASS
```

This is a measured diagnosis, not execution of the new C/OCaml source. The product
change snapshots, disables and restores VDISCARD through the existing termios seam,
including suspend and editor handoff. C syntax, OCaml parsing and Python AST checks
passed. The new product binary still needs CI artifact execution; no local build
was run. The PTY fixture now explicitly rejects a binary that leaves VDISCARD armed.
