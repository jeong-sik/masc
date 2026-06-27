(** Offline, read-only join from recall-injection ledger rows to local execution
    receipt outcomes.

    This is the deterministic local substrate for RFC-0264 P3. It intentionally
    does not query forge/CI/human-feedback state; those outcome sources are a
    later layer over the trace rows produced here. *)

type recall_record =
  { keeper_id : string
  ; trace_id : string
  ; turn : int
  ; injected_fact_keys : string list
  ; injected_fact_key_count : int
  ; injected_episode_key_count : int
  ; failure_reason : string option
  ; ts : float option
  }

type receipt_record =
  { keeper_name : string
  ; trace_id : string
  ; outcome : string
  ; terminal_reason_code : string
  ; current_task_id : string option
  ; ended_at : string option
  ; ended_at_unix : float option
  }

type outcome_bucket =
  | Outcome_ok
  | Outcome_skipped
  | Outcome_error
  | Outcome_cancelled
  | Outcome_unknown
  | Outcome_missing_receipt

type trace_row =
  { trace_id : string
  ; keeper_id : string option
  ; recall_records : int
  ; fact_keys : string list
  ; injected_fact_keys : int
  ; recall_failure_records : int
  ; receipt : receipt_record option
  ; outcome_bucket : outcome_bucket
  }

type fact_key_summary =
  { fact_key : string
  ; injected_count : int
  ; recall_records : int
  ; recall_failure_records : int
  ; trace_count : int
  ; outcome_ok : int
  ; outcome_skipped : int
  ; outcome_error : int
  ; outcome_cancelled : int
  ; outcome_unknown : int
  ; outcome_missing_receipt : int
  }

type t =
  { masc_root : string
  ; recall_dir : string
  ; receipts_dir : string
  ; read_error_count : int
  ; malformed_jsonl_rows : int
  ; invalid_recall_rows : int
  ; invalid_receipt_rows : int
  ; load_errors : string list
  ; recall_records : int
  ; recall_traces : int
  ; traces_with_receipt : int
  ; traces_without_receipt : int
  ; injected_fact_keys : int
  ; recall_failure_records : int
  ; outcome_ok : int
  ; outcome_skipped : int
  ; outcome_error : int
  ; outcome_cancelled : int
  ; outcome_unknown : int
  ; fact_key_summaries : fact_key_summary list
  ; traces : trace_row list
  }

val evaluate : masc_root:string -> t
(** Read [masc_root/recall_injections/**/*.jsonl] and
    [masc_root/keepers/*/execution-receipts/**/*.jsonl], joining on [trace_id].
    Malformed/unreadable/invalid rows are excluded from aggregation and surfaced
    through the load-diagnostic counters and [load_errors]. *)

val outcome_bucket_to_string : outcome_bucket -> string
val to_json : ?trace_limit:int -> ?fact_key_limit:int -> t -> Yojson.Safe.t
val render_text : ?trace_limit:int -> ?fact_key_limit:int -> t -> string
val write_summary_index : path:string -> t -> unit
(** Write the complete fact-key outcome summary as compact JSONL rows.
    The file is replaced by this local CLI helper; the live runtime does not
    call it. *)
