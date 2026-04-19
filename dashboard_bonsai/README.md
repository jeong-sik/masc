# dashboard_bonsai

Bonsai (Jane Street) implementation of the masc-mcp dashboard. Island migration
target — coexists with the Preact SPA at `/dashboard` while this tree builds out
`/dashboard/b/*`. See `planning/claude-plans/masc-mcp-eventual-parrot.md` for the
full migration plan.

## Toolchain

- OCaml variant **`ocaml-variants.5.2.0+ox`** (OxCaml) in opam switch
  `bonsai-dashboard`. The masc-mcp server switch (5.4.1, stock OCaml) is not
  reused because Bonsai `v0.18~preview` requires `ppxlib < 0.36` (incompatible
  with 5.4) and stock OCaml 5.3 fails to build Jane Street's `basement` C stubs
  on macOS 26 due to a `fallthrough` macro collision with the system dispatch
  headers.
- Bonsai `v0.18~preview.130.83+317` from the OxCaml opam repository.
- `ppx_css`, `virtual_dom`, `brr`, `ppx_yojson_conv`.

## One-time switch setup

    opam switch create bonsai-dashboard 5.2.0+ox \
        --repos ox=git+https://github.com/oxcaml/opam-repository.git,default \
        --no-install
    opam install --switch=bonsai-dashboard \
        bonsai ppx_css virtual_dom brr ppx_yojson_conv

If the OxCaml repo is not registered globally yet, the `--repos` flag above
registers it only inside this switch, which is the recommended isolation.

## Build

Build from this directory using the dedicated switch:

    eval $(opam env --switch=bonsai-dashboard)
    dune build

The compiled JS lands at `_build/default/bin/main.bc.js`. A production build
step (not yet implemented) will copy that artifact into
`../assets/dashboard_bonsai/` so the server can serve it via
`/api/assets/dashboard_bonsai/main.bc.js`.

## Serving URL

- `/dashboard/b/hello` — Phase 0 smoke page (current).
- `/dashboard/b/logs` — Phase 1 target (first real tab).

## Directory layout

    bin/main.ml            entry, mounts the Bonsai app on #app
    src/hello_view.ml      placeholder component (ppx_css)
    src/sse.ml             EventSource helper (Phase 0.4 spike)
