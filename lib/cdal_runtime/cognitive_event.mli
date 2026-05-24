(* Cognitive_event — CDAL runtime cognitive event types. *)

type t =
  | Gravity_ranked of
      { ranked_count : int
      ; query_terms : int
      }
  | Intent_predicted of
      { intent_label : string
      ; confidence : float
      }
  | Mode_transitioned of
      { from_mode : string
      ; to_mode : string
      }
  | Disclosure_level of { level : int }
[@@deriving yojson, show]

val name : t -> string

val is_well_formed : t -> (unit, string) result
