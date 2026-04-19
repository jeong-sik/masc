# OCaml North Star

This document defines the OCaml quality direction for `masc-mcp`.
It is intentionally spec-preserving: it does not change MASC, OAS, MCP,
task lifecycle, execution policy, or deterministic/non-deterministic
boundaries.

## Non-Negotiables

- Do not change public OAS/MCP wire shapes as part of quality work.
- Do not change task lifecycle semantics inside a refactor.
- Do not change deterministic/non-deterministic implementation boundaries
  without a separate RFC and explicit review.
- Do not change execution policy, approval policy, or tool semantics as a
  side effect of making code cleaner.
- Do not optimize for performance without benchmark evidence.
- Do not edit `~/me` root workspace files for this program; work inside the
  target repo and its own `.worktrees/`.

## What "Excellent OCaml" Means Here

The project should use OCaml's strengths to make existing behavior easier to
trust:

- model protocol and lifecycle states with algebraic data types;
- keep JSON, strings, filesystem paths, process arguments, and model output at
  typed boundaries;
- expose narrow `.mli` contracts for stable modules;
- return typed `result` values for expected failures;
- reserve exceptions for cancellation, programmer errors, or low-level
  library boundaries;
- use Eio structured concurrency with explicit resource ownership;
- keep mutation bounded behind modules with a clear owner;
- measure allocation and latency before replacing clear code with clever code.

## Implementation Pattern

For each improvement:

1. Write behavior-locking tests for current semantics.
2. Extract pure state transitions or decoding logic without changing the wire
   shape.
3. Keep effectful shells thin: file I/O, Eio fibers, process execution, HTTP,
   SSE, and provider calls belong at the edge.
4. Prefer existing canonical types:
   `Types_auth.masc_error` for user-facing operation errors and
   `Failure_envelope.t` for operator evidence.
5. Run the local checks relevant to touched files.

## Initial Focus Areas

- Task lifecycle: lock the current transition table before extracting a pure
  FSM kernel from `Coord_task`.
- Keeper scheduling: lock semaphore, fairness, and cancellation invariants
  before changing queue implementation details.
- Process and sidecar execution: prove equivalence before replacing shell
  string paths with argv-only paths.
- Typed OAS/codecs: keep wire compatibility, improve error locality, and make
  schema drift visible.

## Health Tracking

`make ocaml-health` is observational by default. It reports risk-pattern
counts but does not fail CI. Promote individual checks to ratchets only after
their baseline and intended scope are reviewed.

Tracked patterns include production `failwith`, `invalid_arg`, `assert false`,
`Obj.magic`, direct `Sys.command`, raw process spawning, manual mutex
lock/unlock, broad exception catches, and untyped JSON utility use.

## Evidence

- OCaml language strengths and module system: https://ocaml.org/about
  checked 2026-04-19, confidence High.
- OCaml release/tooling changelog: https://ocaml.org/changelog checked
  2026-04-19, confidence High.
- Effect handlers and direct-style concurrency:
  https://dl.acm.org/doi/10.1145/3453483.3454039 checked 2026-04-19,
  confidence High.
- Local data-race freedom:
  https://kcsrk.info/papers/pldi18-memory.pdf checked 2026-04-19,
  confidence High.
- Tail Modulo Cons:
  https://arxiv.org/abs/2411.19397 checked 2026-04-19, confidence High.
- OCaml module scoping and local open:
  https://arxiv.org/pdf/1905.06543 checked 2026-04-19, confidence High.
- QCheck state-machine testing:
  https://janmidtgaard.dk/papers/Midtgaard%3AOCaml20.pdf checked
  2026-04-19, confidence High.
- Flambda 2 local PDFs:
  `/Users/dancer/Downloads/Flambda 2 OCaml 2023.pdf` and
  `/Users/dancer/Downloads/icfp23-ocaml-paper11.pdf`, checked locally with
  `pdfinfo` and `pdftotext` on 2026-04-19, confidence High.
