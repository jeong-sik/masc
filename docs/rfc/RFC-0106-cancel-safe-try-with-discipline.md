---
rfc: "0106"
title: "Cancel-safe try-with discipline (Eio.Cancel.Cancelled propagation)"
status: Active
created: 2026-05-17
updated: 2026-08-08
author: vincent
supersedes: []
superseded_by: null
related: ["0072", "0097", "0101", "0126"]
implementation_prs: [15894, 15904, 15917, 15919, 15920, 15925, 16949, 16951]
---

# RFC-0106 — Cancel-safe try-with discipline

## Contract

Eio signals fiber cancellation with `Eio.Cancel.Cancelled`. It is control
flow, not an ordinary failure value. A catch-all handler inside a fiber must
therefore re-raise it so the enclosing switch can unwind.

The shared owner is `Cancel_safe`:

```ocaml
val protect : on_exn:(exn -> 'a) -> (unit -> 'a) -> 'a
val observe : on_exn:(exn -> unit) -> (unit -> unit) -> unit
```

Both functions preserve cancellation and route only non-cancellation
exceptions to `on_exn`. A boundary that must retain its local error mapping
may use the equivalent explicit arm:

```ocaml
try operation () with
| Eio.Cancel.Cancelled _ as exn ->
  let backtrace = Printexc.get_raw_backtrace () in
  Printexc.raise_with_backtrace exn backtrace
| exn -> handle_ordinary_failure exn
```

## Usage

- Use `Cancel_safe.protect` when an ordinary exception becomes a typed value.
- Use `Cancel_safe.observe` for best-effort observers and callbacks.
- Use an explicit typed arm when the surrounding handler must log, classify, or
  release resources locally.
- A handler that already re-raises every exception does not need an additional
  cancellation arm.

Cancellation must not become `None`, `Error`, a warning-only success, or a
domain-specific input failure.

## Verification

`test/test_cancel_safe.ml` pins both combinators: cancellation propagates and
ordinary exceptions follow the supplied handler. Focused boundary tests pin
sites whose local result mapping makes the distinction observable.

Review the actual `try ... with` control flow. Lexical pattern counts are not
a correctness proof because an identical catch-all shape may either absorb or
re-raise its exception.
