(** Keeper_recall_injection_ledger — RFC-0264 P2: per-turn recall injection trace.

    On each turn where Memory OS recall renders a non-empty advisory block, this
    appends a deterministic record of which current fact keys reached the
    prompt. It is the join key between "what recall showed this trace" and the
    turn outcome (execution_receipt carries trace_id + current_task_id; the
    forge carries PR/CI merge state), consumed offline by recall_outcome_eval
    (RFC-0264 P3) to compute recall_relevance / recall_harm.

    Schema v4 is the only accepted wire. It removes every episode-era field and
    records only current fact-key deltas. A keeper's first append in each
    process is a reset row, so replay replaces any durable pre-restart state
    instead of incorrectly retaining keys deleted while the process was down.
    There is no reader or migration path for earlier schemas.

    Delta rows carry only fact keys that changed since the keeper's immediately
    preceding row ({!delta}), plus a
    [content_hash] of the full injected set so a reader can detect "did the
    injected set change" without materializing it, and the O(1)
    [n_facts_in_store] counter.

    Current rows require exact [schema_version = 4] and carry a [delta].
    {!materialize} applies each row to the keeper's running state. A fresh
    process's first row for a keeper is diffed against the empty set, so it is
    automatically a full accounting while retaining one current wire shape.

    The read-only consumer is {!Keeper_recall_outcome_eval}, whose full-history
    scan makes replay exact for the current store.

    Properties:
    - Append-only, never read on the hot path -> cannot change recall behaviour.
    - Best-effort: a write failure is logged and never aborts the turn.
    - Bounded: uses the shared [Dated_jsonl] day-split layout
      ([masc_root/recall_injections/YYYY-MM/DD.jsonl]), same per-day mutex
      registry as the cost / receipt appenders. Append never performs retention
      on the hot path; startup/periodic JSONL maintenance prunes this store via
      [MASC_JSONL_RETENTION_DAYS] by calling [prune_older_than].
    - Deterministic: keys are [memory_id] outputs derived from exact claim bytes,
      so the same trace renders a byte-identical record.
    - Failure-visible: when recall returns an unavailable advisory, the optional
      [failure_reason] records the bounded reason label instead of making the
      side-effect record look like an empty successful injection. *)

val base_dir : masc_root:string -> string
(** Directory that stores recall injection JSONL day files. *)

type delta =
  { reset : bool
  ; added_fact_keys : string list
  ; removed_fact_keys : string list
  ; content_hash : string
  }
  (** [reset = true] clears the keeper's replay state before applying this row.
      The remaining fields carry only fact keys that changed relative to the keeper's
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
  ; delta : delta
  }
(** Typed subset of the append schema consumed by the read-only outcome
    evaluator. Field ownership stays here so the consumer does not duplicate
    ledger JSON field names. *)

type decode_error =
  [ `Expected_object
  | `Missing_field of string
  | `Invalid_field of string
  | `Unexpected_field of string
  | `Unsupported_schema_version of int
  ]
(** Bounded decode failure for read-only consumers that must surface schema
    drift instead of silently dropping malformed rows. *)

val record_of_json_result : Yojson.Safe.t -> (record, decode_error) result

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

val content_hash_of : fact_keys:string list -> string
(** Stable digest over the full injected set (order/duplicate independent). Not
    a security digest — a cheap change-detection / self-consistency signal. *)

type materialized =
  { record : record
  ; fact_keys : string list
  }
(** [record] paired with the full fact-key set actually in effect at
    that row, after replaying {!delta} against the keeper's prior rows. *)

val materialize : record list -> materialized list
(** Reconstruct the full injected key set at each record by replaying
    [delta] per [keeper_id]. Precondition: [records] is already in
    chronological (oldest-first) order — {!Keeper_recall_outcome_eval}'s
    full-tree scan already provides this, so no re-sort happens here (a
    re-sort by [ts] would be *unsound*: true
    chronology is append order, which the caller already preserves). Each
    delta applies added/removed keys to the keeper's state, starting from the
    empty set for its first appearance. Cross-keeper relative order in the
    output is unspecified; per-keeper relative order matches the input. *)

val append
  :  ?failure_reason:string
  -> masc_root:string
  -> keeper_id:string
  -> trace_id:string
  -> turn:int
  -> injected_fact_keys:string list
  -> n_facts_in_store:int
  -> now:float
  -> unit
  -> unit
(** Append one injection record. Computes the delta against [keeper_id]'s
    previous [injected_fact_keys] (in-memory, process-local, scoped by
    [(masc_root, keeper_id)]) and writes a v4 delta row. A keeper's first
    append in a fresh process (no prior in-memory state) writes [reset = true]
    and diffs against the empty set, so its row is a full current baseline.
    Replay clears the durable pre-restart state at that row before applying the
    baseline.

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
      registry that {!append} diffs against. Test isolation and restart
      simulation only; the next append emits an explicit reset baseline. *)
end
