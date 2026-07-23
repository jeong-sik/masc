---
title: Persistence read-drop root fix (recovery story for RFC-0044)
rfc: 0134
status: Active
created: 2026-05-19
implementation_prs: []
---

# RFC-0134 — Persistence read-drop root fix (recovery story for RFC-0044)

Status: Active (frontmatter SSOT)
Author: jeong-sik
Date: 2026-05-19
Supersedes: —
Related: RFC-0044 (typed reason, partial fix), RFC-0088 (counter-as-fix
umbrella), RFC-0097 (FD pressure / container reuse), RFC-0107
(`Jsonl_atomic`, atomic-write SSOT)
Plan SSOT: Error-Warn Reduction Goal §counter-as-fix
(`memory/masc-oas-log-reduction-goal-2026-05-18.html` progress report)

## 1. Problem

The WARN signature

```
[verification] persistence read drop (entry_load_error) path=… : …
```

is the single loudest line in MASC system logs on 2026-05-19:

| Metric | Value | Source |
|---|---|---|
| Total occurrences | 159 | `rg -F 'persistence read drop' system_log_2026-05-19.jsonl` |
| Log file size | 60 627 lines | `wc -l` |
| Share | 0.26 % of all lines | — |
| Reason label | `entry_load_error` (100 %) | classification grep |
| Unique `vrf-*` ids affected | 140 | `rg -o vrf-[a-f0-9]+ \| sort -u` |
| Distinct emit sites | 1 (`Safe_ops.report_persistence_read_drop`) | `rg -n 'report_persistence_read_drop'` |
| Distinct callers under load | 1 (`Workspace_verification_store.list_request_headers`) | log path inspection |

RFC-0044 typed the `reason` label (`Read_drop_reason.t` closed sum) and
raised the *reject bar* for new counters. It explicitly carved out the
recovery story:

> Non-goals: append-only persistence / WAL; **removing the counter**. A
> genuine recovery story for these surfaces requires write-side
> redesign … Scope is out of this RFC and tracked separately.
> — RFC-0044 §2

This RFC owns that tracked-separately recovery story for the dominant
emitter (verification store) and the call-chain that observes it.

### 1.1 Root cause analysis (corrected against actual data)

The original draft assumed three possible causes (schema drift /
concurrent write race / genuine corruption). Log measurement
contradicts that diagnosis.

Of the 159 events, the `detail` field decomposes into exactly two
shapes:

| Detail shape | Count | Share | Underlying error |
|---|---|---|---|
| `Verification <id> not found` | 133 | 83.6 % | `Sys.file_exists` returned `false` |
| `Sys_error … Eio.Io Unix_error (Too many open files in system, "openat", …)` | 26 | 16.4 % | `ENFILE` (per-host FD exhaustion) |

There is **zero** schema drift, JSON-syntax error, permission error,
disk corruption, or partial-write evidence in the 2026-05-19 log. The
two real causes are operational/transient, not data corruption.

### 1.2 Why the 133 "not found" cases are a TOCTOU race

`Workspace_verification_store.list_request_headers`
(`lib/workspace/workspace_verification_store.ml:185-215`) enumerates
`verifications/*.json`, then for each filename id it calls
`load_request_header`, which begins with `Sys.file_exists path` and
returns `Error "Verification <id> not found"` on `false`
(`lib/workspace/workspace_verification_store.ml:171-183`).

The sequence is:

1. `list_dir_safe dir` snapshots the directory.
2. For each `id` in the snapshot, `request_path base_path id` is
   recomputed.
3. `Sys.file_exists path` is checked.
4. `read_json_eio path` is performed.

Between (1) and (3) (or (1) and (4)) another fiber may delete or
rename the file. The current code reports this as `entry_load_error`
via `result_to_option_logged`, indistinguishable from a real load
failure.

This is the textbook TOCTOU shape; the file *did* exist at step (1)
and the absence at step (3) is not a data loss — it is concurrency
between `list_dir` and a writer that uses delete-then-replace.

### 1.3 Why the 26 ENFILE cases are FD pressure

