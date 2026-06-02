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

let json_int_opt = function
  | `Int value -> Some value
  | `Intlit raw -> (
      int_of_string_opt (raw))
  | _ -> None

let json_float_opt = function
  | `Float value -> Some value
  | `Int value -> Some (float_of_int value)
  | `Intlit raw -> float_of_string_opt raw
  | _ -> None

let json_bool_opt = function
  | `Bool value -> Some value
  | _ -> None

let json_string_list_opt = function
  | `List items ->
      Some (items |> List.filter_map json_string_opt |> unique_non_empty)
  | `Null -> Some []
  | _ -> None

(* ================================================================ *)
(* Summary record parsers                                           *)
(* ================================================================ *)

let parse_belief_summary = function
  | `Assoc _ as json ->
      Ok
        {
          id = Json_util.assoc_member_opt "id" json |> Option.value ~default:`Null |> json_string_opt;
          claim = Json_util.assoc_member_opt "claim" json |> Option.value ~default:`Null |> json_string_opt;
          status = Json_util.assoc_member_opt "status" json |> Option.value ~default:`Null |> json_string_opt;
          confidence = Json_util.assoc_member_opt "confidence" json |> Option.value ~default:`Null |> json_float_opt;
          support_agent_count =
            Json_util.assoc_member_opt "support_agent_count" json |> Option.value ~default:`Null |> json_int_opt;
          challenge_agent_count =
            Json_util.assoc_member_opt "challenge_agent_count" json |> Option.value ~default:`Null |> json_int_opt;
          evidence_refs =
            Json_util.assoc_member_opt "evidence_refs" json |> Option.value ~default:`Null
            |> json_string_list_opt |> Option.value ~default:[];
          challenge_refs =
            Json_util.assoc_member_opt "challenge_refs" json |> Option.value ~default:`Null
            |> json_string_list_opt |> Option.value ~default:[];
        }
  | `Null -> Ok { id = None; claim = None; status = None; confidence = None;
                  support_agent_count = None; challenge_agent_count = None;
                  evidence_refs = []; challenge_refs = [] }
  | other ->
      Error
        (Printf.sprintf "dominant_belief must be an object, got %s: %s"
           (Json_util.kind_name other) (Json_util.excerpt other))

let parse_tension_summary = function
  | `Assoc _ as json ->
      Ok
        {
          id = Json_util.assoc_member_opt "id" json |> Option.value ~default:`Null |> json_string_opt;
          topic = Json_util.assoc_member_opt "topic" json |> Option.value ~default:`Null |> json_string_opt;
          kind = Json_util.assoc_member_opt "kind" json |> Option.value ~default:`Null |> json_string_opt;
          severity = Json_util.assoc_member_opt "severity" json |> Option.value ~default:`Null |> json_string_opt;
          recurrence_count =
            Json_util.assoc_member_opt "recurrence_count" json |> Option.value ~default:`Null |> json_int_opt;
          needs_operator =
            Option.value ~default:false (Json_util.get_bool json "needs_operator");
          evidence_refs =
            Json_util.assoc_member_opt "evidence_refs" json |> Option.value ~default:`Null
            |> json_string_list_opt |> Option.value ~default:[];
        }
  | `Null ->
      Ok
        {
          id = None;
          topic = None;
          kind = None;
          severity = None;
          recurrence_count = None;
          needs_operator = false;
          evidence_refs = [];
        }
  | other ->
      Error
        (Printf.sprintf "top_tension must be an object, got %s: %s"
           (Json_util.kind_name other) (Json_util.excerpt other))

let parse_desire_summary = function
  | `Assoc _ as json ->
      Ok
        {
          id = Json_util.assoc_member_opt "id" json |> Option.value ~default:`Null |> json_string_opt;
          desired_state = Json_util.assoc_member_opt "desired_state" json |> Option.value ~default:`Null |> json_string_opt;
          desire_type = Json_util.assoc_member_opt "type" json |> Option.value ~default:`Null |> json_string_opt;
          actionability = Json_util.assoc_member_opt "actionability" json |> Option.value ~default:`Null |> json_string_opt;
          strength = Json_util.assoc_member_opt "strength" json |> Option.value ~default:`Null |> json_float_opt;
          evidence_refs =
            Json_util.assoc_member_opt "evidence_refs" json |> Option.value ~default:`Null
            |> json_string_list_opt |> Option.value ~default:[];
        }
  | `Null ->
      Ok
        {
          id = None;
          desired_state = None;
          desire_type = None;
          actionability = None;
          strength = None;
          evidence_refs = [];
        }
  | other ->
      Error
        (Printf.sprintf "top_desire must be an object, got %s: %s"
           (Json_util.kind_name other) (Json_util.excerpt other))

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

let parse_summary json =
  let stagnation_score =
    Option.value ~default:0.0 (Json_util.get_float json "stagnation_score")
  in
  (
      match Json_util.get_int json "belief_count",
            Json_util.get_int json "contested_belief_count",
            parse_optional_summary parse_belief_summary (Option.value ~default:`Null (Json_util.assoc_member_opt "dominant_belief" json)),
            parse_optional_summary parse_tension_summary (Option.value ~default:`Null (Json_util.assoc_member_opt "top_tension" json)),
            parse_optional_summary parse_desire_summary (Option.value ~default:`Null (Json_util.assoc_member_opt "top_desire" json))
      with
      | Some belief_count, Some contested_belief_count,
        Ok dominant_belief, Ok top_tension, Ok top_desire ->
          Ok
            {
              stagnation_score;
              belief_count;
              contested_belief_count;
              dominant_belief;
              top_tension;
              top_desire;
            }
      | None, _, _, _, _ -> Error "summary.belief_count missing or invalid"
      | _, None, _, _, _ -> Error "summary.contested_belief_count missing or invalid"
      | _, _, Error err, _, _ -> Error err
      | _, _, _, Error err, _ -> Error err
      | _, _, _, _, Error err -> Error err)
