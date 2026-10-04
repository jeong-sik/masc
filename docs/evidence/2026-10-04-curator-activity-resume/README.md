# Curator activity resume

Before this change, a parked Curator owner woke only for a memory commit or an
explicit request. Publishing an enabled Exact declaration left existing facts
waiting. The registry now supplies a next-availability promise. The owner
captures it before its first drain, and a switch-owned daemon awaits changes,
captures the next promise and queues the existing owner.

Publication, withdrawal and every replacement fence exit resolve the previous
promise outside the publication lock. Failed writes, exceptions and retained
commits also end a fence: a Curator that observed `Publication_busy` must retry
current admission. A failed attempt to enable an off registry leaves it off.
No subscriber callback executes on the writing caller. Cancellation removes a
waiter without cancelling the shared promise or another owner's observation.

Executed:

```sh
CURATOR_OCAML_BIN=/path/to/ocaml-5.5.1/bin python3 docs/evidence/2026-10-04-curator-activity-resume/check-source.py
git diff --check
```

Seven full ML/MLI sources parsed with OCaml 5.5.1. The installed Eio 1.3
`core/eio__core.mli` and `core/promise.ml` were read to verify cross-domain
promise resolution, enqueue semantics and waiter cancellation.

A bounded attempt to typecheck the actual registry against existing main build
interfaces stopped at an inconsistent `Runtime_schema` dependency in
`runtime_quota_window.cmi`. It did not typecheck the registry or Curator.
`registry-typecheck.txt` preserves the error excerpt, and its provenance records
the full log hash and omitted duplicate-interface discovery warnings. No
dependency rebuild was performed and no typecheck PASS is claimed.

Authored, **not executed**: seven Curator scenarios cover off-to-on retained
facts without another memory event, first publication, work deferred during a
failed/exception/retained transaction, already accepted work finishing after
off, and one owner cancelling while another continues. One registry scenario
covers publication, rejection, coalescing, withdrawal and transaction outcomes.
They extend the existing `test_workspace_memory_curator_lane` and
`test_exact_output_catalog_precedence` targets using the actual registry and
Curator, with only model execution/input size injected. Exception-kind checks
are present; preservation of the original backtrace is reviewed by source.

No Dune, full candidate typecheck/link, native scenario execution, provider,
TUI/PTY, browser, CI, merge or deployment was performed for this unit. The
previous Web evidence does not establish that a deployed Curator resumed.
F1 runtime integration and the remaining Lane, package and Goal scope are open.
