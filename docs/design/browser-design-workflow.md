# Browser-grounded design and implementation

The first milestone connects an observed browser element to original development
source, then verifies an edit in the same browser context. TUI and Keeper share
browser/document/node identity and source SHA-256. Source hints never grant local
file-system authority.

## Acceptance and current evidence

| Goal | Acceptance | Current status |
| --- | --- | --- |
| Source connection | At least 18/20 correct source targets, no falsely asserted file | Real Vite + Zen and Firefox: 24/24 targets each; HTM template and JSX element precision are explicit |
| Edit/readback | Selected source edit, new browser observation and working action | Scripted fixture source edit, changed source hash, reload, stale-ref refusal and post-edit click passed in both browsers |
| Operator handoff | Select an element, view source, pass context to Keeper | TUI source row and OSC52 JSON handoff implemented; new TUI executable and physical clipboard not measured |
| Autonomous repair | At least 8/10 UI problems resolved without additional source-location guidance | Not measured; scripted fixture is not this benchmark |
| Builtin guidance | Design/implementation/verification packages included in installation | Packages and embedded-seed expectations added; newly built installer execution not measured |

Evidence: [source connection receipts and screenshots](../evidence/browser-source-context-20260908/README.md).

## Next implementation slices

1. Execute the updated TUI and install flow; verify copied context with its source
   record and browser identity. Exercise stale source, tab changes and unsupported
   clipboard terminals.
2. Run ten paired frontend repair tasks with the same model/settings and fixture
   conditions, with and without the source connection. Record actual completion,
   additional user guidance, elapsed time, attempted actions and regressions.
3. Compare three structural design alternatives on three representative surfaces
   with identical data/state/viewport, then verify apply/reload/undo.
4. Observe three flows across three widths and five relevant states (45 cases),
   checking core keyboard actions and task-blocking clipping/overlap.
5. Prototype selectable terminal text with raster regions on text, dashboard and
   form pages. Preserve observation alignment during scroll; use full-image
   fallback for layouts beyond the measured coverage.

The latter slices are planned, not implemented by the source-context milestone.

## Constraints that shape this implementation

MASC's dashboard is Preact/HTM/Vite. The dev-server AST transform records known
source locations instead of depending on React internals. It does not instrument
production output. Original source maps are preserved. HTM identifies a template
expression, not an invented opening-tag coordinate or winning CSS declaration.
External pages without this instrumentation remain usable but unmapped.

The design/implementation/verification skills are routed when relevant to the
user's request. Their value needs paired measurement; installing more guidance
is not itself a quality result.
