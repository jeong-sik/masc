(** Labeling — CDAL labeling protocol v0 types and metrics.

    Implements Section 2 (core labels), Section 3 (precision definitions),
    and Section 7 (output contract) of the labeling protocol.

    @see docs/design/contract-driven-agent-loop-labeling-protocol.md *)

(** Core label per protocol Section 2. *)
type label =
  | Supported
  | Unsupported
  | Ambiguous
  | Drift

(** A human-labeled verdict. *)
type labeled_verdict = {
  verdict : Cdal_types.contract_verdict;
  label : label;
  labeler : string;
  note : string option;
  labeled_at : string;
}

(** Confusion matrix counts per protocol Section 7. *)
type confusion_summary = {
  supported : int;
  unsupported : int;
  ambiguous : int;
  drift : int;
}

(** Output contract per protocol Section 7. *)
type output_contract = {
  workload_name : string;
  judge_protocol_version : string;
  label_owner : string;
  metric_owner : string;
  confusion : confusion_summary;
  claim_coverage : float;
  precision_strict : float;
  precision_lenient : float;
  drift_note : string;
}

(** {2 String conversions} *)

val label_to_string : label -> string
val label_of_string : string -> (label, string) result

(** {2 Metrics — protocol Section 3} *)

val compute_confusion : labeled_verdict list -> confusion_summary

(** [supported / (supported + unsupported + ambiguous)]. Drift excluded. *)
val compute_precision_strict : confusion_summary -> float

(** [supported / (supported + unsupported)]. Ambiguous and drift excluded. *)
val compute_precision_lenient : confusion_summary -> float

(** [labeled / total]. *)
val compute_claim_coverage : labeled:int -> total:int -> float

(** Build a complete output contract from labeled verdicts. *)
val build_output_contract :
  workload_name:string ->
  judge_protocol_version:string ->
  label_owner:string ->
  metric_owner:string ->
  total_claims:int ->
  drift_note:string ->
  labeled_verdict list ->
  output_contract

(** {2 JSON serialization} *)

val label_to_json : label -> Yojson.Safe.t
val labeled_verdict_to_json : labeled_verdict -> Yojson.Safe.t
val labeled_verdict_of_json : Yojson.Safe.t -> (labeled_verdict, string) result
val confusion_summary_to_json : confusion_summary -> Yojson.Safe.t
val output_contract_to_json : output_contract -> Yojson.Safe.t
