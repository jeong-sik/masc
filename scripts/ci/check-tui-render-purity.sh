#!/usr/bin/env bash
# The TUI renderer is meant to be a function of the state, not a step that
# edits it. It used to clamp each surface's scroll mid-frame and write the
# result back, which is why drawing a frame changed the state it drew from --
# the same four lines copied once per surface, with the key handler moving the
# scroll unbounded and the drawing correcting it on the way past.
#
# The bound now lives with the move for every surface the state can count
# (Masc_tui_types.scrolled_surface). What is left are the surfaces whose row
# count the drawing builds out of text it formats; counting those outside the
# drawing would be a second copy of the formatting.
#
# This is a ratchet, not a gate on zero: the number may fall and may not rise.
# Lower it in the same change that removes a write.
set -euo pipefail

RENDER="bin/masc_tui_render.ml"
BUDGET=7

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
  echo "  A surface's scroll bound belongs with the keypress that moves it:" >&2
  echo "  declare the surface in Masc_tui_types.scrolled_surface and let" >&2
  echo "  move_surface_scroll clamp it. The drawing then only reads." >&2
  printf '%s\n' "$writes" >&2
  exit 1
fi

if [ "$found" -lt "$BUDGET" ]; then
  echo "[tui-render-purity] FAIL: $found writes left but the budget still says $BUDGET." >&2
  echo "  Lower BUDGET in this script to $found in the same change." >&2
  exit 1
fi

echo "[tui-render-purity] OK"
