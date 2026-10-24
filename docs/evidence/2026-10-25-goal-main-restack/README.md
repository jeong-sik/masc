# Goal stack composition with the current main

This is a local 16-layer source candidate over main
`98a1508e6ecbda1d38d33aa7d0eb7f366b420ddf`. It preserves the public Goal14
head `895df663fb303ee2fa95c38bbd28b571db9abb62`, the complete latest Draft
measurement-receipt head `177219da10c1b27b606c10af70b4bf6ea39211da`, and new
Draft observation-retention head `2bc6ae8fa1904d8232c8ea0738e0b14bab824945`.
All latest author production and raw evidence files are preserved, apart from
explicitly documented conflict/consumer repairs and own-fragment citations.
Preserving raw runtime reports is not an independent audit or a claim to have
executed their native/model runs. No author checkout, runtime store, installed
candidate, PR readiness or public ref was changed.

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
- Before the scope-isolation repair, `next_attempt` and `retained_commits`
  decoded the whole inventory before selecting a verification. An independently
  bound old Original A therefore blocked unrelated fresh/current B. The actual
  differential component reproduced this separate availability defect.
- The introducing #45775 layer now requires a closed selection for commit
  inventories. Targeted reads first validate immutable routing identity, key,
  summary/body agreement and the already verified digest, then strictly decode
  only that verification. Routing never constructs an executable Original.
  Unverifiable identity remains an error; no unknown is treated as absence.
  `All_verifications` recovery still strictly rejects unsupported records.
  Unsupported target A remains retained and cannot allocate or redispatch.
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
previous repair. The earlier 8-check snapshot run was not rerun and retains its
original source/effect-port limits.

The official projection and submission-link files also inherit main's typed
message-origin change. Those files differ from the earlier 25-check source.
The older execution was not carried forward as current proof. Instead,
`probe_current_origin.py --repo PATH` compiles the current actual Origin/message
types, projection, codec v3, System assembly, submission-link interface and
write-receipt prefix. An Agent Core alias port preserves their nominal type
identity; Goal data types and registry resolution remain named fixture ports.
It executes the actual formatter, Goal row/world arm, template renderer and
exact prompt-template bytes.

Reversing only the two functional formatter/world hunks in this same source
fails at last-Goal removal: Resume is only OWNER, the old Goal digest remains
held and there are no source occurrences. The formatter-only unsafe control
also fails by fabricating empty from known nonempty IDs with unknown summaries.
The current source passes all 25 checks: canonical Active Goals(0) arrives in
the actual codec-v3 User JSON, the previous digest is retired, System span/hash
and the Resume write slot bind, and the same empty observation is not resent.
These are fresh exact-source pure-component results with the recorded effect
ports, not full Host, native provider/SDK, remote retention or live behavior.

## Current sixteen-layer component binding

The independent scope-isolation execution compiles the actual Owner/Original
modules against named temporary-file/store cleanup ports. The integrated seven
source files match that executed repair byte for byte. It keeps main-v2 A
strictly rejected and its original five files/frontier unchanged, permits only
independently bound fresh/current B's own next attempt, and leaves the global
inventory in error. The actual Owner test source also covers malformed routing,
missing/duplicate metadata, key/digest disagreement and vanished bodies. This
is not full Host, production filesystem, provider or runtime recovery proof.

New #45853 replaces the Goal-only System field with closed Goal/Task-verdict
observations. The existing official-removal probe is minimally ported to those
three API changes and executed against the current typed-Origin sources.
Its before and unsafe-formatter controls still fail, and the repaired current
source passes 25 checks. Earlier projection executions are not substituted for
this new input set. `codec-after.json` records a fresh 19-check codec run.

The new Task-verdict block also exposed a real Dashboard consumer failure:
`memCompositionFromInputComponents` dereferenced a missing metadata entry.
The actual source constants/functions, transpiled by TypeScript and executed
in Node, fail for a positive-byte `prompt.completion_authority` before the
one-line introducing-layer mapping and preserve its label and byte total
afterward. No layout assertion, browser render or visible UI success is claimed.

## Latest author carrier response and remaining evidence limits

The complete 0606-to-32805eb7 author delta is preserved. It projects the closed
Completion Authority observation out of an exact Official Start standing
System and into a separately sourced User input. Goal keeps its System/held
policy. Host reads its post-hook issuer once and shares that immutable
snapshot with Start and Resume; Claude, Codex, Antigravity and Muse use the
shared Start composer. Missing/stale issuers cannot borrow an old event or
attest new User input. Ordinary HTTP request assembly is unchanged.

The new exact-source Start/Resume component passes 55 checks against this
candidate's real typed-Origin and codec-v3 interfaces. It includes the actual
Host.start_prompt and selected Host snapshot/blank-base guard statements, with
explicit minimal record/guard and unreachable-effect ports. It observes Start
System = BASE + Goal, one current event in User, absent next event = NEXT OWNER,
changed correlation keys, canonical-source/actual-target proof and JSON write
slot binding. These are pure components, not full Host/hooks, a native process,
vendor retention, remote model behavior or whole-stack source approval.

The Goal withdrawal probe was rerun because the actual submission-link API
now requires a closed Start/Resume target. Before and unsafe-formatter controls
still fail; the current repair passes 25 checks. Scope/codec sources are
unchanged, so their meaningful prior executions are rebound by exact SHA
rather than rerun. The already captured Dashboard consumer fragment is also
unchanged and retains its actual TypeError-to-74-byte result.

The author's same follow-up adopts the identical Agent_core.Types.Text
qualification from our earlier local candidate. The completed older native
run 40114401559 remains historical compile-failure evidence; no fresh complete
native compilation or any of its six selected-suite executions is claimed.
The prior 2be9/0606 source FAIL and independent counterexample remain in the
author evidence as historical findings addressed by this new source delta.
Current exact-scope independent review and native verification remain separate.

## Later author evidence and native counterevidence

The author 328-to-2bc6 publication adopts the identical Dashboard metadata
entry and adds 89 documentation/evidence paths, preserved as the author's
records. The fragment now describes Start/User and the metadata correction;
only the missing own-PR citation on each of its two bullets is repaired here.
No production function or earlier executed component input changed in this
adoption. Source/component checks are therefore rebound, not repeated.

The new native receipt at source328 records six completed suites /245 tests,
but the Claude runtime suite records three explicit failures (lifecycle0,8,13)
and times out600seconds after lifecycle47; case48 has no settled result.
The first failure follows the standing-System assertion in the new lifecycle
fixture. Full expected/received failure summaries are unavailable because the
suite timed out. The inherited-child error in case13 is preserved separately.
These observations are unresolved native counterevidence, not a repaired-suite
PASS and not a measured failure of the differently composed local candidate.
The independent author-source PASS predates these results. Earlier-source
Qwen G3 failure and UI experiment records remain separate from this candidate,
Official transport, production installation and our own execution claims.
