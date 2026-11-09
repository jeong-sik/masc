# A cancelled composition must not admit a queued Serial tool

Observed on 2026-11-09 with the installed OCaml 5.5.1 compiler and Eio library.
Baseline: `419f2a843ed727a69c5c36a307ba28d51da04dce`.

The reproduction extracts `Exclusive_gate` verbatim from the baseline and
candidate executor source, and uses wrappers matching their acquire/release
call sites. One shared operation waits in a protected scope. An exclusive
operation queues behind it; the controller cancels the run, then lets the
shared operation finish. No timeout decides the ordering.

```text
before: queued_dispatched=1 cancellation_propagated=false
after: queued_dispatched=0 cancellation_propagated=true
```

Run `python3 docs/evidence/cancellable-tool-plan-gate-20261109/reproduce.py`
with `ocamlfind` and `eio_main` installed. Generated sources, executables and
output stay in a fresh `artifacts/cancellable-tool-plan-gate/<run>/` directory.

Eio's installed `core/cancel.ml` and public `Cancel.protect` contract say that
protected work does not check its parent cancellation when it returns.
Protecting a gate wait therefore allows the queued tool to run after cancellation.
The candidate uses cancellable condition waits on the execution's single domain;
it checks cancellation before taking ownership and releases only an acquired gate.

This is a focused extracted-gate reproduction. The public executor regression
uses `serial_order_fixture` and the real dispatch callback, but was only parsed
locally. No MASC Dune build, complete executor test run, CI or deployed runtime
result is claimed.