The `Too many open files in system` shape is `ENFILE` (system-wide
descriptor table exhausted), not `EMFILE` (per-process). RFC-0097
introduced container reuse to reduce external openings; current Docker spawn
tracking is observation-only and does not manufacture a capacity bound. The 26
residuals are historical evidence, not proof of a present static limit.

### 1.4 Why the present code is counter-as-fix (anti-pattern §1)

`software-development.md` §"워크어라운드 거부 기준" §1 (Telemetry-as-fix)
applies:

> PR이 silent failure를 *visible*로 만들지만 *fix*하지 않음.
> counter는 *alarm*이지 *fix*가 아님. 데이터 손실은 그대로 발생.

For the 133 TOCTOU events specifically:

-   The "verification not found" outcome is **not data loss** — the
    verification record itself is either being concurrently rewritten
    or has been intentionally retired by a concurrent writer.
-   The counter emits as if it were data loss.
-   The caller (`list_request_headers`) drops the entry from the
    returned list and never retries.
-   No code path treats `entry_load_error` differently from a real
    file read failure (e.g. there is no retry, no reconciliation
    cycle, no operator alert wiring).

That is the precise shape RFC-0088 calls a *counter-as-fix*: the
WARN/counter exists, the data outcome is unchanged.

For the 26 ENFILE events: same surface, different cause; both share
the *no recovery, only telemetry* property.

## 2. Non-goals

-   Removing `Read_drop_reason.t` or the legacy metrics backend counter
    `metric_persistence_read_drops`. The counter remains as a real
    drop signal once the false positives (TOCTOU + ENFILE) are
    classified out.
-   Re-litigating RFC-0044's twelve grandfathered counter surfaces.
    They stay; this RFC addresses the *one* surface that produces
    >95 % of present-day WARN volume.
-   Append-only WAL / write-side schema versioning. Real data on
    2026-05-19 contains zero schema drift events; introducing schema
    versioning now is speculative work, not a measured root fix. If a
    future audit ever shows `invalid_payload` or
    `json_syntax_error` at non-trivial volume, that surface gets its
    own RFC.
-   Operator-side cleanup of the 140 distinct `vrf-*` ids. They are
    not corrupted; they have already been overwritten or retired by
    normal control-plane churn.
-   Touching the three other callers
    (`Governance_anomaly`,
    `Governance_cases_snapshot`, plus the `Safe_ops` helper itself).
    Their volume is zero on the sample day; reclassification is
    deferred until they emit.

## 3. Design

### 3.1 Distinguish TOCTOU from real load failure (PR-2 of this RFC, after PR-1 module)

Add a new variant to `Read_drop_reason.t`:

```ocaml
type t =
  | List_dir_error
  | Entry_load_error
  | Invalid_payload
  | Json_syntax_error
  | …existing…
  | Concurrent_removal
      (** Entry was present at directory enumeration but absent at
          load time. Not a data loss; the entry was concurrently
          retired by another writer. *)
  | Transient_fd_pressure
      (** Underlying open() failed with [ENFILE]/[EMFILE]. Not data
          loss; retry-eligible under RFC-0097 backpressure. *)
```

Wire mapping:

-   `Concurrent_removal` → `"concurrent_removal"`
-   `Transient_fd_pressure` → `"transient_fd_pressure"`

Both are byte-stable additions; legacy metrics backend label cardinality grows by
2.

### 3.2 Classify at the boundary

`load_request_header`
(`lib/workspace/workspace_verification_store.ml:171`) currently returns
`("a", string) result`. Promote its `Error` payload to a typed shape
that distinguishes the three cases at the syscall layer:

```ocaml
type load_error =
  | Concurrent_removal       (* Sys.file_exists = false at step (3) *)
  | Transient_fd_pressure    (* ENFILE/EMFILE caught from read_json_eio *)
  | Genuine_load_failure of string  (* anything else *)

val load_request_header :
  string -> string -> (request_header, load_error) result
```

The `Sys.file_exists` branch maps to `Concurrent_removal`. The
exception handler inspects `exn` (`Eio.Io (Eio.Exn.X (Eio_unix.Unix_error (ENFILE | EMFILE, …)))`)
and maps to `Transient_fd_pressure`. Everything else stays
`Genuine_load_failure`.

