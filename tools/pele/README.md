# Pele terminal renderer

Pele 1.6.0 (MIT, [upstream](https://github.com/obsidianmd/pele)) renders Mermaid
syntax to SVG. This helper resolves SVG theme variables and rasterizes with
resvg for MASC's existing terminal image protocol. Retained SVG markup uses the
same offline rasterizer instead of an operating-system image converter.
It runs offline; diagram
links and images are disabled. It does not start a browser or fetch a CDN.

```sh
scripts/install-pele.sh
printf '%s\n' '{"format":"mermaid","source":"pie\n \"Done\":8\n \"Pending\":2","maxWidth":640}' | masc-pele > diagram.png
pnpm --dir tools/pele install --frozen-lockfile
pnpm --dir tools/pele test
```

The helper reads one JSON request from stdin and writes PNG bytes to stdout.
`format` is `mermaid` or `svg`; unknown and missing formats fail explicitly.
`source` is the retained markup and `maxWidth` is the current available pixel
width. Optional `colors` contains observed `foreground` and `background` as
six-digit RGB hex strings. Without an observed palette, the standalone preview
uses Pele's light defaults. Failure writes diagnostics to stderr and exits
nonzero without an image. The caller retains source and owns preview selection.

Optional `fontSize` is a positive safe integer (default `16`) describing the
physical text density. Pele lays out at its logical default of 16 with available
width `maxWidth / (fontSize / 16)`, then the complete SVG viewport scales by
`fontSize / 16`. Text, authored font sizes, strokes, spacing and chart geometry
scale together; fixed logical chart spacing stays readable at terminal density.
Generated SVG declares its default font family and size explicitly for resvg;
authored child font overrides and diagram label proportions remain intact.
`maxWidth`, `fontSize` and `colors` stay fixed while inspecting one diagram.
Optional `now` captures current-time expressions and decorations as epoch
milliseconds: a safe integer within JavaScript's valid Date range. Retain the
same value while inspecting a scene to freeze Gantt dates and its clock marker.
Omitting it uses Pele's current-time behavior on each render.
Optional `raster` requests a display surface independently of that layout:

```json
{"format":"mermaid","source":"flowchart LR\n A --> B","maxWidth":640,"fontSize":24,"raster":{"width":1200,"height":800,"crop":{"left":0.25,"top":0.25,"right":0.75,"bottom":0.75}}}
```

Raster width and height are positive safe integer pixel bounds. Omit `crop`
for the full diagram; otherwise all four corners must be finite numbers with
`0 <= left < right <= 1` and `0 <= top < bottom <= 1`. Both source formats
support explicit raster requests. Corners refer to the original rendered
viewport, including any letterboxing or clipping from the authored viewBox and
`preserveAspectRatio`. The helper rasterizes only that visible window
at an aspect-preserving size inside the requested bounds. It does not allocate
a full zoomed bitmap before cropping. The original intrinsic SVG dimensions
define the viewport coordinate system. `renderDocument` retains natural
layout width/height metadata while its returned SVG and PNG describe the
requested window. The original SVG viewport remains nested inside that window,
after resvg resolves its supported CSS, percentage geometry and glyphs in the
original document context. Without `raster`, static
SVG retains its exact source bytes and existing no-upscale behavior.

Observed terminal colours seed separate node and group surfaces, muted labels
and borders instead of flattening every fill into the background. Derived text
and borders retain 4.5:1 and 3:1 contrast respectively; if a tint cannot retain
that contrast, its original foreground/background role is used. An already
low-contrast terminal palette is preserved, not repaired. Authored `classDef`,
`style` and `linkStyle` colours, line widths and dashes override these defaults;
their contrast remains the author's choice. Static SVG keeps its own colours.

See [the colour and diagram example](examples/color-and-themes.md) for a
publishable Markdown artifact with coloured states, shapes, grouped flow,
sequence, Gantt, mindmap, pie and bar chart fences. The controls below work with
each prepared diagram; the original Mermaid source stays available.

SVG keeps its authored colours. Without explicit `raster`, it preserves its
aspect ratio, scales down to the available width, and is not enlarged.
It requires a well-formed SVG document, without a
DOCTYPE, processing instruction, foreign namespace, script, embedded image,
HTML content or external href. Fragment references within the SVG are allowed.
It renders static SVG using resvg's supported CSS, not a browser or the
surrounding HTML/CSS. External stylesheets are not fetched.
HTML reports still expose embedded base64 images; extracting inline SVG roots
from their HTML document is separate from this SVG resource path.

The installer publishes an immutable content-addressed runtime beside its
launcher, verifies a real render, and then atomically updates `masc-pele`.
Node.js 22+ and pnpm are required at installation. Node.js and the installed
runtime are required at preview time; the source checkout is not.
Install the helper from the same source revision as the TUI: its explicit format
protocol rejects requests from callers that do not identify the source format.

Upstream renderer speed claims do not measure this PNG pipeline. Font loading,
Node startup, rasterization and terminal transmission add their own latency.

Resources document mode prepares closed Markdown Mermaid fences in the
background. On a Kitty graphics terminal with measured cell geometry, each
prepared PNG appears in its document position and scrolls with the surrounding
text. Several diagrams keep separate placements. Resizing or changing the
observed palette prepares a new snapshot; another resource response cannot
inherit the previous response's pending render.

`Ctrl-O` opens the selected diagram separately; `,` and `.` select images and
diagrams within the response. Source mode and literal search retain the text
reading. Terminals without inline placement support keep the text diagram and
can use the existing standalone preview. Rendering failures remain visible;
`r` rereads the resource and retries from the newly admitted response.

On Kitty graphics terminals with measured cell geometry, the standalone
preview accepts `+`/`-` to zoom, arrow keys or `h`/`j`/`k`/`l` to pan, and `0`
to fit the full image. Wheel input pans vertically. Vector diagrams retain their
original scene and full-image coordinates while an asynchronous worker renders
the visible window at display density. Pending work reuses the base image;
failures stay visible and `r` retries. Ordinary raster images reuse their
original PNG with source-pixel crop coordinates. `v` returns to the
resource's original source, while `Esc` or `q` returns to its document.
These preview keys are consumed by the image and never reach the composer.
