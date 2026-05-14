# RFC-0044 — Typed persistence read-drop reason + Result-based reads

Status: Draft
Author: jeong-sik
Date: 2026-05-08
Supersedes: —
Related: RFC-0042 (closed sum for keeper turn terminal code), RFC-0043
(distribute prometheus metric ownership)

## 1. Problem

Between 2026-05-07 and 2026-05-08, twelve PRs landed on `main` with the
same shape:

```
14037 fix: count execution cache invalidation failures
14058 fix: count prompt override restore failures
14059 fix: count recurring task auto-disable failures
14081 fix: count governance anomaly profile read drops
14082 fix: count team context findings read drops
14084 fix: count board post meta read drops
14085 fix: count keeper chat store read drops
14086 fix: count runtime trust decision read drops
14093 fix: count keeper exec status read drops
14094 fix: count keeper memory bank read drops
14099 fix: count generation lineage manifest read drops
14106 fix: count heartbeat history read drops
```

Each PR does the same three things at a new persistence surface:

1.  Catches an exception around a JSON read or directory list.
2.  Calls `Prometheus.inc_counter Prometheus.metric_persistence_read_drops
    ~labels:[("surface", S); ("reason", R)]` with `R` chosen ad-hoc from
    a free string.
3.  Returns an empty list / default record / `None` so the caller continues.

The PR-body claim is a fix, but the contract on disk is unchanged: the
record is still lost, the caller still sees a default, and downstream
state diverges from what the keeper actually persisted. The counter
makes the loss *visible* but does not make it *recoverable*.

This is the **telemetry-as-fix** anti-pattern that
`instructions/software-development.md §워크어라운드 거부 기준` flags as
PR-rejection grounds. The twelve already-merged PRs predate that bar
(merged 2026-05-07; instruction added 2026-05-08), so they are
grandfathered. This RFC is the close-out path so that the thirteenth
PR of the same shape can be rejected with `RFC-0044 §X` as the reason.

A second, narrower, problem rides along: the `reason` argument at every
callsite is a free string. `lib/core/safe_ops.ml` exposes three named
constants (`persistence_read_drop_reason_list_dir_error`,
`_entry_load_error`, `_invalid_payload`) but call sites freely add new
values. The Prometheus label is therefore not bounded by the type
system; new reasons are silently accepted, dashboards built around the
old set silently miss them.

## 2. Non-goals

-   **Append-only persistence / WAL.** A genuine recovery story for
    these surfaces requires write-side redesign (commit-then-emit,
    append-only journal, version-tagged records). Scope is out of this
    RFC and tracked separately. This RFC restricts to (a) typing the
    visibility surface and (b) raising the bar on adding a thirteenth
    counter without a recovery story.
-   **Removing the counter.** Once the counter exists for a surface, it
    is monitored. Replacing the counter with `Result.t` is acceptable
    only when the recovery path actually lands.
-   **Re-litigating the twelve grandfathered PRs.** They stay merged.

## 3. Design

### 3.1 Closed-sum `Read_drop_reason.t`

New module `lib/core/read_drop_reason.ml` (and `.mli`):

```ocaml
type t =
  | List_dir_error
  | Entry_load_error
  | Invalid_payload
  | Json_syntax_error
  | Lock_contention
  | Schema_version_mismatch
  | Decompression_error
  | Path_normalization_error
  | Stat_error
  | Other of string
        (** Escape hatch for one-off surfaces. PR introducing a new
            [Other] payload must justify why the value cannot be
            promoted to a constructor. Linter (§5) flags PRs that add
            [Other] for a value already used at >=2 sites. *)

val to_wire : t -> string
val of_wire : string -> t option
```

`to_wire` produces strings byte-for-byte compatible with the existing
constants (`list_dir_error`, `entry_load_error`, `invalid_payload`) so
Prometheus label cardinality does not change at swap-over.

### 3.2 Result-based read helpers (PR-3, optional)

`lib/core/safe_ops.ml` gains:

```ocaml
type ('ok, 'a) read_outcome =
  | Read_ok of 'ok
  | Read_drop of { reason : Read_drop_reason.t; path : string; detail : string }
```

Existing helpers (`read_json_file`, `read_directory`) gain `_result`
variants returning `read_outcome`. Migrating callers from
`Some/None + counter` to `Read_ok/Read_drop` is an opt-in mechanical
refactor; the counter is emitted by the caller from the typed value.