### 3.3 Caller behavior, not just label change

The caller (`list_request_headers`) currently treats
`Error _` uniformly as a drop. After this RFC:

-   `Concurrent_removal` → no WARN, no counter. The file is gone by
    design; the next snapshot will reflect that.
-   `Transient_fd_pressure` → DEBUG (not WARN). Counter emitted under
    a *separate* metric name (`metric_persistence_read_fd_pressure`
    or attached as a label) so it does not pollute the
    data-integrity counter.
-   `Genuine_load_failure` → WARN + `metric_persistence_read_drops`
    counter unchanged. This is the residual signal RFC-0044 was
    designed to track.

After PR-3 lands, the daily WARN count drops from ~159 to ~0 unless
genuine corruption appears, in which case the signal is now
meaningful.

### 3.4 Wire-up to RFC-0097 backpressure (optional, PR-4)

`Transient_fd_pressure` is a known input to RFC-0097's spawn throttle.
The verification-store caller can opt into a single retry (with a
short jitter) before downgrading the entry. This is not required for
WARN-volume reduction (the 26 cases are already a minority); it is
listed only to make the integration boundary explicit.

### 3.5 No write-side change in this RFC

The TOCTOU race is closed on the *read* side by classifying, not by
serialising the writer. Forcing writer→reader serialisation across
the entire `verifications/` directory would require a process-wide
lock and is a worse trade-off than tolerating the race.

If a future event log shows a *write-side* race that loses data (e.g.
two writers racing on the same `vrf-*` id, partial bytes left on
disk), that is a separate RFC and likely re-uses RFC-0107
(`Jsonl_atomic`) on the write path. As of 2026-05-19 there is no such
evidence.

## 4. Migration plan

| PR | Scope | Files | Reversible |
|---|---|---|---|
| PR-1 | Add `Concurrent_removal` + `Transient_fd_pressure` to `Read_drop_reason.t`; wire `to_wire`/`of_wire`; no callsite change. | `lib/core/read_drop_reason.{ml,mli}`, alcotest | Yes (pure additive) |
| PR-2 | Promote `Workspace_verification_store.load_request_header` Error type to typed `load_error`. Callers continue to convert via a shim that maps to existing wire reasons. | `lib/workspace/workspace_verification_store.{ml,mli}`, callers in same module, alcotest | Yes |
| PR-3 | In `list_request_headers`, classify the three branches. Skip WARN + counter for `Concurrent_removal`; emit DEBUG (no counter) for `Transient_fd_pressure`; keep WARN + counter for `Genuine_load_failure`. | `lib/workspace/workspace_verification_store.ml` | Yes |
| PR-4 (optional) | Single-shot retry for `Transient_fd_pressure` with jitter; instrument under separate metric. | `lib/workspace/workspace_verification_store.ml`, `lib/keeper/keeper_unified_metrics.ml` (or equivalent) | Yes |

PR-1 is independent and can land alone. PR-2 is wire-compatible (shim
preserves existing labels). PR-3 is the visible behavior change and
the point at which daily WARN volume should drop. PR-4 is deferred
unless ENFILE volume rises.

No removal of `Safe_ops.report_persistence_read_drop`. The function
stays as the SSOT emitter for the *genuine* residual; what changes is
that callers stop feeding it the TOCTOU/FD cases.

## 5. Verification

### 5.1 Standalone tests

-   PR-1: alcotest covering wire round-trip for the two new variants.
-   PR-2: alcotest for `load_request_header`'s three error branches,
    using a temp dir + race fixture (delete-during-enumerate, fd
    exhaustion via `setrlimit` if available, malformed JSON).
-   PR-3: alcotest for `list_request_headers` confirming that
    `Concurrent_removal` does not increment the
    `metric_persistence_read_drops` counter.

### 5.2 Production signal

After PR-3 lands on `main`, re-run the measurement command on a fresh
day's log:

```
rg -F 'persistence read drop' /Users/dancer/me/.masc/logs/system_log_<date>.jsonl | wc -l
```

Acceptance: count drops to ≤ 5 / day on a comparable-traffic day,
versus 159 on 2026-05-19. Any residual is by construction a
`Genuine_load_failure` and triggers a real follow-up.

