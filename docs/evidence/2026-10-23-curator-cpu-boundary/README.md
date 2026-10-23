# Curator classification preparation: CPU-domain boundary

Relates to #45245. This records a source isolation repair and a standalone
scheduling experiment. It does not establish an installed-runtime speedup.

## Confirmed source defect and repair

At base `33e3dcd9bf6e2655a44669b68281f859453fc2c4`,
`Server_workspace_memory_curator.classify_new` runs `Request.prepare` inside
its raw-system-thread `io` wrapper. Preparation builds a transient SQLite FTS
index, ranks neighbors, constructs/render batches, and measures protocol frames.
`Keeper_memory_search_index.with_excluding_owners` already submits CPU work,
but `Domain_pool_ref.submit_cpu_or_inline` sees a non-Eio caller on that raw
thread and runs inline. CPU work therefore shares the calling domain's runtime
lock rather than entering the installed CPU pool.

The repair makes `Workspace_memory_request.prepare` own one CPU-pool job and
removes the Curator caller's raw-thread wrapper. Immutable inputs, destination
selection and prompt resolution are captured before submission. SQLite table
creation, search and cleanup remain within one preparation; nested submissions
stay on its worker. Original-owner transitions and publication remain outside
this boundary. Other storage/recovery paths are unchanged.

## Focused verification

Changed entrypoint: `Workspace_memory_request.prepare`.
Direct product consumer: `Server_workspace_memory_curator.classify_new`.
Behavior target: `test_workspace_memory_request` (existing shape/frame/refusal
checks plus three CPU execution tests):

- Render/measure execute off the caller domain, nested submission finishes on
  a single-worker pool, and the full captured batch equals inline preparation.
- An effectful callback exception preserves its identity and executes once.
- Caller cancellation returns after entered callback cleanup completes.

The tests use domain identity and synchronization rather than latency limits.
No new production timeouts, cache expiry, byte limits or retry heuristics are added.
Local validation passed `git diff --check` and OCaml syntax parsing of the changed
request implementation and its test. These are not type-check or test execution
results. Focused CI execution is recorded separately when a completed result exists.
No full regression, release validation, live install or server restart was run.

## Standalone scheduling experiment

`probe.ml` copies only `Workspace_memory_context.canonical/hash` from the base
above to illustrate the runtime-lock mechanism using synthetic 1 MiB and 8 MiB
JSON values. It does not execute the changed request entrypoint or a real Curator
workload. The two paths are raw system-thread execution on the calling domain
and CPU-worker submission followed by the same system-thread execution.
The observer requests a 1 ms sleep repeatedly. This sampling interval is a
measurement setting, not a product limit or pass/fail threshold.

Native standalone compilation, using installed OCaml 5.5.1/Eio/Digestif:

```sh
opam exec --switch=5.5.1 -- ocamlfind ocamlopt \
  -package eio_main,yojson,digestif.c -linkpkg probe.ml -o probe
./probe > results.jsonl
```

Three rounds alternate path order. For 8 MiB, the largest observer gaps were
31.416–32.966 ms on the calling-domain system thread and 1.183–2.099 ms on the
CPU worker. Every paired digest matches. This demonstrates scheduler isolation,
not faster CPU work: for 1 MiB, median total duration increases from 4.256 to
5.355 ms on the worker path. The raw 12 observations are in `results.jsonl`.

## Live evidence boundary

A separate instrumented capture on embedded source
`a3e12df277e378f2e4a5461e07401dd122cc488a` reproduced fourteen HTTP requests
fully inside a 55-second Eio collection window: nine responses identifying the
same runtime and five client-side 5-second timeouts. The slowest completed
response took 4475.097208 ms. This establishes an observed live problem, not its
attribution to classification preparation. Raw event labels and runtime data
remain private. A later externally replaced, quiet server cannot serve as a
controlled before/after comparison.

This source repair must not be described as resolving those timeouts or proving
TUI/Dashboard performance. Dashboard artifact workflow remains disabled at the
operator's direction; this work does not prepare or install a matching bundle.
