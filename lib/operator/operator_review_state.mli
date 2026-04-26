(** Operator_review_state — Persisted log of operator review
    decisions.

    Records whether an operator has reviewed a particular target
    (task, agent, etc.) and what action they recommended. Used by
    {!Operator_digest} to surface recent operator decisions. *)

(** {1 Types} *)

type review_decision =
  { item_id : string
  ; fingerprint : string
  ; decision : string
  ; actor : string
  ; reason : string
  ; at : string
  ; target_type : string
  ; target_id : string option
  ; recommended_action_type : string option
  }

(** {1 Path} *)

val review_state_path : Coord_utils.config -> string

(** {1 Serialisation} *)

val review_decision_to_yojson : review_decision -> Yojson.Safe.t
val review_decision_of_yojson : Yojson.Safe.t -> (review_decision, string) result
val compare_review_decision : review_decision -> review_decision -> int

(** {1 I/O} *)

(** Read all stored review decisions (raw order, no filtering). *)
val read_review_decisions : Coord_utils.config -> review_decision list

(** Atomically rewrite the full decision log. *)
val write_review_decisions : Coord_utils.config -> review_decision list -> unit

(** {1 Queries} *)

(** [recent_review_decisions ?limit ?target_type ?target_id config]
    returns decisions matching the optional filters, most recent
    first. Default [limit] is ["no cap"]. *)
val recent_review_decisions
  :  ?limit:int
  -> ?target_type:string
  -> ?target_id:string
  -> Coord_utils.config
  -> review_decision list

(** JSON array of {!recent_review_decisions}. *)
val recent_review_decisions_json
  :  ?limit:int
  -> ?target_type:string
  -> ?target_id:string
  -> Coord_utils.config
  -> Yojson.Safe.t
