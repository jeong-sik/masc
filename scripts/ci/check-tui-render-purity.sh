#!/usr/bin/env bash
# The TUI renderer is meant to be a function of the state, not a step that
# edits it. It used to clamp each surface's scroll mid-frame and write the
# result back, which is why drawing a frame changed the state it drew from --
# the same four lines copied once per surface, with the key handler moving the
# scroll unbounded and the drawing correcting it on the way past.
#
# Two things fixed it. A surface the state can count declares its rows and its
# chrome in Masc_tui_types.scrolled_surface, and the key handler clamps against
# that. A surface whose row count only exists once the frame is built -- lines
# of a board post, of a task's notes -- reports the value it used as a
# clamped_scroll beside the frame, and the loop stores it.
#
# The budget is zero and there is no reason for it to rise. A surface that
# needs to clamp has both of those doors; if neither fits, the answer is a
# third door, not a write from inside the drawing.
set -euo pipefail

RENDER="bin/masc_tui_render.ml"
BUDGET=0

if [ ! -f "$RENDER" ]; then
  echo "[tui-render-purity] $RENDER not found" >&2
  exit 1
fi

writes="$(grep -n 'state\.[a-z_]* <-' "$RENDER" || true)"
if [ -z "$writes" ]; then
  found=0
else
  found="$(printf '%s\n' "$writes" | wc -l | tr -d ' ')"
fi

echo "[tui-render-purity] state writes in $RENDER: $found (budget $BUDGET)"

if [ "$found" -gt "$BUDGET" ]; then
  echo "[tui-render-purity] FAIL: the renderer gained a state write." >&2
  echo "  If the state can count the surface's rows, declare it in" >&2
  echo "  Masc_tui_types.scrolled_surface and let move_surface_scroll clamp" >&2
  echo "  it. If the count only exists once the frame is built, report it as" >&2
  echo "  a clamped_scroll beside the frame and let the loop store it." >&2
  printf '%s\n' "$writes" >&2
  exit 1
fi

echo "[tui-render-purity] OK"