### 3.3 Migration plan

PR-1 (this RFC + module): introduce `Read_drop_reason.t` as inert,
mirroring RFC-0042 PR-1. No callsite change, no behavior change.

PR-2: change `report_persistence_read_drop` signature from
`~reason:string` to `~reason:Read_drop_reason.t`, with internal
`to_wire` for the Prometheus label. Existing `safe_ops.ml` constants
become `Read_drop_reason.to_wire List_dir_error` etc.; no wire change.
Callsites pass typed values.

PR-3 (optional): introduce `read_outcome` and migrate one surface as
the canonical example. Subsequent surfaces migrate at their own pace.

### 3.4 Reject-bar reinforcement

`instructions/software-development.md §워크어라운드 거부 기준` already
lists Telemetry-as-fix as a hard reject. This RFC adds a concrete
escape valve:

> A new persistence surface that needs visibility for read failures may
> emit `metric_persistence_read_drops` *only if* the PR also (a) uses a
> typed `Read_drop_reason.t`, and (b) either (b1) attaches an existing
> recovery RFC link, or (b2) labels the PR `WORKAROUND:
> production-blocking, deprecated path` per the override clause and
> opens a follow-up RFC for the recovery story.

PRs that add a new free-string `reason` argument or omit (b) are
declined.

## 4. Stable wire format guarantee

The Prometheus metric `masc_persistence_read_drops_total` keeps its
existing label set `(surface, reason)`. `Read_drop_reason.to_wire`
produces:

| Constructor              | Wire string                 |
| ------------------------ | --------------------------- |
| `List_dir_error`         | `list_dir_error`            |
| `Entry_load_error`       | `entry_load_error`          |
| `Invalid_payload`        | `invalid_payload`           |
| `Json_syntax_error`      | `json_syntax_error`         |
| `Lock_contention`        | `lock_contention`           |
| `Schema_version_mismatch`| `schema_version_mismatch`   |
| `Decompression_error`    | `decompression_error`       |
| `Path_normalization_error` | `path_normalization_error`|
| `Stat_error`             | `stat_error`                |
| `Other s`                | `s`                         |

Existing dashboards that filter on `reason="list_dir_error"` continue
to match. New constructors appear as new label values; cardinality
growth is bounded by the closed sum.

## 5. Drift guards

-   `scripts/lint/no-free-string-read-drop-reason.sh`: greps for
    `Prometheus.inc_counter ... metric_persistence_read_drops`
    invocations whose `reason` argument is a string literal not
    sourced from `Read_drop_reason.to_wire`. Runs in
    `fundamental-check.yml`.
-   Linter for `Other` reuse: any PR that adds a `Read_drop_reason.Other "X"`
    where `X` is already used at another site fails CI; the value must
    be promoted to a constructor.

## 6. Trade-offs

-   **Cost of the closed sum**: every new surface that needs a new
    drop reason now requires a code change in `Read_drop_reason.t`.
    This is the explicit goal — visibility decisions become reviewable.
-   **`Other` escape hatch**: leaves a small back door. Mitigated by
    the §5 lint that blocks reuse.
-   **Wire compatibility cost**: new constructor wire names should
    follow `snake_case` to match the existing convention; trivial.
-   **No recovery story**: this RFC explicitly does not solve data
    loss. Tracking issue: open an issue
    `persistence-recovery-story` after PR-1 lands and link surfaces
    that warrant it (heartbeat history first; that surface had four
    `read_drop` PRs across 2026-04 and 2026-05).

## 7. Open questions

-   Should `Other` exist at all? Strict reading of `instructions/`
    `software-development.md §AI 코드 생성 안티패턴 §1` says no — every
    new value must be a constructor. Argument for keeping `Other`: a
    single shared module owned by `lib/core/` would otherwise break on
    every new persistence surface PR. Decision deferred to PR-2 review.
-   Drift-guard placement: same workflow as `godfile-size-regression`
    or its own job? Same workflow keeps CI surface narrow.

## 8. Acceptance

This RFC is accepted when:

1.  PR-1 (inert `Read_drop_reason` module) is merged.
2.  `instructions/software-development.md §워크어라운드 거부 기준`
    cross-references this RFC as the recovery-story override valve.

PR-2 and PR-3 are tracked separately; their merging is not a
precondition for accepting RFC-0044 itself.
