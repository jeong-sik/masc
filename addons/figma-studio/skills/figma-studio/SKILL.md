---
name: figma-studio
description: Read, edit and validate a paired Figma design through the Figma Studio Lane Addon.
---
# Figma Studio

Use `masc_figma_status` to discover reported sessions. Select the intended open
file with `masc_figma_bind`; names alone do not identify documents. The installed
worker authorizes the configured Keeper and the separately authenticated relay.

Submit `masc_figma_submit` with a stable `operation_id`, explicit `session_id`,
`root_id` and `kind: capture`. Inspect `masc_figma_operation` until an outcome is
reported. A prepared/dispatched receipt is not a successful capture or edit.
Never repeat an uncertain edit under a new operation ID to make it run again.

Read `masc_figma_snapshot` for native REST-shaped JSON and its retained PNG.
Inspect the image with vision before making visual claims. `coverage.stable`
means before/after structure matched; it does not establish an atomic capture.
Missing fonts, variable values and mappings remain explicit limitations.

For native edits, use `kind: apply` with the captured `snapshot_id` and `ops`.
Supported operations are `create_frame`, `create_text`, `rename`, `resize`,
`move`, `set_fill`, `set_text`, and `set_auto_layout`. Refer to new nodes with
unique `@name` references. The Plugin validates the full plan and fonts, then
checks the captured baseline before editing. This is not an atomic transaction.
Read the resulting snapshot and confirm changed node IDs and visible output.

Use `masc_figma_validate` for explicit structural expectations, for example:
`{"snapshot_id":"...","checks":[{"node_id":"1:2","path":["characters"],"equals":"Welcome"}]}`.
A structural pass does not mean visual correctness. Explain failed, missing and
inconclusive checks rather than substituting defaults. Reports are retained in
the next Lane observation with the snapshot and image artifacts.

For design-to-code, pin this snapshot, inspect the requested repository, reuse
its components, implement the design, run the app, and compare its actual
render with the retained PNG. Record interaction checks separately from visual
assessment. Do not impose an invented SSIM threshold.

The host-side `figma-mcp/studio/preview.py` helper can display a saved snapshot
tool result with `--kitty` using timg; this is an operator/host command, not a
command inside this network-isolated worker. The PNG hash is checked first.
