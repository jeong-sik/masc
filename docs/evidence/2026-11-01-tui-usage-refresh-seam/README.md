# Usage key and HTTP launch seam

This addresses PR #47049 review comment 4434152535: the earlier focused test
called the period helper and request order directly, so removing the actual
key arm's dispatch could leave it passing. This proof compiles the exact `w/W`
match arm together with the **entire** `start_http_scoped_refresh` function.
The retained change adds evidence only; no production API or behavior changed.

The source head is `ea7f321488112e20f09edec5a229d817b320dd98`, the actual PR
#47049 head read for this review. Its target seam is identical at full TUI top
`74756f56e61a92d8d64250e9ed7552ad165645c4`. Baseline is
`61b4d5531d44cb780dff64158fdbf7d641f1658f`.

At that source head, the copied key arm is `bin/masc_tui.ml:32841` and the full
launch function is `bin/masc_tui.ml:16956`. Source hashes:

- key arm: `41332cf22538abf4e3911e37b2dae3d4d9665cac9ea3ff39aefcefae35942487`
- full launch: `d12dd7b7c374b73fc1deace5d2af6f7b85ad99a85efe1d3974863efa7f499d07`

The source extraction also copies complete `Surface_read_source`,
`Surface_read_order` and `Http_refresh_order`, `surface_needs`/`nothing`, the
actual period transition, the complete workspace identity matcher and booting
guard. Extraction uses pinned Git objects and fails if the expected source
boundaries are absent. It does not substitute a handwritten key action or
launch implementation.

## Reproduce

With OCaml 5.5.1 and the three source commits available in the repository:

```sh
python3 docs/evidence/2026-11-01-tui-usage-refresh-seam/run.py
```

The runner writes a fresh timestamped directory under
`artifacts/p3-feature-detail-20261101/usage-seam/`; it never writes new output
into this retained bundle. `--output artifacts/<new-run>` chooses another new
directory. Missing Git objects are a visible failure; a shallow clone must
obtain the pinned commits first. No Dune, external package or server is needed.

The retained execution used:

```sh
python3 docs/evidence/2026-11-01-tui-usage-refresh-seam/run.py --output artifacts/p3-feature-detail-20261101/usage-seam-retained-run
```

`receipt.json` records the helper/source/output hashes, command, compiler
version and observed output. The complete source manifest and generated
compilation/run outputs remain in that artifact directory. No binaries or
generated source tree are included in this bundle.

## Observed result

The current source compiled and passed **10 cases**:

- Both lowercase `w` and uppercase `W` reach the actual transport call with
  the newly selected days, a Navigation request, the provider-history-only
  needs and the original endpoint.
- Queued overlapping collectors capture `1,7,14` at dispatch time. Full and
  scoped collectors keep the same authority generation, superseded/ABA
  history requests lose dataset ownership, and the unrelated full-refresh
  Keeper usage source retains ownership.
- Five deterministic authority/identity changes before or during probing or
  transport produce refused completion. Pre-admission refusals do not call
  the dataset loader. The exact identity matcher and both probe guards run.
- The actual telemetry key guard suppresses the action. The complete launch
  function's synchronous branch reaches application and finishes its request.

Two negative controls compiled and failed both key cases at the dispatch seam:
the baseline's actual key arm resets the display without launching a reader;
an explicitly labeled derivative of the candidate arm passes `needs=nothing`.
Thus the adapters do not independently manufacture the expected dispatch.

## Limits

The copied arm is wrapped in a minimal match with a fallback. Preceding key
bindings and the complete input event loop are not executed. State is a small
record exposing the fields these exact functions use. Canonical paths are
pre-resolved string values; this does not test filesystem path resolution.

The scheduler queues closures, transport records arguments and supplies
controlled identity/readings, and the mailbox is an in-memory queue. Credential
preparation, context bookkeeping, logs and unrelated loaders are adapters.
Synchronous application is a callback counter. This does not exercise real
HTTP decoding, Eio scheduling/cancellation, mailbox consumers, display layout,
terminal input, actual result application or installed runtime behavior.
The copied request-order modules establish the scoped request decisions in
this harness; they do not establish completion of a visible TUI flow.

No repository test target, local Dune build, CI dispatch/watch, PTY assertion,
GitHub response, approval, stack mutation or publication was performed.
