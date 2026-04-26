(** Meta_cognition_parse — JSON parsing for summary data.

    Parses the compact summary JSON produced by [summary_json] back into
    typed OCaml records for programmatic interpretation.

    @since God file decomposition — extracted from meta_cognition.ml *)

open Meta_cognition_types

(* ================================================================ *)
(* JSON extraction helpers                                          *)
(* ================================================================ *)

let json_string_opt = function
  | `String value ->
    let trimmed = String.trim value in
    if trimmed = "" then None else Some trimmed
  | _ -> None
;;

let json_int_opt = function
  | `Int value -> Some value
  | `Intlit raw -> int_of_string_opt raw
  | _ -> None
;;

let json_float_opt = function
  | `Float value -> Some value
  | `Int value -> Some (float_of_int value)
  | `Intlit raw -> float_of_string_opt raw
  | _ -> None
;;

let json_bool_opt = function
  | `Bool value -> Some value
  | _ -> None
;;

let json_string_list_opt = function
  | `List items -> Some (items |> List.filter_map json_string_opt |> unique_non_empty)
  | `Null -> Some []
  | _ -> None
;;

(* ================================================================ *)
(* Summary record parsers                                           *)
(* ================================================================ *)

let parse_belief_summary = function
  | `Assoc _ as json ->
    Ok
      { id = Yojson.Safe.Util.member "id" json |> json_string_opt
      ; claim = Yojson.Safe.Util.member "claim" json |> json_string_opt
      ; status = Yojson.Safe.Util.member "status" json |> json_string_opt
      ; confidence = Yojson.Safe.Util.member "confidence" json |> json_float_opt
      ; support_agent_count =
          Yojson.Safe.Util.member "support_agent_count" json |> json_int_opt
      ; challenge_agent_count =
          Yojson.Safe.Util.member "challenge_agent_count" json |> json_int_opt
      ; evidence_refs =
          Yojson.Safe.Util.member "evidence_refs" json
          |> json_string_list_opt
          |> Option.value ~default:[]
      ; challenge_refs =
          Yojson.Safe.Util.member "challenge_refs" json
          |> json_string_list_opt
          |> Option.value ~default:[]
      }
  | `Null ->
    Ok
      { id = None
      ; claim = None
      ; status = None
      ; confidence = None
      ; support_agent_count = None
      ; challenge_agent_count = None
      ; evidence_refs = []
      ; challenge_refs = []
      }
  | _ -> Error "dominant_belief must be an object"
;;

let parse_tension_summary = function
  | `Assoc _ as json ->
    Ok
      { id = Yojson.Safe.Util.member "id" json |> json_string_opt
      ; topic = Yojson.Safe.Util.member "topic" json |> json_string_opt
      ; kind = Yojson.Safe.Util.member "kind" json |> json_string_opt
      ; severity = Yojson.Safe.Util.member "severity" json |> json_string_opt
      ; recurrence_count = Yojson.Safe.Util.member "recurrence_count" json |> json_int_opt
      ; needs_operator =
          Yojson.Safe.Util.member "needs_operator" json
          |> json_bool_opt
          |> Option.value ~default:false
      ; evidence_refs =
          Yojson.Safe.Util.member "evidence_refs" json
          |> json_string_list_opt
          |> Option.value ~default:[]
      }
  | `Null ->
    Ok
      { id = None
      ; topic = None
      ; kind = None
      ; severity = None
      ; recurrence_count = None
      ; needs_operator = false
      ; evidence_refs = []
      }
  | _ -> Error "top_tension must be an object"
;;

let parse_desire_summary = function
  | `Assoc _ as json ->
    Ok
      { id = Yojson.Safe.Util.member "id" json |> json_string_opt
      ; desired_state = Yojson.Safe.Util.member "desired_state" json |> json_string_opt
      ; desire_type = Yojson.Safe.Util.member "type" json |> json_string_opt
      ; actionability = Yojson.Safe.Util.member "actionability" json |> json_string_opt
      ; strength = Yojson.Safe.Util.member "strength" json |> json_float_opt
      ; evidence_refs =
          Yojson.Safe.Util.member "evidence_refs" json
          |> json_string_list_opt
          |> Option.value ~default:[]
      }
  | `Null ->
    Ok
      { id = None
      ; desired_state = None
      ; desire_type = None
      ; actionability = None
      ; strength = None
      ; evidence_refs = []
      }
  | _ -> Error "top_desire must be an object"
;;

let parse_optional_summary parse value =
  match value with
  | `Null -> Ok None
  | other ->
    Result.map
      (fun parsed ->
         match other with
         | `Assoc _ -> Some parsed
         | _ -> None)
      (parse other)
;;

let parse_summary json =
  let open Yojson.Safe.Util in
  let stagnation_score =
    Option.value ~default:0.0 (json_float_opt (member "stagnation_score" json))
  in
  match
    ( json_int_opt (member "belief_count" json)
    , json_int_opt (member "contested_belief_count" json)
    , parse_optional_summary parse_belief_summary (member "dominant_belief" json)
    , parse_optional_summary parse_tension_summary (member "top_tension" json)
    , parse_optional_summary parse_desire_summary (member "top_desire" json) )
  with
  | ( Some belief_count
    , Some contested_belief_count
    , Ok dominant_belief
    , Ok top_tension
    , Ok top_desire ) ->
    Ok
      { stagnation_score
      ; belief_count
      ; contested_belief_count
      ; dominant_belief
      ; top_tension
      ; top_desire
      }
  | None, _, _, _, _ -> Error "summary.belief_count missing or invalid"
  | _, None, _, _, _ -> Error "summary.contested_belief_count missing or invalid"
  | _, _, Error err, _, _ -> Error err
  | _, _, _, Error err, _ -> Error err
  | _, _, _, _, Error err -> Error err
;;
