(** Keeper_learning — Decision recording and replay for keeper deliberation. *)

(** A single deliberation decision record. *)
type decision_record = {
  id : string;
  keeper_name : string;
  timestamp : float;
  triggers : string list;
  observation_json : Yojson.Safe.t;
  prompt_hash : string;
  action_chosen : string;
  action_json : Yojson.Safe.t;
  reasoning : string;
  confidence : float;
  cost_usd : float;
  outcome : string;
  outcome_detail : string;
  feedback_score : float option;
  feedback_comment : string;
}

val generate_decision_id : unit -> string
(** Generate a unique decision ID with "dec-" prefix, timestamp, and random suffix. *)

val prompt_hash : string -> string
(** Return the first 8 hex chars of the MD5 digest of the given prompt string. *)

val decision_record_to_json : decision_record -> Yojson.Safe.t
(** Serialize a decision record to JSON. *)

val decision_record_of_json : Yojson.Safe.t -> decision_record option
(** Deserialize a decision record from JSON. Returns None on parse failure. *)

val decisions_path : Room.config -> string -> string
(** [decisions_path config keeper_name] returns the JSONL file path for the keeper's decisions. *)

val record_decision : Room.config -> decision_record -> unit
(** Append a decision record to the keeper's JSONL decisions file. *)

val read_decisions :
  Room.config -> keeper_name:string -> limit:int -> decision_record list
(** Read recent decisions for a keeper, newest first, up to [limit] entries.
    A non-positive limit returns all records. *)

val record_outcome :
  Room.config ->
  keeper_name:string ->
  decision_id:string ->
  outcome:string ->
  detail:string ->
  unit
(** Update the outcome fields for an existing decision record. *)

val record_feedback :
  Room.config ->
  keeper_name:string ->
  decision_id:string ->
  score:float ->
  comment:string ->
  unit
(** Record human feedback (score in [-1.0, 1.0] range, comment) for a decision. *)
