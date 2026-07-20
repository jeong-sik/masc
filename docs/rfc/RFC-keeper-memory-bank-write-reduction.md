---
rfc: "keeper-memory-bank-write-reduction"
title: "Keeper memory-bank near-dup accumulation — write reduction, not write-boundary dedup"
status: Draft
created: 2026-07-20
updated: 2026-07-20
author: vincent (drafted with Claude)
supersedes: []
superseded_by: null
related: ["keeper-memory-consolidation", "0332", "0247", "0285", "0257"]
implementation_prs: []
---

# RFC: Keeper memory-bank near-dup accumulation — write reduction, not write-boundary dedup

Status: Draft · slug-only (README §정책) · 2026-07-20

Companion to [`RFC-keeper-memory-consolidation`](./RFC-keeper-memory-consolidation.md).
That RFC decides the *destination* (deprecate memory_bank into Memory OS). This
RFC pins the *specific live bug* (dashboard `#keepers` shows a keeper's memory
as near-identical idle prose), records why the three obvious fixes are
forbidden by existing contract, and resolves the apparent RFC-0332 vs
consolidation-§4 conflict that has already produced two rejected PRs.

## §1 Problem — the bank is an unbounded append log of operating-constraint prose

Live evidence (`<base-path>/.masc/keepers/idealist.memory.jsonl`, measured
2026-07-19):

- 52 rows; **18 of them** are one restated idle note
  `**FINAL archive of open loop "Wait for genuinely new signal" — turn=N, RESOLVED**`,
  differing only in `turn=N` (82→93, non-monotonic across keeper restarts) and a
  backlog count. Accumulated ~1 every 12 minutes over a 3.5h window.
- Source mix: `progress_consolidation` 26, `message_metadata` 17, `explicit_memory_write` 5,
  `model_state_block` 4. `message_metadata`/`model_state_block` are written by code
  that **no longer exists** in `lib/` — orphaned-provenance rows the append log
  never ages out.

Root cause is three independent layers (all CONFIRMED, adversarial verify pass):

1. **Append-only writers, no lifecycle.** The three production writers of the bank
   file — `append_explicit_memory_note` (`keeper_memory_bank.ml`, via the
   `keeper_memory_write` tool `keeper_tool_memory_runtime.ml`),
   `append_memory_notes_from_tool_results` (via `lib/memory.ml:104` →
   `keeper_agent_run_post_turn_memory.ml`), and `append_voice_output` — gate only on
   `is_meaningful_memory_text` (placeholder/length) and append unconditionally.
2. **The only cleanup path is dead in production.** `compact_memory_bank_if_needed`
   (`keeper_memory_bank.ml:544`) has zero production callers (test-only). It was
   production-wired in an earlier keeper-turn-loop change and then deliberately
   hard-cut by **#24721 ("hard-cut heuristic bank compaction") + #24727 ("remove
   heuristic compaction facade")**.
3. **The (dead) dedup key is digit-preserving.** `normalize_memory_text_key`
   (`keeper_memory_bank_selection.ml`) strips punctuation/case but not digits, so
   `turn=91` and `turn=92` are distinct keys — the idle notes would survive dedup
   even if compaction ran.

The content itself is the deeper miss: `FINAL archive … RESOLVED`,
`Release task-1851`, `waiting for genuine signal` are **task-sequencing and
operating-constraint prose**, which `KEEPER-STATE-OWNERSHIP.md` states are *not
memory-note categories*. The bank is being used as an idle-deliberation journal.

Blast radius is bounded but real: the bank's **live-prompt slot is already dead**
(`keeper_run_prompt.ml:78` hardcodes `memory_context = ""`), and live recall runs
on Memory OS, so this does not poison keeper reasoning today. It
does pollute the operator-facing `#keepers` dashboard panel
(`read_keeper_memory_summary_result` feeds `dashboard_http_keeper.ml`,
`server_dashboard_http_keeper_api.ml`, `server_dashboard_http_memory_subsystems.ml`,
`keeper_status.ml`, `keeper_status_detail.ml`) and grows the file unbounded.

## §2 Why the three obvious fixes are forbidden

