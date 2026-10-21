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
SVG keeps its authored colours and aspect ratio, scales down to the available
width, and is not enlarged. It requires a well-formed SVG document, without a
DOCTYPE, processing instruction, foreign namespace, script, embedded image,
HTML content or external href. Fragment references within the SVG are allowed.
It renders static SVG using resvg, not a browser or the surrounding HTML/CSS.
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
