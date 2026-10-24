# Goal stack composition with the current main

This is a local source candidate over main
`98a1508e6ecbda1d38d33aa7d0eb7f366b420ddf`, preserving the original 14-layer
Goal head `895df663fb303ee2fa95c38bbd28b571db9abb62` and the fifteenth Draft
measurement-receipt layer. The latter moved from `3014cfce` to `ec664e53` while
the candidate was prepared; that delta only corrects the authoritative-empty
provider-wire fixture expectation and is preserved here. No author checkout,
runtime store, installed candidate, PR readiness, or public ref was changed.

The whole stack was rebased with `gh stack rebase`. Conflict choices preserve
main's immutable review original and worker/publication flow, completion-result
wrapper, Browser test registration, and inline/raw response replay. Goal's
reported provider-model evidence wraps the combined telemetry without replacing
either replay carrier. The new evaluator response identity survives retained
result serialization. The producer runtime is captured in the immutable
original and passed to retained execution, rather than recovered from a later
alias. Every existing constructor call supplies that option explicitly.

The #45782 review identified a separate fragment ownership error. The exact
`changelog.d/45781.md` bytes now belong to the introducing #45781 layer; #45782
adds only its own fragment. The numeric-fragment parser had accepted the old
contents, so this manual layer-ownership repair is not described as a failing
parser becoming successful.

## Strict retained-record boundary

The previously installed recovery candidate's source `8e534a757f13` used
`verifier_review_original/v1`. Main already uses v2, which captures separate
system instructions. That pre-existing v1 incompatibility is distinct from
this candidate's changes:

- Original v2 -> v3 adds a required nullable `generator_runtime` field. Null
  means producer evidence was not observed; it is never inferred from an alias.
- Retained result v1 -> v2 adds a required nullable `evaluator_execution` field
  containing the actual accepted provider response and source ToolUse ordinal.

Older field sets and versions are refused. There is no decoder fallback,
migration, deletion, identity reconstruction, or automatic provider replay.
This is a real deployment compatibility and availability boundary. No live
inventory scan or deployment compatibility PASS is claimed here.

The source failure paths were read through their actual callers:

- `Verifier_review_owner.load` maps Original decoding errors to
  `Corrupt_original`; its read path does not retain, replace, or delete a body.
  `load_for_destination` and `load_retained` propagate that error.
- `next_attempt` and `retained_commits` decode inventory records before
  selecting the verification. An incompatible Original can therefore block the
  whole verifier-review scope, including unrelated new reviews. It is not
  silently dropped or treated as an empty inventory.
- `Verifier_review_worker.run_attempt_with` loads first. Already judged,
  committing, finished, conflicted, and refused phases restore their result
  before any dispatch intention. An old result returns `Original_corrupt`;
  dispatch-pending remains `Execution_pending`. Neither branch starts a new
  provider call. Commit-intent decoding also precedes domain application.
- `Completion_authority_agent.process_task_once` turns inventory failure into
  review-preparation infrastructure unavailability. The publication-preservation
  guard treats inventory errors as preserve=true, preventing a competing registry
  completion. Terminal recovery propagates pending/decode errors before terminal
  publication. These failures leave the owner data and unresolved obligation;
  they are not successful completion or restored service.

An eventual installation needs a separate retained-record inventory and
operator recovery decision. This source candidate does not authorize such an
operation or assert that the generic deployment preflight validates this
specific semantic schema.

## Bounded validation

`probe_conflict_codecs.py --repo PATH --baseline` compiles main's exact retained
result decoder against the Goal result type. It fails on the missing
`evaluator_execution` field, demonstrating the new direct consumer dependency.
Without `--baseline`, it compiles the actual full Original implementation and
private interface, actual response-identity implementation/interface, extracted
Goal types, and actual retained-result codecs. All 19 behavior checks pass.

The probe uses named ports for prompt rendering, tool/context types, canonical
serialization and digest. It does not execute the real owner store, worker,
provider, HTTP/native Host, filesystem locks, SDK, or live Keeper. Its digest
port is explicitly not production cryptographic validation. The JSON reports
bind the compiled actual source inputs by SHA-256.

The existing native worker fixture now asserts exact winning-response identity
after restore and no second dispatch. It and the full worker/host typecheck
remain unexecuted. Changed OCaml parsing and fragment checks are separate
source checks; they do not establish native or runtime success. The original
Goal snapshot/empty-observation producer sources remain byte-identical to the
previous repair. The earlier 8/25 component runs were not rerun and retain their
original source/effect-port limits.

The official projection and submission-link files also inherit main's typed
message-origin change. Those files differ from the earlier 25-check source.
Their small origin-construction/classification deltas were read, but the older
execution is not evidence that this current projection, complete Host, or live
provider path passes. Only the unchanged producer bytes have exact source reuse.
