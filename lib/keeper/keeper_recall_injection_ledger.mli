(** Keeper_recall_injection_ledger — RFC-0264 P2: per-turn recall injection trace.

    On each turn where Memory OS recall renders a non-empty advisory block, this
    appends a deterministic record of which fact/episode keys reached the
    prompt. It is the join key between "what recall showed this trace" and the
    turn outcome (execution_receipt carries trace_id + current_task_id; the
    forge carries PR/CI merge state), consumed offline by recall_outcome_eval
    (RFC-0264 P3) to compute recall_relevance / recall_harm.

    Schema v2 (2026-07-17, masc#25052): the pre-existing schema wrote the FULL
    injected fact/episode key list on every turn. Because {!Keeper_memory_os_recall}
    injects the store's *entire* current fact/episode set every turn (no
    selection budget existed before this change), every append cost was
    proportional to store size, not to what actually changed. With no
    compaction of this ledger, per-keeper turns accumulated O(turns * store_size)
    bytes — the same "append without compaction" class of bug diagnosed in the
    2026-07-17 board_attention_candidate boot-hang incident.

    v2 rows instead carry only the fact/episode keys that changed since the
    keeper's immediately preceding row ({!payload} = [Delta]), plus a
    [content_hash] of the full injected set so a reader can detect "did the
    injected set change" without materializing it, and plus store-size
    counters ([n_facts_in_store] / [n_episodes_in_store]) that were already
    (or are now) O(1) scalars — unrelated to the growth bug and kept as-is.

    Legacy rows (schema_version absent, written before this change) still
    decode as {!payload} = [Full_snapshot]: the full list they always carried
    IS the exact injected set at that turn, so no replay is needed for them.
    {!materialize} treats a [Full_snapshot] row as resetting a keeper's running
    state to exactly that row's lists, and a [Delta] row as applying
    added/removed to the running state — so mixed legacy/v2 history for the
    same keeper replays correctly, and a fresh process's first v2 row for a
    keeper (diffed against an empty prior state) is automatically a full
    accounting even though it is tagged [Delta].

    Two real (non-telemetry) readers exist and are adapted by this change:
    {!Keeper_recall_outcome_eval} (offline, full-history scan — replay is
    always exact) and the dashboard memory-quality summary in
    [Server_dashboard_http_memory_subsystems] (bounded recent-lines sample —
    replay is exact for any keeper whose sampled window include its own
    genesis row, which the schema change makes far more likely since v2 rows
    are only written on an actual change).

    Properties:
    - Append-only, never read on the hot path -> cannot change recall behaviour.
    - Best-effort: a write failure is logged and never aborts the turn.
    - Bounded: uses the shared [Dated_jsonl] day-split layout
      ([masc_root/recall_injections/YYYY-MM/DD.jsonl]), same per-day mutex
      registry as the cost / receipt appenders. Append never performs retention
      on the hot path; startup/periodic JSONL maintenance prunes this store via
      [MASC_JSONL_RETENTION_DAYS] by calling [prune_older_than].
    - Deterministic: keys are [claim_identity] outputs (producer [claim_id] when
      present, else exact source event plus claim payload) and [trace_id:gN]
      episode keys, so the same trace renders a byte-identical record.
    - Failure-visible: when recall returns an unavailable advisory, the optional
      [failure_reason] records the bounded reason label instead of making the
      side-effect record look like an empty successful injection. *)

val base_dir : masc_root:string -> string
(** Directory that stores recall injection JSONL day files. *)

type payload =
  | Full_snapshot of
      { fact_keys : string list
      ; episode_keys : string list
      }
  (** The complete injected key sets at this turn. Written by legacy
      (schema_version absent) rows, and by {!to_json} (kept for round-trip
      tests and fixtures that need a self-contained row). *)
  | Delta of
      { added_fact_keys : string list
      ; removed_fact_keys : string list
      ; added_episode_keys : string list
      ; removed_episode_keys : string list
      ; content_hash : string
      }
  (** Only the fact/episode keys that changed relative to the keeper's
      previous row. [content_hash] is {!content_hash_of} over the full
      injected set at this turn, so a reconstructed set can be checked for
      internal consistency without re-deriving it from application state. *)

type record =
  { keeper_id : string
  ; trace_id : string
  ; turn : int
  ; ts : float option
  ; failure_reason : string option
  ; n_facts_in_store : int option
  ; n_episodes_in_store : int option
  ; payload : payload
  }
(** Typed subset of the append schema consumed by read-only dashboard/eval
    surfaces. Field ownership stays here so consumers do not duplicate ledger
    JSON field names. *)

type decode_error =
  [ `Expected_object
  | `Missing_field of string
  | `Invalid_field of string
  | `Unsupported_schema_version of int
  ]
(** Bounded decode failure for read-only consumers that must surface schema
    drift instead of silently dropping malformed rows. *)

val record_of_json_result : Yojson.Safe.t -> (record, decode_error) result
val record_of_json : Yojson.Safe.t -> record option
(** Compatibility wrapper over {!record_of_json_result}. New read paths that need
    observability should use the result-returning decoder. *)

