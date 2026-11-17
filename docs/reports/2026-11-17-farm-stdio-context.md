# Farm interactive process runtime capture

The remote interactive port obtained a clock before waiting for its endpoint
lease, but `Process_eio.with_stdio` later read the global runtime again. A runtime
replacement during that wait or the dispatch callback could change the process
manager and host working directory. The carrier could then run under different
conditions from those the caller had acquired before admission.

## Change

`Process_eio.stdio_context` holds the existing immutable runtime record: process
manager, default cwd capability/path and clock. The remote port captures it before
the lease or control probe, uses its clock for the existing timeout, and supplies
the same context to the process runner. The runner does not reread the global
runtime when an explicit context is supplied. Ordinary callers capture the current
runtime when they call `with_stdio`.

Both forms still require an active Eio fiber. An old capture cannot reopen a
closed capability or enable Unix fallback. The process group, stream drains,
actual exit status and receipt callback retain their existing ownership. Guest
sessions still obtain the network and clock from Eio without a process manager.
Context-free request preparation remains available.

The existing finite control-probe helper retains its own runtime path; this change
keeps the payload context stable across that probe, rather than changing probe
execution. The cwd is a captured capability/path, not an opened directory held
against filesystem replacement. This is not a serializable execution binding.

## Verification scope

Three authored cases exercise the changed boundary:

- Capture runtime A, install runtime B, and observe the actual child `pwd` under
  the explicit capture and under the ordinary current-runtime call.
- Carry a capture out of its Eio scope and verify that it cannot spawn there.
- Replace the runtime inside remote dispatch admission and observe the actual
  host carrier's cwd. Its deliberately invalid scripted receipt remains rejected;
  it supplies no evidence that a remote sandbox was applied.

Full-file OCaml 5.5.2 parsing and whitespace checks passed. The cases have not
been type-checked, linked or executed by this coding session. Independent source
review and any later execution are recorded separately against their candidates.

## Remaining reader work

Durable media originals still need a real execution binding with held-directory
identity, exact captured request/carrier data, and owner/declaration cross-checks.
Serialization must not recreate a process capability. Existing originals must
be inspected before current reader selection, including after a workspace or
declaration change. Owner/preflight integration, approval recovery, retained full
MCP results and an actual DOCX run through the owned SSH/guest route remain required.
