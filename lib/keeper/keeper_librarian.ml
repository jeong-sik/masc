(** Keeper_librarian — LLM-owned current Memory OS selection. *)

open Keeper_memory_os_types

module Canonical_tool = Agent_sdk.Canonical_tool

type input =
  { trace_id : string
  ; generation : int
  ; current_facts : fact list
  ; messages : Agent_sdk.Types.message list
  }

type selection =
  { summary : string
  ; retained_claim_ids : string list
  ; new_claims : fact list
  ; facts : fact list
  ; open_items : string list
  ; constraints : string list
  ; preserved_tool_refs : string list
  }

let wire_field_summary = "summary"
let wire_field_retained_claim_ids = "retained_claim_ids"
let wire_field_new_claims = "new_claims"
let wire_field_open_items = Keeper_memory_os_types.wire_field_open_items
let wire_field_constraints = Keeper_memory_os_types.wire_field_constraints
let wire_field_preserved_tool_refs = Keeper_memory_os_types.wire_field_preserved_tool_refs
let wire_field_claim = Keeper_memory_os_types.wire_field_claim
let wire_field_category = Keeper_memory_os_types.wire_field_category
let wire_field_source_turn = Keeper_memory_os_types.wire_field_source_turn
let wire_field_source_tool_call_id = Keeper_memory_os_types.wire_field_source_tool_call_id
let wire_field_claim_id = Keeper_memory_os_types.wire_field_claim_id
let wire_field_claim_kind = Keeper_memory_os_types.wire_field_claim_kind
let wire_field_valid_for_days = Keeper_memory_os_types.wire_field_valid_for_days
let wire_claim_fields = Keeper_memory_os_types.wire_librarian_claim_fields
let wire_current_fields =
  [ wire_field_summary
  ; wire_field_retained_claim_ids
  ; wire_field_new_claims
  ; wire_field_open_items
  ; wire_field_constraints
  ; wire_field_preserved_tool_refs
  ]

let trim_nonempty s =
  let s = String.trim s in
  if String.equal s "" then None else Some s
;;

let role_to_string = Agent_sdk.Types.role_to_string

let text_of_content block =
  match Canonical_tool.tool_result_of_block block with
  | Some result ->
    Some
      (Printf.sprintf
         "[tool result omitted: id=%s is_error=%b]"
         result.Canonical_tool.call_id
         (Agent_sdk.Types.tool_result_outcome_is_error
            result.Canonical_tool.outcome))
  | None -> (
    match Canonical_tool.tool_call_of_block block with
    | Some call ->
      Some
        (Printf.sprintf
           "[tool use omitted: id=%s name=%s]"
           call.Canonical_tool.call_id
           call.Canonical_tool.name)
    | None -> (
      match block with
      | Agent_sdk.Types.Text s -> trim_nonempty s
      | Agent_sdk.Types.ToolResult _ ->
        invalid_arg
          "keeper_librarian: OAS canonical tool-result projection unavailable"
      | Agent_sdk.Types.ToolUse _ ->
        invalid_arg
          "keeper_librarian: OAS canonical tool-call projection unavailable"
      | Agent_sdk.Types.Thinking _
      | Agent_sdk.Types.ReasoningDetails _
      | Agent_sdk.Types.RedactedThinking _ -> None
      | Agent_sdk.Types.Image _ -> Some "[image omitted]"
      | Agent_sdk.Types.Document _ -> Some "[document omitted]"
      | Agent_sdk.Types.Audio _ -> Some "[audio omitted]"))
;;

let message_to_text ~turn (m : Agent_sdk.Types.message) : string =
  let parts = List.filter_map text_of_content m.content in
  let body = String.concat "\n" parts |> String.trim in
  let header = Printf.sprintf "turn=%d role=%s" turn (role_to_string m.role) in
  if String.equal body ""
  then Printf.sprintf "[%s] (empty)" header
  else Printf.sprintf "[%s] %s" header body
;;

let format_messages_for_prompt messages =
  match messages with
  | [] -> "[no messages]"
  | _ ->
    messages
    |> List.mapi (fun turn message -> message_to_text ~turn message)
    |> String.concat "\n\n---\n\n"
;;

let current_fact_json fact =
  `Assoc
    [ "memory_id", `String (claim_identity fact)
    ; "fact", fact_to_json fact
    ]
;;

