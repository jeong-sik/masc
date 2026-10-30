# Completion review evidence ownership — #38062

## Source change

`Keeper_request_source.t` declares either durable `Keeper_history {trace_id}` or
program-owned `Completion_review` before dispatch. The driver, wrapper, actual
Keeper and completion-review callers, four official-client adapters, and shared
Host carry that owner explicitly. A missing trace no longer selects a history
policy. Prepared Keeper input retains its checked continuity; completion input
has no fabricated trace or Librarian boundary.

Completion review preserves the original messages, attachments and tool pairs
at initial projection and after typed context/body refusal. It bypasses carried
history cuts, Memory reprojection, halving and current-result marker retries.
Media capability admission rejects an incapable candidate instead of replacing
submitted media with an unreadable reference. Existing effect/continuation,
permission, cancellation and candidate retry classification remain authoritative.

Within one review invocation, actual earlier lookup observations accompany each
later declared evaluator slot. At lookup return the full `Tool_bridge` formatter
projects the result once under the existing completion-review `Inline_up_to`
SSOT policy. The retained view has the actual slot/name/arguments/disposition and
admitted model content/media or the typed projection refusal. Raw rejected data
and host-only metadata do not enter the next prompt. A later lookup still runs
the actual handler and cannot replace the earlier observed source view.

## Verification scope

The following are authored native test sources, not observed native execution:

- `test_completion_review_immutable_input`: actual wrapper → Agent Core → HTTP
  peer; preserves the original lookup body and ToolUse/ToolResult identity on
  typed context/body refusal. A supplied third response detects re-entry. The
  existing checkpoint fence may also prevent it, so this fixture is not an
  isolated negative control for the new owner branch.
- `test_keeper_official_argument_window`: Host completion identity despite a
  tiny capacity, late seed and argument demotion opportunity, with no history
  reader, capacity measurement, callback or artifact write.
- `test_keeper_codex_current_context`: actual Codex completion projection keeps
  the full evidence without reading the Keeper history boundary.
- `test_anti_rationalization_empty_reject`: actual slot traversal with an
  injected evaluator and real supplied lookup; immutable prior observations,
  fresh changed reads, invocation isolation, and full-bridge refusal preservation.

Independent source review found a handoff that bypassed the existing inline
ceiling. A partial raw-message guard still missed Failed metadata/Explicit_data;
that counterexample motivated reuse of the actual full formatter. Historical
port execution or a reproduced counterexample is not proof that the latest
repair passed. Final executed checks are recorded below.

No local Dune build, full project typing, native test executable, CI dispatch,
installation, runtime replacement or live Keeper continuity proof is claimed.
Vendor-internal auto-compaction is outside the observed source boundary.

## Remaining full issue scope

Relates to #38062; this unit does not close it. Global marks schema/loader,
validator/template removal and remaining dead ladder cleanup must be audited
against RFC §13.7 and Librarian lifecycle §7(라), including semantic continuity,
I4 visibility, and a valid staged operating configuration. No live TOML or
installed binary identity was read or changed in this unit. Earlier forecast
origin repairs do not establish those prerequisites.

## Executed bounded check

`execution.json` records **48 assertions PASS** on the source head it names.
`source-manifest.json` and `fragments.json` bind the seven source files and 29
extracted fragments. The later documentation/changelog additions do not change
those source bytes. The probe compiles actual AR slot traversal, full bridge
formatting and artifact metadata decoding against actual Tool_output codec and
Tool_result accessor source. Evaluator, slot resolution, SDK/Eio/error boundary
and prompt registry behavior are explicit ports. Blob storage is a fail-fast
port; the run observed zero storage calls. It does not exercise native SDK,
provider HTTP, effect/permission/cancellation handling or the full project type
graph. Compiler warning exclusions in the receipt apply to this port harness,
not to production warning policy.

The cases cover the SSOT limit-plus-one Completed body/media, short Failed
message with large metadata or Explicit_data, missing artifact manifest,
original admitted content/media, host-only metadata exclusion, and formatting
frozen before the next evaluator's assembly even after prompt guidance changes.
Historical partial guard and counterexample executions remain historical; they
are not counted as repaired native results.

With OCaml 5.5.1, ocamlfind, Yojson and Digestif installed, reproduce from the
repository root using an owned output directory:

```sh
opam exec -- python3 docs/evidence/2026-10-23-completion-review-evidence/verify_review_handoff_ports.py \
  --repo . --output /tmp/completion-review-handoff-check
```

`syntax.json` records strict syntax-only parsing of all 49 changed OCaml
implementation/interface files after rebase. These hashes bind the checked
source; this does not resolve or type-check the project dependency graph.
