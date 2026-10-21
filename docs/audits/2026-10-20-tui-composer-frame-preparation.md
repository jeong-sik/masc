# Shared composer frame preparation

Related PR: [#44174](https://github.com/jeong-sik/masc/pull/44174).

Source change only. As-Is is parent head
`2004c3cb261a7b4bb7388f6533e7a56da72ddb45`.
Parsing, typing, execution and runtime evidence are separate; no runtime
Before/After or speedup is established by this refactor.

## As-Is / To-Be

`finish_surface` previously called `composer_line` and `composer_cursor`
separately. With a focused composer and no browser/navigation overlay, both
projected the selected recipient and metadata, escaped the draft/prefix and ran
`Message_layout.input_window`. The cursor also rebuilt the voice prompt twice.
The two branches wanted the same synchronous frame data.

`composer_row` now returns the line and caret together. One local projection,
prompt width and escaped draft window supply both. This is frame-local immutable
reuse; no result, recipient or draft is retained for a later frame or key.

| Work per focused composer frame | Before in source | After in source |
| --- | ---: | ---: |
| Full state-to-composer projection | 2 | 1 |
| Voice prompt construction | 3 | 1 |
| Prompt display-width computation | 3 | 1 |
| Full draft and prefix escaping | 2 each | 1 each |
| Horizontal draft-window preparation | 2 | 1 |

These are direct source call-path counts, not executed invocation-count tests or
a frame-time reduction. `Message_input.contents` already returns its immutable
string in constant time; it was not a draft-copy bottleneck. Prefix slicing,
escaping, grapheme/window work and hint construction remain. Returning the pair
adds an ordinary tuple allocation. No allocation or latency total was measured.

## Authority and visible contracts

- The same freshly selected recipient and original typed availability still
  supply the frame. Key routing independently reads its current projection;
  rendering never supplies focus/send permission.
- Unfocused Overview retains its source-only metadata note and hidden caret.
  Browser-owned input retains its blank row/hidden caret. Keeper navigation
  bypasses all composer preparation and keeps its existing empty row.
- The editable prompt, terminal escaping, grapheme-aligned prefix, horizontal
  width, one-row budget and column clamp retain their existing functions. The
  caret consumes the exact window/prompt dimensions prepared for this frame.
- Slash/read notes still follow the draft. Approval notices retain their row
  precedence and the existing focused-caret policy. No authority or priority
  decision is inferred from a note.
- Preparation remains inside the existing `surface.chrome` timing boundary.
  There is no extra worker, request, timer, global cache or telemetry capture.

The old independently computed row/cursor functions are removed. The draft-window
helper had no other source consumers; its unused interface export is removed
instead of leaving another route that could reintroduce separate preparation.
No display/layout/row-order/snapshot/PTY/helper-mirror/invocation-count tests are
added. Source inspection and parsing do not prove actual caret/input behavior.

## Before/After evidence still required

Match actual workspace/population, cache state, draft/cursor/attachments, terminal
width, overlays, resources and logging conditions. Measure complete frame/input
boundaries as well as chrome cost, retaining failed, cancelled, interrupted and
unfinished attempts. A lower source call count is not useful Task work or paint.
The input-key path, source I/O, Composition/shared-backend continuity and other
frame work are outside this direct delta. All six original goal axes and actual
matched Before/After remain open.
