# MSX activity refusal and spectator recovery

Base: `5d673773d03b1cf9008a01543cb1e3833c9f02ea`. This is the narrow tick/read repair within the machine activity change. The sibling machine activity evidence owns the inventory, publication, and emulator-owner checks.

The MSX tick route now returns HTTP 409 with `ok: false` and either `code: "activity_disabled"` or `code: "activity_unobserved"` for the owner's refusal before execution. The TUI retains its picture and requests only GET `/api/v1/msx/activity` and the existing live-screen read while observing that refusal. A valid enabled activity and valid live answer permit a new tick on the next cadence. Failed reads preserve the picture and the observation policy. Transport errors and unrecognized tick responses retain an unknown mutation outcome; they are never automatically retried. Changing the workspace, port, or view cannot convert that unknown outcome to permission. Only an explicit current-scope frame read can rearm it.

Activity GET follows the existing `with_public_read` wrapper, including read authentication in strict mode; no strict public-path exception was added. Input errors keep their notice and do not trigger the old unconditional frame read that erased it.

## Executed checks

Run from this checkout:

```sh
MSX_TICK_OCAML_BIN=/Users/dancer/.opam/5.5.1/bin python3 docs/evidence/2026-10-05-msx-tick-activity/check-leaf.py
```

- Actual complete `masc_tui_msx_tick.ml/.mli` and `test_tui_msx_tick.ml`: **6/6 PASS**, OCaml 5.5.1. `leaf.json` records compiler commands, input hashes, and the exact production frame/mark declaration fragments extracted for the two dependencies. No HTTP/server/main behavior is replaced in this check; those modules are not compiled by it.
- The six scenarios cover typed off/unobserved refusal, read-only recovery policy, unknown-outcome retention, malformed activity/refusal responses, retained pixel metadata, scope changes, and late cache responses.
- OCaml 5.5.1 syntax only: **10/10 PASS**, recorded in `syntax.json`. This includes main, async protocol, HTTP, route, and route-test source; parsing is not type or link validation.
- An earlier local invocation of the same tick leaf used the default OCaml 5.5.0 and passed. It is not the pinned-toolchain evidence; the retained final logs are the later 5.5.1 run.

## Authored checks and source review limits

`test_msx_routes.ml` adds real owner/executor checks for both refusal codes without frame advancement, off-to-on admission, and a router request check for strict unauthenticated rejection / authenticated read / absent POST handler. These native route tests are **authored and parsed only, not run or typechecked**.

The main event handling was source-reviewed for request identity, view/port/workspace fencing, no automatic retry of unknown outcomes, and preserving input errors. The late-error workspace mismatch response assigns the typed terminal policy before discarding stale presentation, so a stale transport error still holds `Outcome_unknown`. This main/HTTP integration was not executed by the leaf scenarios. Full native TUI/server typechecking, link, Dune build, PTY, live HTTP, emulator playback, and CI were not run for this unit.

`source-hashes.json` binds the ten modified source files, two unmodified type-extraction inputs, and this folder's artifacts. Route and route-test files also contain the parent machine-owner changes; hashing the whole file does not expand this tick check's execution scope.