let format_current_facts_for_prompt facts =
  `List (List.map current_fact_json facts)
  |> Yojson.Safe.pretty_to_string
;;

let prompt_variables (inp : input) : (string * string) list =
  [ "current_memory", format_current_facts_for_prompt inp.current_facts
  ; ( "conversation_history"
    , format_messages_for_prompt inp.messages )
  ]
;;

let string_field key fields =
  match List.assoc_opt key fields with
  | Some (`String s) -> trim_nonempty s
  | Some (`Assoc _ | `Bool _ | `Float _ | `Int _ | `Intlit _ | `List _ | `Null)
  | None -> None
;;

let int_field key fields =
  match List.assoc_opt key fields with
  | Some (`Int i) -> Some i
  | Some (`Assoc _ | `Bool _ | `Float _ | `Intlit _ | `List _ | `Null | `String _)
  | None -> None
;;

let rec traverse f = function
  | [] -> Some []
  | x :: xs ->
    (match f x, traverse f xs with
     | Some y, Some ys -> Some (y :: ys)
     | (Some _, None) | (None, _) -> None)
;;

let string_list_field key fields =
  match List.assoc_opt key fields with
  | Some (`List items) -> traverse (function `String s -> trim_nonempty s | _ -> None) items
  | Some (`Assoc _ | `Bool _ | `Float _ | `Int _ | `Intlit _ | `Null | `String _)
  | None -> None
;;

let string_list_field_or_empty key fields =
  match List.assoc_opt key fields with
  | None | Some `Null -> Some []
  | Some _ -> string_list_field key fields
;;

let field_allowed ~allowed field =
  List.exists (String.equal field) allowed
;;

let first_unexpected_field ~allowed fields =
  List.find_map
    (fun (field, _) ->
       if field_allowed ~allowed field then None else Some field)
    fields
;;

type parse_error =
  | Empty_output
  | Invalid_json of string
  | Json_string_invalid_json of string
  | Top_level_not_object
  | Unexpected_field of string
  | Missing_required_fields
  | Claim_schema_mismatch
  | Unknown_retained_claim_id of string
  | Duplicate_retained_claim_id of string
  | Duplicate_selected_claim_id of string

let parse_error_to_string = function
  | Empty_output -> "empty_output"
  | Invalid_json msg -> "invalid_json: " ^ msg
  | Json_string_invalid_json msg -> "json_string_invalid_json: " ^ msg
  | Top_level_not_object -> "top_level_not_object"
  | Unexpected_field field -> "unexpected_field: " ^ field
  | Missing_required_fields -> "missing_required_fields"
  | Claim_schema_mismatch -> "claim_schema_mismatch"
  | Unknown_retained_claim_id identity ->
    "unknown_retained_claim_id: " ^ identity
  | Duplicate_retained_claim_id identity ->
    "duplicate_retained_claim_id: " ^ identity
  | Duplicate_selected_claim_id identity ->
    "duplicate_selected_claim_id: " ^ identity
;;

let json_of_output raw =
  let raw = String.trim raw in
  if String.equal raw ""
  then Error Empty_output
  else
    let try_parse ~on_error s =
      try Ok (Yojson.Safe.from_string (String.trim s)) with
      | Yojson.Json_error msg -> Error (on_error msg)
    in
    match try_parse raw ~on_error:(fun msg -> Invalid_json msg) with
    | Error _ as error -> error
    | Ok (`String inner) ->
      if String.equal (String.trim inner) ""
      then Error (Json_string_invalid_json "empty JSON string")
      else try_parse inner ~on_error:(fun msg -> Json_string_invalid_json msg)
    | Ok json -> Ok json
;;

let claim_source ~trace_id turn tool_call_id =
  { trace_id; turn; tool_call_id }
;;

let claim_kind_field fields =
  match List.assoc_opt wire_field_claim_kind fields with
  | None | Some `Null -> Some None
  | Some (`String raw) -> Option.map (fun kind -> Some kind) (claim_kind_of_string raw)
  | Some _ -> None
;;

let optional_string_field_strict key fields =
  match List.assoc_opt key fields with
  | None | Some `Null -> Some None
  | Some (`String value) -> Some (Some value)
  | Some _ -> None
;;

let claim_id_field fields =
  match optional_string_field_strict wire_field_claim_id fields with
  | Some (Some id) when String.equal (String.trim id) "" -> None
  | value -> value
;;

(* Producer-declared lifetime in whole days, same contract as the explicit
   keeper_memory_write surface (RFC-0351 S2). Absent/null = durable. A
   present value outside [1, max_valid_for_days] or of the wrong JSON type
   rejects the claim (strict, like every other field here): a malformed
   lifetime silently stored as "forever" is exactly the ephemeral-immortality
   drift this field closes. *)
let valid_for_days_field fields =
  match List.assoc_opt wire_field_valid_for_days fields with
  | None | Some `Null -> Some None
  | Some (`Int days)
    when days >= 1 && days <= Keeper_memory_os_types.max_valid_for_days ->
    Some (Some days)
  | Some _ -> None
;;

