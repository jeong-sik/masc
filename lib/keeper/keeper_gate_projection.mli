(** Pure presentation of Gate decisions and durable completion failures. *)
open Keeper_gate_types

val auto_judge_resume_failure_code_to_string : auto_judge_resume_failure_code -> string
val completion_rejection_of_exact_attempt : Keeper_approval_queue_result.exact_attempt_rejection -> auto_judge_completion_rejection
val completion_rejection_operator_detail : auto_judge_completion_rejection -> string
val status_label : Unix.process_status -> string
val authorization_source_to_string : authorization_source -> string
val unavailable_reason_to_string : unavailable_reason -> string
val authorization_subject_id : authorization_source -> string option
val decision_to_yojson : decision -> Yojson.Safe.t
val authorization_metadata : ?producer_metadata:Yojson.Safe.t -> authorization -> Yojson.Safe.t
