(** Operator_review_state — Persisted log of operator review
    decisions.

    Records whether an operator has reviewed a particular target
    (task, agent, etc.) and what action they recommended. Used by
    {!Operator_digest} to surface recent operator decisions. *)

(** {1 Types} *)

type review_decision_value = Review_decision_value of string


type review_decision = {
  item_id : string;
  fingerprint : string;
  decision : review_decision_value;
  actor : string;
  reason : string;
  at : string;
  target_type : string;
  target_id : string option;
  recommended_action_type : string option;
}

(** {1 Path} *)


(** {1 Serialisation} *)




(** {1 I/O} *)

(** Read all stored review decisions (raw order, no filtering). *)

(** {1 Queries} *)

(** [recent_review_decisions ?limit ?target_type ?target_id config]
    returns decisions matching the optional filters, most recent
    first. Default [limit] is ["no cap"]. *)

(** JSON array of {!recent_review_decisions}. *)
val recent_review_decisions_json :
  ?limit:int ->
  ?target_type:string ->
  ?target_id:string ->
  Workspace_utils.config ->
  Yojson.Safe.t
