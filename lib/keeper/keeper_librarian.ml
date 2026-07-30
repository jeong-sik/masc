(** Keeper_librarian — structured claim extraction for the Memory OS. *)

open Keeper_memory_os_types

module Canonical_tool = Agent_sdk.Canonical_tool

type input =
  { trace_id : string
  ; messages : Agent_sdk.Types.message list
  }

let wire_field_episode_summary = Keeper_memory_os_types.wire_field_episode_summary
let wire_field_claims = Keeper_memory_os_types.wire_field_claims
let wire_field_claim = Keeper_memory_os_types.wire_field_claim
let wire_field_category = Keeper_memory_os_types.wire_field_category
let wire_field_source_turn = Keeper_memory_os_types.wire_field_source_turn
let wire_field_source_tool_call_id = Keeper_memory_os_types.wire_field_source_tool_call_id
let wire_field_claim_id = Keeper_memory_os_types.wire_field_claim_id
let wire_episode_fields = Keeper_memory_os_types.wire_librarian_episode_fields
let wire_claim_fields = Keeper_memory_os_types.wire_librarian_claim_fields

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

let prompt_variables (inp : input) : (string * string) list =
  [ ( "conversation_history"
    , inp.messages |> format_messages_for_prompt )
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

let field_allowed ~allowed field =
  List.exists (String.equal field) allowed
;;

let first_unexpected_field ~allowed fields =
  let rec loop seen = function
    | [] -> None
    | (field, _) :: rest ->
      if List.mem field seen || not (field_allowed ~allowed field)
      then Some field
      else loop (field :: seen) rest
  in
  loop [] fields
;;

type parse_error =
  | Top_level_not_object
  | Unexpected_field of string
  | Missing_required_fields
  | Claim_schema_mismatch

let parse_error_to_string = function
  | Top_level_not_object -> "top_level_not_object"
  | Unexpected_field field -> "unexpected_field: " ^ field
  | Missing_required_fields -> "missing_required_fields"
  | Claim_schema_mismatch -> "claim_schema_mismatch"
;;

let claim_source ~trace_id turn tool_call_id =
  { trace_id; turn; tool_call_id }
;;

let message_has_tool_call_id (message : Agent_sdk.Types.message) tool_call_id =
  let message_level_match =
    match message.tool_call_id with
    | Some id -> String.equal id tool_call_id
    | None -> false
  in
  message_level_match
  || List.exists
       (fun block ->
          match Canonical_tool.tool_call_of_block block with
          | Some call -> String.equal call.Canonical_tool.call_id tool_call_id
          | None ->
            (match Canonical_tool.tool_result_of_block block with
             | Some result ->
               String.equal result.Canonical_tool.call_id tool_call_id
             | None -> false))
       message.content
;;

let source_is_in_input ~messages ~turn ~tool_call_id =
  match List.nth_opt messages turn with
  | None -> false
  | Some _ when Option.is_none tool_call_id -> true
  | Some message ->
    (match tool_call_id with
     | Some id -> message_has_tool_call_id message id
     | None -> true)
;;

let required_nullable_string_field key fields =
  match List.assoc_opt key fields with
  | None -> None
  | Some `Null -> Some None
  | Some (`String value) -> Some (Some value)
  | Some _ -> None
;;

let claim_id_field fields =
  match required_nullable_string_field wire_field_claim_id fields with
  | Some (Some id) when String.equal (String.trim id) "" -> None
  | value -> value
;;

let fact_of_json ~trace_id ~messages ~now (json : Yojson.Safe.t) : fact option =
  match json with
  | `Assoc fields ->
    (match
       string_field wire_field_claim fields
       , (match List.assoc_opt wire_field_category fields with
          | Some (`String raw) -> category_of_string raw
          | Some _ | None -> None)
       , int_field wire_field_source_turn fields
       , claim_id_field fields
       , required_nullable_string_field wire_field_source_tool_call_id fields
     with
     | Some claim, Some category, Some turn, Some claim_id, Some tool_call_id
       when
         turn >= 0
         && source_is_in_input ~messages ~turn ~tool_call_id ->
      Some
        { claim
        ; category
        ; source = claim_source ~trace_id turn tool_call_id
        ; first_seen = now
        ; last_verified_at = None (* RFC-0285 §3.3 / RFC-0259 P7: re-extraction must not advance last_verified_at *)
        ; claim_id
        }
     | (Some _, Some _, Some _, _, _)
     | (Some _, Some _, None, _, _)
     | (Some _, None, _, _, _)
     | (None, _, _, _, _) -> None)
  | `Bool _ | `Float _ | `Int _ | `Intlit _ | `List _ | `Null | `String _ -> None
;;

let unexpected_claim_field = function
  | `Assoc fields -> first_unexpected_field ~allowed:wire_claim_fields fields
  | `Bool _ | `Float _ | `Int _ | `Intlit _ | `List _ | `Null | `String _ -> None
;;

let claim_identities_are_unique claims =
  let rec loop seen = function
    | [] -> true
    | claim :: rest ->
      let identity = Keeper_memory_os_types.claim_identity claim in
      if Set_util.StringSet.mem identity seen
      then false
      else loop (Set_util.StringSet.add identity seen) rest
  in
  loop Set_util.StringSet.empty claims
;;

let episode_of_json_result ?now ~generation (inp : input) (json : Yojson.Safe.t) :
  (episode, parse_error) result
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
    (match first_unexpected_field ~allowed:wire_episode_fields fields with
     | Some field -> Error (Unexpected_field field)
     | None ->
       (match string_field wire_field_episode_summary fields, List.assoc_opt wire_field_claims fields with
        | Some episode_summary, Some (`List claim_items) ->
          (match List.find_map unexpected_claim_field claim_items with
           | Some field -> Error (Unexpected_field field)
           | None ->
             (match
                traverse
                  (fact_of_json
                     ~trace_id:inp.trace_id
                     ~messages:inp.messages
                     ~now)
                  claim_items
              with
              | Some claims when claim_identities_are_unique claims ->
                Ok
                  { trace_id = inp.trace_id
                  ; generation
                  ; episode_summary
                  ; claims
                  ; source_turn_range =
                      Keeper_memory_os_types.source_turn_range_of_facts claims
                  ; created_at = now
                  ; terminal_marker = None
                  }
              | Some _ | None -> Error Claim_schema_mismatch))
        | _ -> Error Missing_required_fields))
  | `Bool _ | `Float _ | `Int _ | `Intlit _ | `List _ | `Null | `String _ ->
    Error Top_level_not_object
;;
