# Phase 0 Report — dashboard_bonsai foundation

Scope: land the first Bonsai island under `/dashboard/b/hello`, measure the
baseline cost of introducing Jane Street Bonsai alongside the existing Preact
dashboard, and capture every concrete obstacle encountered so later phases can
plan against reality instead of assumptions.

## Timeline

- 2026-04-19 — plan approved (`planning/claude-plans/masc-mcp-eventual-parrot.md`).
- 2026-04-19 — worktree `feature/bonsai-phase-0` created from `origin/main`.
- 2026-04-19 — OxCaml switch `bonsai-dashboard` (`ocaml-variants.5.2.0+ox`) created.
- 2026-04-19 — `/dashboard/b/*` server routes added, masc-mcp main build green.
- 2026-04-19 — `dashboard_bonsai/` scaffold written.
- TBD — `dune build` green on OxCaml switch.
- TBD — first end-to-end smoke (`curl /dashboard/b/hello`).

## Toolchain decisions

1. **Stock OCaml 5.3 + janestreet-bleeding rejected.** `basement` C stubs fail
   to build on macOS 26.3 because `caml/misc.h` defines `fallthrough` as an
   unconditional macro, which leaks into the preprocessor state by the time
   `dispatch/base.h` is pulled in via `<dispatch/dispatch.h>`. The system SDK
   uses the token `fallthrough` inside `__has_attribute(...)`, and the prior
   macro expansion breaks that call. This affects every OCaml 5.3/5.4 project
   that (transitively) includes libdispatch on macOS 26.
2. **OxCaml accepted.** `oxcaml/opam-repository` ships Jane Street's compiler
   fork plus patched packages, including a working `basement`. ARM64 macOS is
   a first-class supported platform.
3. **Dedicated switch.** `bonsai-dashboard` is a hard isolation boundary from
   the masc-mcp main switch (stock OCaml 5.4.1). `dune` in the repo root
   excludes `dashboard_bonsai/` from the main project tree. Each tree builds
   in its own switch with its own dune-project. No shared OCaml link graph.
4. **Preact coexistence.** `/dashboard/*` continues to serve Vite output.
   `/dashboard/b/*` serves js_of_ocaml output from `assets/dashboard_bonsai/`.
   Neither side can accidentally depend on the other.

## Measurements (Hello World, 2026-04-19)

### Bundle size — production flags without effects=cps

    dune config: (js_of_ocaml (flags (:standard --opt 3 --enable use-js-string
                                      --disable pretty --disable debuginfo)))

| Metric | Value | Notes |
|--------|-------|-------|
| Bundle `main.bc.js` raw | **47.3 MB** (47,337,143 B) | entire OCaml + Jane Street + Bonsai runtime |
| Bundle `main.bc.js` gzip | **8.0 MB** (8,036,581 B) | |
| js_of_ocaml warning | `missing-effects-backend` | Bonsai uses effect handlers; without `--effects=cps` runtime behaviour is undefined |

### Bundle size — production flags WITH `--effects=cps` (correct)

| Metric | Value | Notes |
|--------|-------|-------|
| Bundle `main.bc.js` raw | **60.3 MB** (63,187,392 B) | CPS transform expands every fn into continuation form |
| Bundle `main.bc.js` gzip | **9.0 MB** (8,989,664 B) | +0.9 MB vs non-CPS |

### Comparison

- Preact hello-world (industry rule-of-thumb): ~5 KB gzip.
- Ratio: **~1,800x larger** than Preact at gzip.
- Plan exit condition #1 ("gzip size > 10× Preact equivalent widget") is **triggered**. Plan requires 2 conditions for auto-halt; currently 1 of 2.

### Supporting metrics

| Metric | Value |
|--------|-------|
| OxCaml switch package count | 241 installed |
| Bonsai roots | bonsai, bonsai_web, bonsai_concrete, bonsai_web_components |
| Cold install time | ~15 min (two-stage: first opam errored mid-install, second completed) |
| Cold build time from clean `_build/` | not measured (dominated by js_of_ocaml link step, multiple minutes) |
| Warm rebuild | not measured |

## Stack-specific observations

1. **v0.18 Bonsai API shifted from v0.17.** `Start.start` in v0.17 took a plain
   `'a Bonsai.t`. In v0.18 preview it takes a `(Bonsai.graph @ local) -> 'a Bonsai.t`
   — cont-style. Requires OxCaml mode annotation `(_graph @ local)`.
2. **Library names changed.** v0.17 had `bonsai.web` (sublib). v0.18 has a
   top-level `bonsai_web` package/library.
3. **`opam install` has non-deterministic rollbacks.** An early install
   reported `∗ installed bonsai` but a later `opam list` showed bonsai was not
   installed. A second, more-explicit install of `bonsai bonsai_web ppx_css
   virtual_dom` forced the resolver to pin and commit the whole tree. Lock
   contention from concurrent `dune` processes in other worktrees may be
   implicated. Record in handoff.
4. **Optimization flags give ~1.7% reduction.** `--opt 3 --enable use-js-string
   --disable pretty --disable debuginfo` moved raw from 48.2 MB to 47.3 MB.
   The main weight is the closure of Jane Street dependencies, not formatting
   or debug info.
5. **CPS effects transform costs 0.9 MB gzip**, but is required for correctness
   since Bonsai schedules effect handlers.

## Open questions / follow-ups

- `Start.start` entry signature in v0.18 preview vs v0.17 — adjust `bin/main.ml`
  if the build surfaces a type error.
- SSE helper spike (Phase 0.4) — compare `brr`'s `Brr_io.Sse` API against a
  hand-rolled `Dom_html.eventSource` binding. Keep the winner, delete the
  other.
- `ppx_css` reported class names and Preact Tailwind output must not share
  class name space (they don't collide now because `ppx_css` generates
  deterministic hashed names, but document the guarantee).
- Document the build orchestration: the smoke test needs `assets/dashboard_bonsai/main.bc.js`
  in place before `serve_bonsai_static` returns anything useful. A simple
  `Makefile` target (`make bonsai-dashboard`) or a `dune promote` alias is
  probably the next step.

## Did anything surprise us?

- Jane Street's public release cadence assumes an OCaml version floor (5.3 as
  of v0.18 preview). macOS 26 SDK breaks that floor silently at the C-stub
  stage. OxCaml is the only clean answer today.
- `opam install` on the OxCaml switch finished far faster than the 30–60 min
  we scoped in the plan — the download cache already had most of the standard
  OCaml ecosystem, and the Jane Street packages build in parallel.
