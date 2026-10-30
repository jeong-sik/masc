# Memory support retraction design R1

## Decision

Memory OS current facts have two structural bases:

- `Observed`: selected from evidence or written explicitly.
- `Derived`: a conclusion with one or more independently sufficient
  `{rule_id, premise_ids}` support sets.

The model decides what a claim and rule mean. Deterministic OCaml maintains the
least supported fixed point. A derived fact is current when at least one whole
support set is current. Removing an observation therefore retracts every
unsupported conclusion, including conclusions that depend on another removed
conclusion. Cycles without an observed root never bootstrap themselves.

This generalizes the existing source-bound Memory OS mechanism. Source-bound
memory invalidates one observation when exact source bytes change. Support
maintenance invalidates any number of conclusions that depend on ordinary
current facts.

## Why this is the first slice

The linked Lemmalog account separates fuzzy evidence interpretation from
deterministic truth maintenance. It also distinguishes relevant history from
what is currently true. MASC already records conversation history, current
memory snapshots, source-byte invalidations, and Librarian decisions. The
missing structure was the edge between a conclusion and the exact current facts
that justify it.

This slice does not introduce a second database or a Datalog sidecar. The
existing atomic snapshot and journal are enough for a positive support graph.
A larger rule language is justified only after the product demonstrates cases
that this typed graph cannot express.

## Orthogonal verification model

Feature and duration are independent axes. A feature is not considered proven
for a duration merely because the server stayed alive, and a ten-turn transcript
does not prove one-hour continuity.

| Feature axis | Turn proof | Time proof | Failure proof | Surface proof |
|---|---|---|---|---|
| Memory current truth | premise -> conclusion -> recall | 1h, 2h, 4h, 24h checkpoints | remove premise during the run; conclusion retracts before the next model call | API, journal, log, dashboard |
| Multi-runtime Keeper | same objective continues for 10+ turns | provider/runtime identity sampled across checkpoints | fail active runtime; next turn continues from typed state | runtime timeline and Keeper detail |
| Team / cross-verification | producer and verifier exchange exact artifacts | independent lanes remain live for the selected duration | producer failure does not erase verifier state | Board, task, artifact, lane views |
| Connector continuity | same conversation identity survives routing | scheduled and proactive outputs at declared times | connector unavailable; durable queue drains in order after recovery | connector log and destination screenshot |
| Parallel tools | results join by typed call identity | sustained concurrency with latency and queue depth samples | one lane fails or cancels without corrupting siblings | trace waterfall and queue view |

The duration runner must record explicit lifecycle events and checkpoint
identities. It must not decide success from a budget counter, a timeout guess, a
keyword in model prose, or the mere presence of a process.

## Current implementation contract

- Fact JSON is one closed current shape and unknown fields reject.
- `rule_id` is opaque. No control flow branches on its spelling.
- `premise_ids` are exact ordinary-current Memory OS identities returned by
  write/search receipts. Search names the store on every match; source-bound
  identities are not accepted as ordinary support edges in this slice. No
  substring or regular-expression inference creates an edge.
- A derived write without a complete current support set is rejected inside the
  same locked update and creates no snapshot or journal revision.
- Persistence, source-bound writes, Librarian selection, and recall never use a
  byte threshold to accept, discard, or hide current truth. Prompt rendering is
  an output operation, not a memory authority.
- Complete snapshot replacement computes retractions to a fixed point and
  records typed invalidations in the committed change.
- Multiple derivations are alternatives. One surviving complete derivation is
  sufficient. Rewriting the same exact conclusion with a distinct `rule_id`
  joins that path; it does not erase an already proven alternative. A directly
  observed fact remains an observation. Rewriting an existing `rule_id`
  replaces that rule's canonical premise set, so a strengthened rule cannot be
  bypassed by its earlier premise set.
- The memory-facts API returns each fact's basis and the last support
  invalidations. Fleet health and both dashboards separate observed facts,
  derived facts, and support invalidations.
- Each committed support retraction emits a structured Keeper log line with the
  revision, conclusion identity, and missing premise identities.

The core slice introduced the truth-maintenance store primitive. The stacked
public surface adds `keeper_memory_retract(memory_id, reason)`: successful
calls commit an `explicit_retract` source, return the exact removed identities
and support invalidations, and end with a typed Memory OS revision receipt.
Invalid identities, empty reasons, and absent facts do not commit a snapshot or
journal line. This source contract still requires an exact-head binary before
Keeper-facing usability can be claimed; an older live service is baseline
evidence only.

Deployment is a hard cut, not a data conversion. After the exact branch binary
is available and before it becomes the live writer, stop Keeper turns and remove
the ordinary `*.memory-current.json` and `*.memory-journal.jsonl` files under the
resolved `keepers_dir`. Source-bound snapshots have a different current schema
and remain intact. Start the binary, let Keepers establish new observations, and
prove the new files through the API before resuming autonomous work.

## Product comparison and absorption order

- [Lemmalog](https://github.com/JordyZomer/lemmalog): absorb provenance,
  retraction, proof explanation, and current-truth maintenance. Do not adopt a
  rule engine merely for feature parity.
- [OpenClaw memory architecture](https://github.com/openclaw/openclaw/blob/main/docs/concepts/memory-architecture.md): keep human-readable durable sources and
  retrieval indexes distinct from current truth.
- [Orca](https://github.com/stablyai/orca): use isolated worktrees, visible
  agent lanes, terminals, and browser evidence as the concrete direction for
  MASC IDE work.
- [Hermes Agent](https://github.com/NousResearch/hermes-agent): compare tool and
  skill acquisition with MASC's typed capability inventory and durable Keeper
  state.
- [Codex goals](https://learn.chatgpt.com/use-cases/follow-goals): preserve a
  durable objective and verifiable stopping condition across multi-hour work;
  do not treat that objective store as semantic memory.
- [Claude Code memory](https://docs.anthropic.com/en/docs/claude-code/memory):
  compare instruction and project-memory scopes, while retaining MASC's
  explicit current-truth and retraction boundary.

## Proof sequence

1. Exact source and schema checks in CI; no local build is used for this slice.
2. CI proves two observations, a derived conclusion, and a conclusion depending
   on that conclusion at the authoritative store boundary.
3. The stacked typed Keeper-facing retract tool is checked in CI. Its exact-head
   runtime then removes one observation and proves both conclusions disappear
   from recall while the journal, log, API, and dashboard show the exact chain.
4. With that public tool in place, the same scenario runs for 10+ turns, then
   at 1h, 2h, 4h, and 24h without
   changing the feature oracle.
5. Repeat across Codex, Claude Code, Antigravity, and configured API providers;
   inject runtime failure between two checkpoints and verify continuity from
   stored identities rather than transcript resemblance.

The current local service predates this source slice. Its health and dashboard
are baseline evidence only; they are not deployment proof. Exact-head runtime
and browser artifacts must be collected after CI produces the branch binary.

## Sources

- [I accidentally turned LLM memory into program analysis](https://pwning.systems/posts/llm-memory-program-analysis/)
- [Lemmalog repository](https://github.com/JordyZomer/lemmalog)
- [GeekNews topic](https://news.hada.io/topic?id=33015)
