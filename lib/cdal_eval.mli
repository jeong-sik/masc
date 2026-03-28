(** Cdal_eval — Content-based CDAL proof evaluation.

    Reads actual proof artifacts (violations, token usage, tool traces)
    and derives verdict + recommendation from their content.
    Recommendation is computed via constraint algebra (inverse of
    [Mode_enforcer.check_violation]), not hardcoded string mapping.

    @since CDAL eval content-based redesign *)

(** Verdict severity. *)
type severity =
  | Ok
  | Warn of string
  | Fail of string

(** Evidence actually read from proof artifacts. *)
type evidence_content = {
  violations : Violation_record.t list;
  token_usage : Token_usage_record.t list;
  tool_trace_count : int;
  completed_normally : bool;
}

(** Structured recommendation derived from constraint algebra.
    [minimum_required] is computed as [max(minimum_required_mode v)]
    across all violations. [gap] is the ordinal distance from
    [current_mode] to [minimum_required]. *)
type mode_recommendation = {
  current_mode : Agent_sdk.Execution_mode.t;
  minimum_required : Agent_sdk.Execution_mode.t;
  gap : int;
  offending_tools : string list;
  violation_kinds : Violation_record.violation_kind list;
}

(** Eval result with full evidence content. *)
type eval_result = {
  evidence : evidence_content;
  overall : severity;
  recommendation : mode_recommendation option;
  run_id : string;
  contract_id : string;
  result_status : Agent_sdk.Cdal_proof.result_status;
  evaluated_at : float;
}

(** Evaluate a proof bundle by reading actual artifacts from the proof store.
    Gracefully degrades if artifact files are missing. *)
val evaluate :
  store:Agent_sdk.Proof_store.config ->
  Agent_sdk.Cdal_proof.t ->
  eval_result

(** Pure evaluation from pre-loaded content (for testing without I/O). *)
val evaluate_content :
  violations:Violation_record.t list ->
  token_usage:Token_usage_record.t list ->
  trace_count:int ->
  Agent_sdk.Cdal_proof.t ->
  eval_result

val is_acceptable : eval_result -> bool
val to_json : eval_result -> Yojson.Safe.t
val severity_to_string : severity -> string

(** Persist eval result to date-partitioned JSONL store. *)
val persist : eval_result -> unit
val reset_store_for_testing : unit -> unit
val set_store_for_testing : base_dir:string -> unit