let fact_of_json ~trace_id ~now (json : Yojson.Safe.t) : fact option =
  match json with
  | `Assoc fields ->
    (match
       string_field wire_field_claim fields
       , (match List.assoc_opt wire_field_category fields with
          | Some (`String raw) -> category_of_string raw
          | Some _ | None -> None)
       , int_field wire_field_source_turn fields
       , claim_kind_field fields
       , claim_id_field fields
       , optional_string_field_strict wire_field_source_tool_call_id fields
       , valid_for_days_field fields
     with
     | ( Some claim
       , Some category
       , Some turn
       , Some claim_kind
       , Some claim_id
       , Some tool_call_id
       , Some valid_for_days )
       when turn >= 0 ->
      Some
        { claim
        ; category
        ; claim_kind
         ; source = claim_source ~trace_id turn tool_call_id
         ; first_seen = now
         ; valid_until =
             (* RFC-0351 S2: the extracting model's own lifetime judgment for
                the claim; absent = durable. Closes the librarian half of the
                "ephemeral is kept briefly and forgotten" prompt promise —
                the read side (fact_is_current + expiry GC) has been waiting
                on a producer since #25519. *)
             Option.map
               (Keeper_memory_os_types.valid_until_of_days ~now)
               valid_for_days
         ; last_verified_at = None (* RFC-0285 §3.3 / RFC-0259 P7: re-extraction must not advance last_verified_at *)
         ; schema_version
         ; claim_id
         }
     | (Some _, Some _, Some _, _, _, _, _)
     | (Some _, Some _, None, _, _, _, _)
     | (Some _, None, _, _, _, _, _)
     | (None, _, _, _, _, _, _) -> None)
  | `Bool _ | `Float _ | `Int _ | `Intlit _ | `List _ | `Null | `String _ -> None
;;

let unexpected_claim_field = function
  | `Assoc fields -> first_unexpected_field ~allowed:wire_claim_fields fields
  | `Bool _ | `Float _ | `Int _ | `Intlit _ | `List _ | `Null | `String _ -> None
;;

module String_map = Map.Make (String)
module String_set = Set.Make (String)

let current_facts_by_id facts =
  List.fold_left
    (fun by_id fact ->
       String_map.add (claim_identity fact) fact by_id)
    String_map.empty
    facts
;;

let materialize_facts ~current_facts ~retained_claim_ids ~new_claims =
  let open Result.Syntax in
  let current_by_id = current_facts_by_id current_facts in
  let rec retain seen retained_rev = function
    | [] -> Ok (List.rev retained_rev, seen)
    | identity :: rest ->
      if String_set.mem identity seen
      then Error (Duplicate_retained_claim_id identity)
      else
        (match String_map.find_opt identity current_by_id with
         | None -> Error (Unknown_retained_claim_id identity)
         | Some fact ->
           retain
             (String_set.add identity seen)
             (fact :: retained_rev)
             rest)
  in
  let* retained, selected_ids =
    retain String_set.empty [] retained_claim_ids
  in
  let rec append_new selected_ids new_rev = function
    | [] -> Ok (retained @ List.rev new_rev)
    | fact :: rest ->
      let identity = claim_identity fact in
      if String_set.mem identity selected_ids
      then Error (Duplicate_selected_claim_id identity)
      else
        append_new
          (String_set.add identity selected_ids)
          (fact :: new_rev)
          rest
  in
  append_new selected_ids [] new_claims
;;

let selection_of_json_result ?now (inp : input) (json : Yojson.Safe.t) :
  (selection, parse_error) result
  =
  let now =
    match now with
    | Some now -> now
    | None ->
      (* NDT-OK: extraction timestamps are provenance/retention metadata only. *)
      Unix.gettimeofday ()
  in
  match json with
  | `Assoc fields ->
    (match first_unexpected_field ~allowed:wire_current_fields fields with
     | Some field -> Error (Unexpected_field field)
     | None ->
       (match
          string_field wire_field_summary fields
          , string_list_field wire_field_retained_claim_ids fields
          , List.assoc_opt wire_field_new_claims fields
          , string_list_field_or_empty wire_field_open_items fields
          , string_list_field_or_empty wire_field_constraints fields
          , string_list_field_or_empty wire_field_preserved_tool_refs fields
        with
        | ( Some summary
          , Some retained_claim_ids
          , Some (`List claim_items)
          , Some open_items
          , Some constraints
          , Some preserved_tool_refs ) ->
          (match List.find_map unexpected_claim_field claim_items with
           | Some field -> Error (Unexpected_field field)
           | None ->
             (match traverse (fact_of_json ~trace_id:inp.trace_id ~now) claim_items with
              | Some new_claims ->
                (match
                   materialize_facts
                     ~current_facts:inp.current_facts
                     ~retained_claim_ids
                     ~new_claims
                 with
                 | Ok facts ->
                   Ok
                     { summary
                     ; retained_claim_ids
                     ; new_claims
                     ; facts
                     ; open_items
                     ; constraints
                     ; preserved_tool_refs
                     }
                 | Error _ as error -> error)
              | None -> Error Claim_schema_mismatch))
        | _ -> Error Missing_required_fields))
  | `Bool _ | `Float _ | `Int _ | `Intlit _ | `List _ | `Null | `String _ ->
    Error Top_level_not_object
;;

let selection_of_output_result ?now (inp : input) (raw : string) :
  (selection, parse_error) result
  =
  match json_of_output raw with
  | Error _ as error -> error
  | Ok json -> selection_of_json_result ?now inp json
;;
