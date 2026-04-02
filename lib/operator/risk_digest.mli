(** Risk_digest — Structural risk signals for supervisor digest.

    Computes 4 risk fields from session state using deterministic
    structural signals only (no LLM judge). Per RFC #3475 PoC-2:
    "1st PoC gates close only on deterministic structural signal." *)

type evidence_gap = {
  required_count : int;
  present_count : int;
  missing : string list;
}
(** Compares delivery_contract.required_artifacts against evidence_refs. *)

type drift_signal =
  | Cascade_length_change of { original : int; current : int }
(** Structural drift signals from session metadata. *)

type unsafe_edit_signal =
  | Destructive_tool of string
  | Zero_repair_budget
  | High_risk_class
(** Structural signals indicating unsafe edit potential. *)

type t = {
  evidence_gap : evidence_gap;
  drift_risk : drift_signal list;
  unsafe_edit_risk : unsafe_edit_signal list;
  ambiguity : string option;
}

val compute :
  session:Team_session_types.session ->
  worker_cards:Operator_digest_types.worker_card list ->
  t
(** Compute risk digest from session state and worker cards. *)

val to_yojson : t -> Yojson.Safe.t
(** Serialize risk digest to JSON. *)