### 5.3 Counter-as-fix self-check (per §"워크어라운드 거부 기준")

This RFC is itself audited against the seven-item checklist:

1.   [ ] "makes X visible" only — **No.** PR-3 removes false-positive
     emissions; it does not add a new visibility surface.
2.   [ ] string/substring/prefix classifier added — **No.** The new
     variants are closed-sum members; the classifier lives at the
     syscall boundary (typed `exn` match), not on log strings.
3.   [ ] "PR #N only fixed K of M sites" — **No.** Other surfaces
     have zero current volume; addressing them is deferred *with
     evidence requirement*, not deferred *with a counter*.
4.   [ ] `_ ->` catch-all added — **No.** The new exception match
     enumerates `ENFILE` and `EMFILE` explicitly; everything else is
     `Genuine_load_failure of string`, which is itself the residual
     category, not a catch-all that hides shape.
5.   [ ] cap / cooldown / dedup / repair — **No.**
6.   [ ] test backdoor — **No.**
7.   [ ] same typo N times — **No.** Single emit site.

## 6. Trade-offs

| | Pro | Con |
|---|---|---|
| Read-side classification only | Localised change, reversible, no writer workspace collaboration cost | TOCTOU window still exists; if a writer is *also* buggy the bug is now invisible at this surface |
| Two new `Read_drop_reason.t` variants | Compile-time exhaustiveness everywhere | legacy metrics backend label cardinality +2 |
| Separate metric for FD pressure (PR-4) | Data-integrity counter stops being polluted | One more metric to monitor |
| No write-side WAL | Matches measured cause distribution (0 corruption events) | If write-side corruption ever appears, follow-up RFC needed |

## 7. Open questions

1.   Should `Concurrent_removal` emit a DEBUG line (for debugging
     races) or be entirely silent? Default proposal: silent — the
     directory snapshot at the next call will reflect the new state,
     so no operator decision depends on the event.
2.   Should the three other callers
     (`Governance_anomaly`,
     `Governance_cases_snapshot`, `Governance_cases_snapshot.load_case`)
     receive the same typed-error promotion proactively? Default
     proposal: no — they currently emit zero WARNs/day; promoting
     speculatively is N-of-M scope creep (anti-pattern §3). Each
     follows the same template when its own volume appears.
3.   For PR-2 (typed `load_error`), should `Genuine_load_failure`
     carry `Read_drop_reason.t` (`Invalid_payload` vs
     `Json_syntax_error`) instead of `string`? Default proposal: yes
     in a follow-up, no in PR-2 to keep diff minimal.

## 8. Acceptance

-   PR-1 merged.
-   PR-2 merged with shim preserving existing wire labels.
-   PR-3 merged; next-day log shows `persistence read drop` count
    ≤ 5 / day (target 0).
-   This RFC transitions Draft → Active on PR-1 merge → Implemented
    on PR-3 merge → Closed on PR-4 decision (lands or formally
    deferred with re-measurement evidence).

## 9. References

-   user manifest `software-development.md` §워크어라운드 거부 기준 §1
    (Telemetry-as-fix).
-   `memory/feedback_lint_string_classifier_is_workaround_not_fundamental.md`.
-   `memory/feedback_hardcoding_and_legacy_zero_tolerance.md`.
-   RFC-0044 (`docs/rfc/RFC-0044-persistence-read-drop-typed.md`) —
    prior step on the labeling axis.
-   RFC-0088 — counter-as-fix umbrella.
-   RFC-0097 — FD pressure / container reuse (closed the production
    breach; this RFC handles the read-side residual classification).
-   RFC-0107 — `Jsonl_atomic` (atomic-write SSOT; not needed here but
    referenced as the canonical write-side primitive if write-side
    corruption ever appears).
-   Plan SSOT (Error-Warn Reduction Goal) §counter-as-fix.

## 10. WORKAROUND-CARRYOVER

None. This RFC is a root fix at the read-side classification boundary,
not a counter, cap, cooldown, dedup, or repair. The existing counter
(`metric_persistence_read_drops`) is *preserved* but its emission
volume is reduced by classifying out false positives — the residual
becomes a real signal, not a workaround.
