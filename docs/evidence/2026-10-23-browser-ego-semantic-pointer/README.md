# ego semantic pointer: cross-origin iframe evidence

Captured 2026-10-23 from `feat/browser-ego-semantic-pointer-20261023`, based on
`29f764b36676fecf308f56cee039ae5749efd2e1` (upper layer of Stack #45598).
Tracking: <https://github.com/jeong-sik/masc/issues/45556>.
Published as code #45627 and evidence #45631 on a fresh stack from main
`9c2256fea8fad3bb8ca7e5aed8a92cd803fcbdda`; the boundary hash below is unchanged.

`scripts/probe-browser-ego-semantic-pointer.mjs` extracts the production
`nativeTargetInput` function from `Browser_ego_peer` and executes that exact
boundary using ego's real Page API. SHA-256:
`17f56114dac1e162c554a12691722513c19e0fe7fff2164daec5e6db82798bdd`.
Installed ego version: 0.6.0.16 (its own notice in `ego.log`).

## Result

Six scenarios passed. The owned top page uses localhost; its iframe uses
127.0.0.1 on a different port, making it cross-origin and cross-site. Both
documents contain a button with the same visible text.

| Scenario | Independent application observation |
|---|---|
| Hover observed iframe AX ref | The iframe receives trusted mouseenter; the outer lookalike remains untouched. |
| Double-click observed iframe AX ref | The iframe receives one trusted dblclick; the outer lookalike remains untouched. |
| Hover role/name target | The top document's matching button receives trusted mouseenter, following ego's top-document preference. |
| Double-click text target | The top button receives one trusted dblclick; the iframe does not receive another. |
| Wrong expectedUrl | Refused before input; application state unchanged. |
| Removed iframe/stale ref | Refused before input; application state unchanged. |

Success receipts are objects, as the actual OCaml peer requires; a trusted event
alone is not treated as a compatible receipt. Parent observations accept messages
only from the expected frame origin and window. Fresh snapshots supply each
iframe ref; refs are not guessed from a prior run.

`proof.json` records the boundary results and separately read application state.
`ego.log` retains AX snapshots and runtime output, with trailing blank lines removed. The screenshot
`trusted-frame-results.png` shows the two controls and the observed trusted event
log; the coding session opened and visually inspected it.

## Continuity

The previous goal space 54 returned `task space not found`; a subsequent
`listTaskSpaces()` confirmed it absent. No other goal's space was taken over.
The operator explicitly authorized one successor, created as **space 66**,
name `masc browser parity 20261023 continuation`, page `p1`. All subsequent
probe rounds reused 66. It remains open because the broader goal is unfinished.

```sh
node scripts/probe-browser-ego-semantic-pointer.mjs /Users/dancer/.local/bin/ego-browser /tmp/masc-ego-semantic-proof 66
node --test test/test_browser_ego_target.cjs
```

The executable path and space number above identify this capture; supply the
executable and continuing goal-owned space appropriate to another environment.
Do not create another space automatically if this one disappears.

## Scope

Actual browser execution proves the extracted native target boundary, native
event delivery and application observations above. It does not execute the
OCaml decoder, generated ownership/dialog wrapper, live host/Add-on transport,
installed Keeper tools, autonomous target selection or a human comparison.
The same unchanged wrapper still performs ownership/dialog checks in source.
Explicit `framePath` reads/actions remain unsupported on ego; iframe AX targets
are a separate native resolver path. Other backends do not gain AX support.

The Node boundary suite passes four grouped cases across click/fill/hover/double
click: exact native dispatch, navigation during discovery, missing/ambiguous
targets and an uncertain reply without replay. Sixteen changed ML/MLI files
passed parser-only checks, tool TOML parsed, and diff whitespace checks passed.
No local Dune build, OCaml type check, CI, deployment or Keeper benchmark ran.
