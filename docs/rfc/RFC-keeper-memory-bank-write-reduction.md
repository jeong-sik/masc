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
  bank rows survive is the LLM librarian returning keep/rewrite/forget, with
  deterministic code validating schema/provenance and atomically applying that
  plan (spec-12 §Compaction). This is also the forward store's model: Memory OS
  already runs scheduled per-keeper LLM consolidation
  (`server_bootstrap_maintenance.ml` → `Keeper_memory_os_consolidation_runtime`).

Both levers point the same way as the parent RFC: **read from and consolidate in
Memory OS; stop feeding the bank.** Continuity is unaffected — it comes from OAS
checkpoint + typed MASC metadata, not `.memory.jsonl` (parent RFC §1.4).

## §5 Plan — staged, each an independent PR with rollback

Operationalizes the parent RFC's Stages 2–3 for this bug; no new heuristic, no
compaction re-wire.

- **S1 (read repoint, smallest safe step, fixes the visible complaint).** Point
  the operator `#keepers` memory panel to Memory OS facts instead of the raw bank
  append log, one read surface at a time (parent §Stage 2). Read-only, reversible,
  no write or continuity change. Operator immediately sees the LLM-consolidated,
  retention-bounded store rather than idle-prose dups.
- **S2 (write reduction at source).** Route explicit `keeper_memory_write` and
  post-turn tool-result notes to the Memory OS typed producer; stop the bank
  append. Enforce the Write Contract so operating-constraint prose is not a
  persistable memory operation. Keeps continuity on snapshot cache.
- **S3 (retire).** Once S1/S2 land and bake, remove `keeper_memory_bank*` + the
  `.memory.jsonl` path + the dead compaction, per parent §Stage 4. Until then the
  bank is written-but-not-read.

## §6 Anti-workaround declaration

Rejected as workarounds (CLAUDE.md workaround bar): (a) any similarity/threshold
dedup at the bank write or compaction boundary (RFC-0332); (b) lowering
compaction `target_notes`/`trigger_bytes` to "run more often" (symptom
suppression; the key is exact-match anyway); (c) a counter/telemetry that makes
dups visible without stopping them; (d) an external heuristic cleanup script
(non-deterministic, recurs — a one-time truncate + backup is *cleanup*, not
*fix*).

## §7 First PR and verification

First PR = **S1 for the single `#keepers` panel surface** (`keeper_status.ml` /
the dashboard keeper-detail read), gated behind an env flag defaulting to the
current bank read so it is a no-op until validated (parent RFC Stage-1 flag
convention, `Keeper_memory_bank_env` SSOT). Verification: read-only harness
diffing panel JSON for a keeper with known bank dups vs its Memory OS facts;
unit test pins the flag default (no behavior change) and the flipped path
(facts source). Live sanity: `#keepers?keeper=idealist` renders facts, not the
18 idle-note dups.

## §8 Rollback

Each stage is an independent PR. S1/S2 sit behind env flags defaulting to
current behavior, so revert is an env flip. S3 is the only irreversible stage
and lands only after S1/S2 bake.
