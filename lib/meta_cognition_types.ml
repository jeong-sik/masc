(** Meta_cognition_types — Types and utilities for room-level meta-cognition.

    Contains all shared type definitions and leaf utility functions used
    across the meta-cognition sub-modules.

    @since God file decomposition — extracted from meta_cognition.ml *)

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

type social_edge =
  { from_agent : string
  ; to_agent : string
  ; edge_type : string
  ; weight : int
  ; evidence_refs : string list
  ; last_seen_at : float
  }

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

(* ================================================================ *)
(* Leaf utilities                                                    *)
(* ================================================================ *)

let take n xs =
  let rec loop remaining acc = function
    | _ when remaining <= 0 -> List.rev acc
    | [] -> List.rev acc
    | x :: rest -> loop (remaining - 1) (x :: acc) rest
  in
  loop n [] xs
;;

let unique_non_empty values =
  values
  |> List.map String.trim
  |> List.filter (fun value -> value <> "")
  |> List.sort_uniq String.compare
;;

let clamp ~min_v ~max_v value =
  if value < min_v then min_v else if value > max_v then max_v else value
;;

let salience_to_string = function
  | Stable -> "stable"
  | Contested_belief -> "contested_belief"
  | Operator_tension -> "operator_tension"
  | Operator_desire -> "operator_desire"
  | Stagnant_room -> "stagnant_room"
;;

let preview ?(max_len = 120) text =
  let text =
    text
    |> String.split_on_char '\n'
    |> List.map String.trim
    |> List.filter (fun chunk -> chunk <> "")
    |> String.concat " "
  in
  String_util.utf8_safe ~max_bytes:(max 0 (max_len - 1) + 3) ~suffix:"…" text
  |> String_util.to_string
;;

let contains_ci haystack needle =
  String_util.contains_substring
    (String.lowercase_ascii haystack)
    (String.lowercase_ascii needle)
;;

let contains_any_ci haystack needles =
  List.exists (fun needle -> contains_ci haystack needle) needles
;;