1. **Heuristic write-boundary dedup (jaccard/lexical threshold).** Rejected by
   **RFC-0332** ("an arbitrary score must not merge or silently discard durable
   memory … otherwise rows remain distinct") and by `spec/12-memory-systems.md`
   §Compaction ("a threshold, priority score, or capacity rule cannot decide which
   memories survive"). Two PRs took this route and were closed by the author:
   **#24300, #24313** (compile break + wrong direction + phantom "RFC-0327 §A1"
   citation). Do not attempt a third.
2. **Re-wire the deterministic compaction.** Reverts #24721/#24727, which removed
   it *twice in one day* as "heuristic", and reintroduces the exact
   threshold/capacity survival rule spec-12 forbids. Also useless here: its
   digit-preserving key (root cause 3) leaves the idle notes intact anyway.
3. **A canonicalizing stripper (drop `turn=N` before an exact-key match).**
   Deterministic and non-scoring, but `KEEPER-STATE-OWNERSHIP` §Forbidden lists
   "parser, stripper, sidecar" as mechanisms that must not decide runtime memory
   state, and RFC-0332's "otherwise rows remain distinct" reserves *any* merge
   decision for an explicit judgment boundary. Permissible only behind an
   explicit contract amendment; not assumed here.

## §3 Reconciliation — RFC-0332 vs consolidation §4

`RFC-keeper-memory-consolidation` §4 names "write-side semantic dedup" as part of
the root fix; RFC-0332 rejects "heuristic lexical-similarity dedup at the write
boundary". These are **not in conflict once scoped**: the sanctioned
"write-side semantic dedup" is the **Memory OS** typed candidate path
(`dedup_memory_candidates` / claim-identity, RFC-0285), which is an explicit
typed operation — *not* a jaccard threshold layered onto the memory_bank. The
two closed PRs applied the heuristic to the bank and were correctly rejected.
This RFC records that scoping so the distinction is citable and not re-litigated.

## §4 Sanctioned direction — reduce bank writes, lean on Memory OS

Per `spec/12-memory-systems.md` §Write Contract and §Compaction plus
`KEEPER-STATE-OWNERSHIP`, exactly two levers are in-contract:

- **Write-contract enforcement (source).** Operating-constraint / task-sequencing
  prose is not a memory-note category. The `keeper_memory_write` tool and the
  post-turn tool-result writer should stop persisting idle turn-status
  restatements as durable notes. This is enforced by *what is a valid memory
  operation*, not by scoring existing rows.
- **LLM-judged consolidation (survival).** The only sanctioned decider of which
  rows survive is the LLM librarian returning keep/rewrite/forget, with
  deterministic code validating schema/provenance and atomically applying that
  plan (spec-12 §Compaction; RFC-0247 "a fact's value is the librarian's
  judgment, not a number"). Memory OS *has* this pass
  (`Keeper_memory_os_consolidation_runtime`, wired in
  `server_bootstrap_maintenance.ml`) but it is **disabled by default**
  (`Env_config.KeeperMemoryOs.consolidation_enabled_default = false`).

Both levers point the same way as the parent RFC: **consolidate in Memory OS via
the LLM pass; stop feeding the bank.** Continuity is unaffected — it comes from
OAS checkpoint + typed MASC metadata, not `.memory.jsonl` (parent RFC §1.4).

## §4b Memory OS facts have the *same disease* — and its retention is off

Re-pointing the dashboard to Memory OS facts (naive §5 S1) does **not** fix the
complaint; it relocates it. Measured live (`idealist.facts.jsonl`, 2026-07-20):

- **449 fact rows**; `valid_until` present on **0 of 449** — no fact carries an
  expiry.
- claim_kind: `durable_knowledge` 296, `self_observation` 86, `external_state`
  57, absent 10. category: `lesson` 116, `ephemeral` 102, `constraint` 99,
  `validated_approach` 68, … — the bulk is the same operating-constraint prose
  the bank holds ("A constraint exists that limits tool calls to non-…",
  "Operator action required: token identity separation"), mis-tagged
  `durable_knowledge`.

Why nothing decays: `fact_effective_valid_until fact = fact.valid_until`
(`keeper_memory_os_types.ml`; the comment: "No category … only `valid_until` has
that authority"). Per-kind / per-category TTL was **deliberately removed** — the
RFC-0259 supersession (2026-06-25) states "retention/ranking effects … are no
longer active policy," consistent with RFC-0247 (judgment = LLM, not a number).
GC (`gc_enabled_default = true`) faithfully removes rows past `valid_until`, but
since the librarian never emits one, GC is a no-op and every fact is permanent.

**Consequence — the Memory OS fundamental fix is NOT deterministic.** Re-adding a
TTL / category / cap rule would revert the same governance decision that rejected
bank compaction (RFC-0332, #24721/#24727, the RFC-0259 supersession). The only
in-contract levers are (i) **enable the LLM-judged consolidation** — an operator
decision (scheduled per-keeper provider calls; the fleet has known provider-SPOF
issues, so it needs shadow validation + cost sign-off, not a unilateral default
flip), and (ii) **improve librarian extraction** so operating-constraint /
task-sequencing prose is not extracted as a durable fact (KEEPER-STATE-OWNERSHIP:
"not memory-note categories") — an LLM-boundary change verified by the memory
eval harness, not a deterministic unit test.

## §5 Plan — staged, each an independent PR with rollback

Ordered by §4b: the facts store must be bounded *before* the dashboard reads it,
or S1 just relocates the junk. No new heuristic, no compaction/TTL re-wire.

- **S0 (bank write kill-switch — LANDED in this PR).** `MASC_KEEPER_MEMORY_BANK_WRITE`
  (default true = no change); when false the three bank writers skip uniformly.
  Deterministic operator gate that stops the *bank* half at the source. This is
  the only piece here that is a clean deterministic change.
- **S1 (bound the facts store — operator + LLM-boundary, not deterministic).**
  (a) Enable the LLM-judged consolidation (`consolidation_enabled`) after a shadow
  run validates it against live provider capacity; (b) tighten librarian
  extraction so operating-constraint / task-sequencing prose is not extracted as a
  durable fact. Verified by the memory eval harness, not a unit test. **Blocks S2.**
- **S2 (read repoint).** Once facts are bounded (S1), point the `#keepers` memory
  panel to Memory OS facts, one read surface at a time (parent §Stage 2).
  Read-only, reversible, env-flag defaulting to current bank read.
- **S3 (write reduction + retire).** Route explicit / tool-result notes to the
  Memory OS typed producer; stop the bank append; then remove `keeper_memory_bank*`
  + the `.memory.jsonl` path + dead compaction (parent §Stage 4).

## §6 Anti-workaround declaration

Rejected as workarounds (CLAUDE.md workaround bar): (a) any similarity/threshold
dedup at the bank write or compaction boundary (RFC-0332); (b) lowering
compaction `target_notes`/`trigger_bytes` to "run more often" (symptom
suppression; the key is exact-match anyway); (c) a counter/telemetry that makes
dups visible without stopping them; (d) an external heuristic cleanup script
(non-deterministic, recurs — a one-time truncate + backup is *cleanup*, not
*fix*); (e) **re-adding a per-kind/per-category TTL or a cap to the Memory OS
facts store** (§4b) — that reverts the RFC-0259 supersession and RFC-0247's
"judgment = LLM, not a number". Facts survival is decided by the LLM
consolidation, which must be *enabled*, not replaced with a deterministic rule.

## §7 Landed here + next PR

- **Landed in this PR (S0):** the bank write kill-switch — the one clean
  deterministic change. `dune build` + `test_keeper_memory_write` (kill-switch
  counterfactual) green; SSOT/lint green.
- **Next (S1, separate — needs operator decision):** a shadow-validation harness
  for `consolidation_enabled` (read-only: run the consolidation pass against a
  copy of each keeper's live facts, report before/after counts and what it would
  forget), so enabling it is an evidence-backed operator decision rather than a
  blind default flip. Then the librarian-extraction tightening, verified by the
  memory eval harness.

## §8 Rollback

S0 is env-reversible (`MASC_KEEPER_MEMORY_BANK_WRITE=true`, the default). S1's
consolidation enablement is env-reversible. S2 sits behind an env flag defaulting
to current behavior. S3 (retire) is the only irreversible stage and lands only
after S0–S2 bake.
