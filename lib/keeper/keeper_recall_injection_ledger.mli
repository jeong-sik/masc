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
      registry as the cost / receipt appenders. Startup/periodic JSONL
      maintenance prunes this store via [MASC_JSONL_RETENTION_DAYS], and
      callers can trigger immediate retention through [prune_older_than] or
      [append ~retention_days].
    - Deterministic: keys are [claim_identity] outputs (the identity SSOT — the
      producer [claim_id] when present, else [normalize_claim]) and [trace_id:gN]
      episode keys, so the same trace renders a byte-identical record.
    - Failure-visible: when recall returns an unavailable advisory, the optional
      [failure_reason] records the bounded reason label instead of making the
      side-effect record look like an empty successful injection. *)

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
  -> ?retention_days:int
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
    [Eio.Cancel.Cancelled]. When [retention_days] is positive, the underlying
    dated JSONL store performs its opportunistic once-per-process-day prune
    during append. *)

val prune_older_than
  :  masc_root:string
  -> retention_days:int
  -> int
(** Delete recall injection day-files older than [retention_days] days.
    Thin wrapper over {!Dated_jsonl.prune}; returns the number of files
    deleted. *)
