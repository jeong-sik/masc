(** Cdal_eval -- Phase 0 structural verdict over CDAL proof bundles.

    Consumes {!Agent_sdk.Cdal_proof.t} and produces a deterministic verdict.
    No LLM judge, no golden set, no baseline lock.

    Two dimensions:
    - Evidence presence: did OAS produce expected artifacts?
    - Violation summary: did Mode_enforcer detect runtime violations?

    @since Phase 0 -- CDAL proof tap *)

(** Verdict severity. *)
type severity =
  | Ok
  | Warn of string
  | Fail of string

(** Evidence presence check -- did OAS produce artifacts?
    This is a crash detector, not a quality signal. *)
type evidence_check = {
  has_tool_traces : bool;
  has_raw_evidence : bool;
  has_checkpoint : bool;
  completed_normally : bool;
}

(** Runtime violation summary extracted from proof metadata.
    Mode_enforcer already collects violations at runtime;
    this aggregates what was recorded in the proof bundle. *)
type violation_summary = {
  violation_ref_count : int;
  mode_was_downgraded : bool;
  downgrade_reason : string option;
}

(** Phase 0 eval result. *)
type eval_result = {
  evidence : evidence_check;
  violations : violation_summary;
  overall : severity;
  run_id : string;
  contract_id : string;
  result_status : Agent_sdk.Cdal_proof.result_status;
  evaluated_at : float;
}

(** Evaluate a proof bundle. Pure function, no I/O. *)
val evaluate : Agent_sdk.Cdal_proof.t -> eval_result

(** [is_acceptable r] returns [true] when [r.overall] is [Ok] or [Warn _]. *)
val is_acceptable : eval_result -> bool

(** JSON serialization for JSONL persistence. *)
val to_json : eval_result -> Yojson.Safe.t

(** Severity to short string for logging. *)
val severity_to_string : severity -> string
