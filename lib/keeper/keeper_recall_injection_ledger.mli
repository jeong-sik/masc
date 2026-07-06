(** Keeper_recall_injection_ledger — RFC-0264 P2: per-turn recall injection trace.

    On each turn where Memory OS recall renders a non-empty advisory block, this
    appends a deterministic record of which fact/episode keys reached the
    prompt. It is the join key between "what recall showed this trace" and the
    turn outcome (execution_receipt carries trace_id + current_task_id; the
    forge carries PR/CI merge state), consumed offline by recall_outcome_eval
    (RFC-0264 P3) to compute recall_relevance / recall_harm.

    Properties:
    - Append-only, never read on the hot path -> cannot change recall behaviour.
    - Best-effort: a write failure is logged and never aborts the turn.
    - Bounded: uses the shared [Dated_jsonl] day-split layout
      ([masc_root/recall_injections/YYYY-MM/DD.jsonl]), same per-day mutex
      registry as the cost / receipt appenders. Append never performs retention
      on the hot path; startup/periodic JSONL maintenance prunes this store via
      [MASC_JSONL_RETENTION_DAYS] by calling [prune_older_than].
    - Deterministic: keys are [claim_identity] outputs (the identity SSOT — the
      producer [claim_id] when present, else [normalize_claim]) and [trace_id:gN]
      episode keys, so the same trace renders a byte-identical record.
    - Failure-visible: when recall returns an unavailable advisory, the optional
      [failure_reason] records the bounded reason label instead of making the
      side-effect record look like an empty successful injection. *)

val base_dir : masc_root:string -> string
(** Directory that stores recall injection JSONL day files. *)

type record =
  { keeper_id : string
  ; trace_id : string
  ; turn : int
  ; injected_fact_keys : string list
  ; injected_episode_keys : string list
  ; failure_reason : string option
  }
(** Typed subset of the append schema consumed by read-only dashboard/eval
    surfaces. Field ownership stays here so consumers do not duplicate ledger
    JSON field names. *)

type decode_error =
  [ `Expected_object
  | `Missing_field of string
  | `Invalid_field of string
  ]
(** Bounded decode failure for read-only consumers that must surface schema
    drift instead of silently dropping malformed rows. *)

val record_of_json_result : Yojson.Safe.t -> (record, decode_error) result
val decode_error_to_string : decode_error -> string

val failure_reason_unknown_label : string
val bounded_failure_reason_label : string -> string
(** Collapse recall failure labels to the bounded producer set. Unknown producer
    strings are grouped as {!failure_reason_unknown_label} to avoid
    high-cardinality dashboard output. The bounded producer set is the Memory OS
    recall unavailable reasons: [read_error], [fact_store_parse_error],
    [episode_store_parse_error], and [prompt_render_error]. *)

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
(** Pure record serialiser. Exposed for round-trip tests. [failure_reason],
    when present, is a bounded reason label from the recall renderer. *)

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
(** Append one injection record. Best-effort: never raises except to re-raise
    [Eio.Cancel.Cancelled]. Retention is intentionally handled by server
    maintenance, not by append. *)

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
