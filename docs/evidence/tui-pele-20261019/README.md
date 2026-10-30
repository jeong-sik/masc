# Pele integration evidence

Scope: Mermaid source to offline Pele SVG, concrete SVG theme resolution,
resvg PNG, and the OCaml subprocess acquisition boundary. These artifacts are
renderer output, not captures of an installed TUI.

- `pnpm --dir tools/pele test`: 6/6 passed, covering six diagram families,
  narrow layout, observed palette colors, malformed input, source resource
  handling, literal chart metadata and terminal-safe parser diagnostics.
- `scripts/install-pele.sh --prefix /tmp/masc-pele-proof/bin`: installed a
  content-addressed helper and completed its real PNG smoke render.
- A focused OCaml harness compiled only `masc_tui_pele.ml/.mli` with
  `ocamlfind ocamlc -package yojson,unix -linkpkg` in a temporary directory.
  Calling the installed helper returned a real PNG, surfaced malformed source
  as an error, and removed request/output/diagnostic temporary files.
- `ocamlc -stop-after parsing` accepted changed OCaml source/interfaces.
  This is syntax evidence, not a TUI typecheck or executable build.
- `sh -n scripts/install-pele.sh`, JavaScript syntax checks, and
  `git diff --check` passed.

The PNGs were generated through `renderDiagram` using the same exact source
and an explicit foreground `#eeeeee` / background `#161616` test palette:

```mermaid
flowchart LR
 A[Mermaid 원문] --> B[Pele 레이아웃] --> C[PNG] --> D[터미널 미리보기]
```

| Available width | Natural output | File |
|---|---|---|
| 320 px | 169 × 352 px | [Narrow preview](flow-320.png) |
| 1200 px | 655 × 64 px | [Wide preview](flow-1200.png) |

The narrow PNG was visually inspected; Korean labels remained readable and
foreground/background materialization rendered correctly. No upstream speed
ratio was reproduced or asserted for the terminal PNG pipeline.

The repository protocol excludes local Dune builds for external coding
sessions. Full TUI compilation, the OCaml projection suites, installation of
a changed TUI binary, and an interactive TUI capture are unverified here.
