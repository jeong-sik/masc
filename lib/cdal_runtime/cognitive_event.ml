(* Cognitive_event — implementation.

   See cognitive_event.mli for the interface contract. *)

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

let name = function
  | Gravity_ranked _ -> "gravity_ranked"
  | Intent_predicted _ -> "intent_predicted"
  | Mode_transitioned _ -> "mode_transitioned"
  | Disclosure_level _ -> "disclosure_level"
;;

let is_well_formed = function
  | Gravity_ranked { ranked_count; query_terms } ->
    if ranked_count < 0
    then Error "Gravity_ranked.ranked_count must be non-negative"
    else if query_terms < 0
    then Error "Gravity_ranked.query_terms must be non-negative"
    else Ok ()
  | Intent_predicted { intent_label; confidence } ->
    if String.length intent_label = 0
    then Error "Intent_predicted.intent_label must be non-empty"
    else if (not (Float.is_finite confidence)) || confidence < 0.0 || confidence > 1.0
    then Error "Intent_predicted.confidence must be a finite float in [0.0, 1.0]"
    else Ok ()
  | Mode_transitioned { from_mode; to_mode } ->
    if String.length from_mode = 0
    then Error "Mode_transitioned.from_mode must be non-empty"
    else if String.length to_mode = 0
    then Error "Mode_transitioned.to_mode must be non-empty"
    else if String.equal from_mode to_mode
    then Error "Mode_transitioned.from_mode and to_mode must differ"
    else Ok ()
  | Disclosure_level { level } ->
    if level < 0 || level > 3
    then Error "Disclosure_level.level must be in [0, 3]"
    else Ok ()
;;
