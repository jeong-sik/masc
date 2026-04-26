(** Coord-level meta-cognition read model.

    Derives high-signal beliefs, tensions, desires, and discourse edges
    from existing room artifacts without mutating state. *)

type belief_summary =
  { id : string option
  ; claim : string option
  ; status : string option
  ; confidence : float option
  ; support_agent_count : int option
  ; challenge_agent_count : int option
  ; evidence_refs : string list
  ; challenge_refs : string list
  }

type tension_summary =
  { id : string option
  ; topic : string option
  ; kind : string option
  ; severity : string option
  ; recurrence_count : int option
  ; needs_operator : bool
  ; evidence_refs : string list
  }

type desire_summary =
  { id : string option
  ; desired_state : string option
  ; desire_type : string option
  ; actionability : string option
  ; strength : float option
  ; evidence_refs : string list
  }

type summary_input =
  { stagnation_score : float
  ; belief_count : int
  ; contested_belief_count : int
  ; dominant_belief : belief_summary option
  ; top_tension : tension_summary option
  ; top_desire : desire_summary option
  }

type salience =
  | Stable
  | Contested_belief
  | Operator_tension
  | Operator_desire
  | Stagnant_room

type interpretation =
  { primary_salience : salience
  ; secondary_saliences : salience list
  ; reason : string
  ; target_id : string option
  ; evidence_refs : string list
  }

type digest_ref =
  { post_id : string
  ; title : string
  ; created_at : string
  ; updated_at : string option
  ; hearth : string option
  ; digest_key : string
  ; matches_summary : bool
  }

val snapshot_json : ?hearth:string -> limit:int -> Coord.config -> Yojson.Safe.t
val summary_json : ?hearth:string -> Coord.config -> Yojson.Safe.t
val parse_summary : Yojson.Safe.t -> (summary_input, string) result
val interpret : summary_input -> interpretation
val interpretation_to_json : interpretation -> Yojson.Safe.t
val salience_to_string : salience -> string
val summary_signature : summary_input -> string
val digest_hearth : string
val digest_source : string
val post_digest_key : Board.post -> string option
val latest_digest_ref : ?summary:summary_input -> unit -> digest_ref option
val latest_digest_json : ?summary:summary_input -> unit -> Yojson.Safe.t
