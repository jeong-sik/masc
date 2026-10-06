# Curator activity resume

Before this change, a parked Curator owner woke only for a memory commit or an
explicit request. Publishing an enabled Exact declaration left existing facts
waiting.

## Current implementation

The Curator owner subscribes to its lane through
`Runtime_exact_output_registry.subscribe_lane_changes`, next to the memory
commit subscription. The callback only wakes the owner; it never runs a model.

- A publication wakes a subscriber when it changes that lane's declaration or
  its admitted slot targets. The registry captures matching subscribers under
  the publication lock with the committed transition and calls them on the
  writing caller after releasing the lock. A callback failure is logged and
  does not hide the committed receipt.
- A reader refused with `Publication_busy` while a replacement fence stands is
  recorded. When that fence closes -- committed, not committed, raised,
  finished or aborted -- every subscriber is woken, because `current` does not
  record which lane the refused reader asked about. A fence that refused no
  reader wakes only the subscribers whose lane changed.
- `unpublish` does not notify subscribers.

The subscription itself came from main (#40902) when this branch merged it;
the refusal tracking was added on top in 8df4a690b0.

Executed against this README's parent, f2a68b1c7c:

```sh
dune build --root . ./test/test_exact_output_catalog_precedence.exe ./test/test_workspace_memory_curator_lane.exe
cd _build/default/test
DUNE_SOURCEROOT=<worktree> MASC_BASE_PATH=<scratch> ./test_exact_output_catalog_precedence.exe   # 15 tests, pass
DUNE_SOURCEROOT=<worktree> MASC_BASE_PATH=<scratch> ./test_workspace_memory_curator_lane.exe     # 17 tests, pass
```

A mutant that ignores the recorded refusal in `fence_close_subscribers` fails
4 cases: `fence exits wake subscribers only after turning a reader away` in
the registry suite,
and `failed write reopens deferred work`, `exception reopens deferred work`
and `retained commit reopens deferred work` in the Curator suite.

No full `dune runtest`, provider, TUI/PTY, browser, CI, merge or deployment was
performed for this unit.

## Historical: next-availability promise design (6d42d073c3)

The first version of this unit, up to 6d42d073c3, used a next-availability
promise: the owner captured it before its first drain, and a switch-owned
daemon awaited changes, captured the next promise and queued the owner.
Publication, withdrawal and every replacement fence exit resolved the previous
promise outside the publication lock, and cancellation removed a waiter
without cancelling the shared promise. That design was replaced by the
subscription above. The record below, and the files `check-source.py`,
`parser.json`, `registry-typecheck*.txt` and `source-hashes.json`, describe
that design and do not verify the current code.

Executed:

```sh
CURATOR_OCAML_BIN=/path/to/ocaml-5.5.1/bin python3 docs/evidence/2026-10-04-curator-activity-resume/check-source.py
git diff --check
```

Seven full ML/MLI sources parsed with OCaml 5.5.1. The installed Eio
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
