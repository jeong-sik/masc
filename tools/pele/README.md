# Pele terminal renderer

Pele 1.6.0 (MIT, [upstream](https://github.com/obsidianmd/pele)) renders Mermaid
syntax to SVG. This helper resolves SVG theme variables and rasterizes with
resvg for MASC's existing terminal image protocol. It runs offline; diagram
links and images are disabled. It does not start a browser or fetch a CDN.

```sh
scripts/install-pele.sh
printf '%s\n' '{"source":"pie\n \"Done\":8\n \"Pending\":2","maxWidth":640}' | masc-pele > diagram.png
pnpm --dir tools/pele install --frozen-lockfile
pnpm --dir tools/pele test
```

The helper reads one JSON request from stdin and writes PNG bytes to stdout.
`source` is exact Mermaid text and `maxWidth` is the current available pixel
width. Optional `colors` contains observed `foreground` and `background` as
six-digit RGB hex strings. Without an observed palette, the standalone preview
uses Pele's light defaults. Failure writes diagnostics to stderr and exits
nonzero without an image. The caller retains source and owns preview selection.

The installer publishes an immutable content-addressed runtime beside its
launcher, verifies a real render, and then atomically updates `masc-pele`.
Node.js 22+ and pnpm are required at installation. Node.js and the installed
runtime are required at preview time; the source checkout is not.

Upstream renderer speed claims do not measure this PNG pipeline. Font loading,
Node startup, rasterization and terminal transmission add their own latency.