val failure_reason_unknown_label : string
val bounded_failure_reason_label : string -> string
(** Collapse recall failure labels to the bounded producer set. Unknown producer
    strings are grouped as {!failure_reason_unknown_label} to avoid high-cardinality
    dashboard output. *)

val diff_keys : previous:string list -> current:string list -> string list * string list
(** [diff_keys ~previous ~current] is [(added, removed)]: keys in [current] but
    not [previous], and keys in [previous] but not [current]. Order-independent
    (both inputs are treated as sets); output lists are sorted. Pure. *)

val apply_delta : previous:string list -> added:string list -> removed:string list -> string list
(** [apply_delta ~previous ~added ~removed] is [(previous ∪ added) \ removed],
    sorted and deduplicated. Inverse companion to {!diff_keys}: for any
    [previous]/[current], applying the delta {!diff_keys} computed reproduces
    [current] exactly (as a set). Pure. *)

val content_hash_of : fact_keys:string list -> episode_keys:string list -> string
(** Stable digest over the full injected set (order/duplicate independent). Not
    a security digest — a cheap change-detection / self-consistency signal. *)

type materialized =
  { record : record
  ; fact_keys : string list
  ; episode_keys : string list
  }
(** [record] paired with the full fact/episode key set actually in effect at
    that row, after replaying {!payload} against the keeper's prior rows. *)

val materialize : record list -> materialized list
(** Reconstruct the full injected key set at each record by replaying
    [payload] per [keeper_id]. Precondition: [records] is already in
    chronological (oldest-first) order — both {!Keeper_recall_outcome_eval}'s
    full-tree scan and {!Dated_jsonl.read_recent_lines} already provide this,
    so no re-sort happens here (a re-sort by [ts] would be *unsound*: [ts] is
    optional and legacy rows may omit it; true chronology is append order,
    which the callers already preserve). A [Full_snapshot] row resets the
    keeper's running state to exactly its own lists; a [Delta] row applies
    added/removed to the running state (starting from the empty set for a
    keeper's first appearance in [records], which is exact when [records]
    covers that keeper's full history, and a documented under-approximation —
    never an over-approximation — otherwise). Cross-keeper relative order in
    the output is unspecified; per-keeper relative order matches the input. *)

val to_json
  :  ?failure_reason:string
  -> keeper_id:string
  -> trace_id:string
  -> turn:int
  -> injected_fact_keys:string list
  -> injected_episode_keys:string list
  -> n_facts_in_store:int
  -> now:float
  -> unit
  -> Yojson.Safe.t
(** Legacy (schema v1, [Full_snapshot]) pure record serialiser. Exposed for
    round-trip tests and fixtures that need a self-contained row independent of
    any keeper's prior state. Not used by {!append} since schema v2. *)

val append
  :  ?failure_reason:string
  -> masc_root:string
  -> keeper_id:string
  -> trace_id:string
  -> turn:int
  -> injected_fact_keys:string list
  -> injected_episode_keys:string list
  -> n_facts_in_store:int
  -> now:float
  -> unit
  -> unit
(** Append one injection record. Computes the delta against [keeper_id]'s
    previous [injected_fact_keys]/[injected_episode_keys] (in-memory,
    process-local, scoped by [(masc_root, keeper_id)]) and writes a v2
    [Delta] row: this is the fix for the O(store_size) per-turn growth
    ([injected_fact_keys]/[injected_episode_keys] here are still the caller's
    full current sets — computing that live snapshot is not itself the growth
    bug; persisting a full copy of it every turn was). A keeper's first
    append in a fresh process (no prior in-memory state) diffs against the
    empty set, so its row's "delta" is the full current set — an accurate,
    one-time, bounded-by-keeper-count cost, not a per-turn one.

    Best-effort: never raises except to re-raise [Eio.Cancel.Cancelled].
    Retention is intentionally handled by server maintenance, not by append. *)

type prune_error =
  [ `Sys_error
  | `Unix_error
  | `Json_error
  | `Unexpected_exception
  ]
(** Bounded failure label for recall-ledger prune setup failures. *)

val string_of_prune_error : prune_error -> string
val error_label_of_exn : exn -> string
(** Bounded read-side error label for read-only dashboard consumers. *)

val prune_older_than
  :  masc_root:string
  -> retention_days:int
  -> (int, prune_error) result
(** Best-effort maintenance hook for deleting recall injection day-files older
    than [retention_days] days. [Ok count] returns the prune count reported by
    {!Dated_jsonl.prune}; this is the store-level maintenance count, not a
    filesystem guarantee that every matched unlink succeeded. [Error label]
    makes prune setup failures visible to maintenance callers after logging
    with a bounded label. [Eio.Cancel.Cancelled] is re-raised. *)

module For_testing : sig
  val reset_delta_state : unit -> unit
  (** Clear the in-memory per-(masc_root, keeper_id) "previous injected set"
      registry that {!append} diffs against. Test isolation only — production
      has no reset path (a lost registry after restart just means the next
      append per keeper is a one-time full accounting, which is safe). *)
end
