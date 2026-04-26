(** Meta_cognition_types — types and utilities for room-level meta-cognition.

    Shared type definitions and leaf utility functions used across the
    meta-cognition sub-modules.

    @since God file decomposition — extracted from [meta_cognition.ml]. *)

(** {1 Source evidence} *)

type source =
  { ref_id : string
  ; author : string
  ; text : string
  ; created_at : float
  ; hearth : string option
  ; target_author : string option
  }

type governance_case =
  { id : string
  ; title : string
  ; status : string
  }

(** {1 Rule predicates (callback-bearing)} *)

type belief_rule =
  { id : string
  ; claim : string
  ; support : source -> bool
  ; challenge : source -> bool
  }

type tension_rule =
  { id : string
  ; topic : string
  ; kind : string
  ; matches : source -> bool
  }

type desire_rule =
  { id : string
  ; desired_state : string
  ; desire_type : string
  ; actionability : string
  ; matches : source -> bool
  }

(** {1 Social graph} *)

type social_edge =
  { from_agent : string
  ; to_agent : string
  ; edge_type : string
  ; weight : int
  ; evidence_refs : string list
  ; last_seen_at : float
  }

(** {1 Aggregated summaries} *)

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

(** {1 Salience classification} *)

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

(** {1 Leaf utilities} *)

(** [take n xs]: first [n] elements of [xs], or the whole list when
    [n >= List.length xs]. Returns [[]] for [n <= 0]. *)
val take : int -> 'a list -> 'a list

(** Trim, drop empty, and dedup a list of strings (ASCII compare order). *)
val unique_non_empty : string list -> string list

(** [clamp ~min_v ~max_v v] clips [v] into the closed interval [[min_v, max_v]]. *)
val clamp : min_v:'a -> max_v:'a -> 'a -> 'a

val salience_to_string : salience -> string

(** [preview ?max_len text] collapses newlines to spaces and truncates to
    roughly [max_len] bytes (default 120), appending ["…"] when clipped.
    Uses {!String_util.utf8_safe} so multi-byte boundaries are preserved. *)
val preview : ?max_len:int -> string -> string

(** Case-insensitive substring match. *)
val contains_ci : string -> string -> bool

(** [contains_any_ci haystack needles] is [true] when any of [needles]
    is a case-insensitive substring of [haystack]. *)
val contains_any_ci : string -> string list -> bool
