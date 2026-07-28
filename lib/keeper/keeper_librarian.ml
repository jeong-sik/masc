(** Keeper_librarian — store-aware recognition extraction for the Memory OS.

    masc#26122: the librarian's input carries the keeper's current fact store
    and its output is a list of typed recognition operations
    ({!Keeper_librarian_recognition.operation}), not bare claims. *)

open Keeper_memory_os_types

module Canonical_tool = Agent_sdk.Canonical_tool
module Recognition = Keeper_librarian_recognition

type input =
  { trace_id : string
  ; generation : int
  ; messages : Agent_sdk.Types.message list
  ; store : fact list
    (* The keeper's current facts, exactly as read before the LLM call. The
       prompt renders them with 0-based indices; every index in the output
       operations refers to this snapshot. *)
  }

let wire_field_episode_summary = Keeper_memory_os_types.wire_field_episode_summary
let wire_field_operations = Keeper_memory_os_types.wire_field_operations
let wire_field_op = Keeper_memory_os_types.wire_field_op
let wire_field_fact = Keeper_memory_os_types.wire_field_fact
let wire_field_index = Keeper_memory_os_types.wire_field_index
let wire_field_member_indices = Keeper_memory_os_types.wire_field_member_indices
let wire_field_reason = Keeper_memory_os_types.wire_field_reason
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
let wire_field_schema_version = Keeper_memory_os_types.wire_field_schema_version
let wire_episode_fields = Keeper_memory_os_types.wire_librarian_episode_fields
let wire_claim_fields = Keeper_memory_os_types.wire_librarian_claim_fields
let wire_operation_fields = Keeper_memory_os_types.wire_librarian_operation_fields

let accepted_episode_fields = wire_field_schema_version :: wire_episode_fields

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

let truncate_text max_len s =
  if String.length s <= max_len then s else String.sub s 0 max_len ^ "\n...[truncated]"
;;

let truncate_for_log max_len s =
  if String.length s <= max_len then s else String.sub s 0 max_len ^ "..."
;;

let format_messages_for_prompt messages =
  match messages with
  | [] -> "[no messages]"
  | _ ->
    messages
    |> List.mapi (fun turn message -> message_to_text ~turn message)
    |> List.map (truncate_text 4000)
    |> String.concat "\n\n---\n\n"
;;

let format_store_for_prompt store =
  match store with
  | [] -> "[no stored facts]"
  | _ :: _ -> Keeper_memory_os_consolidation.render_numbered_facts store
;;

let prompt_variables (inp : input) : (string * string) list =
  [ ( "conversation_history"
    , inp.messages |> format_messages_for_prompt )
  ; "current_store", format_store_for_prompt inp.store
  ]
;;

let string_field key fields =
  match List.assoc_opt key fields with
  | Some (`String s) -> trim_nonempty s
  | Some (`Assoc _ | `Bool _ | `Float _ | `Int _ | `Intlit _ | `List _ | `Null)
  | None -> None
;;

let optional_string_field key fields =
  match List.assoc_opt key fields with
  | Some (`String s) -> trim_nonempty s
  | Some `Null | None -> None
  | Some (`Assoc _ | `Bool _ | `Float _ | `Int _ | `Intlit _ | `List _) -> None
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
  | Operation_schema_mismatch of string

let parse_error_to_string = function
  | Empty_output -> "empty_output"
  | Invalid_json msg -> "invalid_json: " ^ msg
  | Json_string_invalid_json msg -> "json_string_invalid_json: " ^ msg
  | Top_level_not_object -> "top_level_not_object"
  | Unexpected_field field -> "unexpected_field: " ^ field
  | Missing_required_fields -> "missing_required_fields"
  | Claim_schema_mismatch -> "claim_schema_mismatch"
  | Operation_schema_mismatch detail -> "operation_schema_mismatch: " ^ detail
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
       , string_field wire_field_category fields
       , int_field wire_field_source_turn fields
       , claim_kind_field fields
       , claim_id_field fields
       , optional_string_field_strict wire_field_source_tool_call_id fields
       , valid_for_days_field fields
     with
     | ( Some claim
       , Some category_str
       , Some turn
       , Some claim_kind
       , Some claim_id
       , Some tool_call_id
       , Some valid_for_days )
       when turn >= 0 ->
      (* Parse the provider's category once at the producer boundary. It remains
         context and never creates a validity horizon. *)
      let category = category_of_string category_str in
      Some
        { claim
        ; category
        ; claim_kind
         ; source = claim_source ~trace_id turn tool_call_id
         (* Tier-1 (per-keeper) facts carry no distinct-keeper corroboration set;
            the consolidator populates observed_by only on promotion (RFC-0244). *)
         ; observed_by = []
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
         ; reinforcement_count = 0 (* first observation; Reinforce ops move it *)
         }
     | (Some _, Some _, Some _, _, _, _, _)
     | (Some _, Some _, None, _, _, _, _)
     | (Some _, None, _, _, _, _, _)
     | (None, _, _, _, _, _, _) -> None)
  | `Bool _ | `Float _ | `Int _ | `Intlit _ | `List _ | `Null | `String _ -> None
;;

let source_turn_range claims =
  match claims with
  | [] -> None
  | first :: rest ->
    let init = first.source.turn in
    let lo = List.fold_left (fun acc claim -> min acc claim.source.turn) init rest in
    let hi = List.fold_left (fun acc claim -> max acc claim.source.turn) init rest in
    Some (lo, hi)
;;

let unexpected_claim_field = function
  | `Assoc fields -> first_unexpected_field ~allowed:wire_claim_fields fields
  | `Bool _ | `Float _ | `Int _ | `Intlit _ | `List _ | `Null | `String _ -> None
;;

(* ---------- Recognition operation parsing (masc#26122) ---------- *)

(* Every non-null key of an operation object must be [op] or listed in
   [relevant]. A non-null value on a field foreign to the op is model
   confusion and rejects the whole output, like every other strict check
   here. *)
let first_foreign_non_null_field ~relevant fields =
  List.find_map
    (fun (key, value) ->
       match value with
       | `Null -> None
       | _ ->
         if String.equal key wire_field_op
            || List.exists (String.equal key) relevant
         then None
         else Some key)
    fields
;;

let operation_mismatch op detail =
  Error (Operation_schema_mismatch (op ^ ": " ^ detail))
;;

let index_field fields =
  match int_field wire_field_index fields with
  | Some i when i >= 0 -> Some i
  | Some _ | None -> None
;;

let member_indices_field fields =
  match List.assoc_opt wire_field_member_indices fields with
  | Some (`List items) ->
    traverse (function
      | `Int i when i >= 0 -> Some i
      | _ -> None)
      items
  | Some (`Assoc _ | `Bool _ | `Float _ | `Int _ | `Intlit _ | `Null | `String _)
  | None -> None
;;

let operation_of_json ~trace_id ~now (json : Yojson.Safe.t) :
  (Recognition.operation, parse_error) result
  =
  match json with
  | `Assoc fields ->
    (match first_unexpected_field ~allowed:wire_operation_fields fields with
     | Some field -> Error (Unexpected_field field)
     | None ->
       (match string_field wire_field_op fields with
        | None -> Error (Operation_schema_mismatch "missing op")
        | Some op when String.equal op Keeper_memory_os_types.wire_op_add ->
          (match first_foreign_non_null_field ~relevant:[ wire_field_fact ] fields with
           | Some field -> operation_mismatch op ("foreign field " ^ field)
           | None ->
             (match List.assoc_opt wire_field_fact fields with
              | Some (`Assoc _ as fact_json) ->
                (match unexpected_claim_field fact_json with
                 | Some field -> Error (Unexpected_field field)
                 | None ->
                   (match fact_of_json ~trace_id ~now fact_json with
                    | Some fact -> Ok (Recognition.Add fact)
                    | None -> Error Claim_schema_mismatch))
              | Some _ | None -> operation_mismatch op "missing fact object"))
        | Some op when String.equal op Keeper_memory_os_types.wire_op_reinforce ->
          (match
             first_foreign_non_null_field
               ~relevant:[ wire_field_index; wire_field_source_turn ]
               fields
           with
           | Some field -> operation_mismatch op ("foreign field " ^ field)
           | None ->
             (match index_field fields, int_field wire_field_source_turn fields with
              | Some index, Some source_turn when source_turn >= 0 ->
                Ok (Recognition.Reinforce { index; source_turn })
              | _ -> operation_mismatch op "requires index and source_turn"))
        | Some op when String.equal op Keeper_memory_os_types.wire_op_merge ->
          (match
             first_foreign_non_null_field
               ~relevant:
                 [ wire_field_member_indices; wire_field_claim; wire_field_category ]
               fields
           with
           | Some field -> operation_mismatch op ("foreign field " ^ field)
           | None ->
             (match
                ( member_indices_field fields
                , string_field wire_field_claim fields
                , string_field wire_field_category fields )
              with
              | Some (_ :: _ :: _ as member_indices), Some claim, Some category ->
                Ok
                  (Recognition.Merge
                     { member_indices
                     ; consolidated_claim = claim
                     ; category = category_of_string category
                     })
              | _ ->
                operation_mismatch
                  op
                  "requires member_indices (>= 2), claim, and category"))
        | Some op when String.equal op Keeper_memory_os_types.wire_op_revise ->
          (match
             first_foreign_non_null_field
               ~relevant:
                 [ wire_field_index
                 ; wire_field_claim
                 ; wire_field_category
                 ; wire_field_claim_id
                 ; wire_field_valid_for_days
                 ]
               fields
           with
           | Some field -> operation_mismatch op ("foreign field " ^ field)
           | None ->
             (match
                ( index_field fields
                , string_field wire_field_claim fields
                , optional_string_field wire_field_category fields
                , claim_id_field fields
                , valid_for_days_field fields )
              with
              | Some index, Some claim, category, Some claim_id, Some valid_for_days ->
                Ok
                  (Recognition.Revise
                     { index
                     ; claim
                     ; category = Option.map category_of_string category
                     ; claim_id
                     ; valid_for_days
                     })
              | _ -> operation_mismatch op "requires index and claim"))
        | Some op when String.equal op Keeper_memory_os_types.wire_op_forget ->
          (match
             first_foreign_non_null_field
               ~relevant:[ wire_field_index; wire_field_reason ]
               fields
           with
           | Some field -> operation_mismatch op ("foreign field " ^ field)
           | None ->
             (match index_field fields, string_field wire_field_reason fields with
              | Some index, Some reason -> Ok (Recognition.Forget { index; reason })
              | _ -> operation_mismatch op "requires index and reason"))
        | Some op -> Error (Operation_schema_mismatch ("unknown op " ^ op))))
  | `Bool _ | `Float _ | `Int _ | `Intlit _ | `List _ | `Null | `String _ ->
    Error (Operation_schema_mismatch "operation is not an object")
;;

(* The librarian's full recognition output: the episode narrative plus the
   typed store operations. *)
type recognition_output =
  { episode_summary : string
  ; operations : Recognition.operation list
  ; open_items : string list
  ; constraints : string list
  ; preserved_tool_refs : string list
  }

let rec traverse_result f = function
  | [] -> Ok []
  | x :: xs ->
    (match f x with
     | Error _ as error -> error
     | Ok y ->
       (match traverse_result f xs with
        | Error _ as error -> error
        | Ok ys -> Ok (y :: ys)))
;;

let recognition_output_of_json_result ?now (inp : input) (json : Yojson.Safe.t) :
  (recognition_output, parse_error) result
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
    (match first_unexpected_field ~allowed:accepted_episode_fields fields with
     | Some field -> Error (Unexpected_field field)
     | None ->
       (match
          string_field wire_field_episode_summary fields
          , List.assoc_opt wire_field_operations fields
          , string_list_field_or_empty wire_field_open_items fields
          , string_list_field_or_empty wire_field_constraints fields
          , string_list_field_or_empty wire_field_preserved_tool_refs fields
        with
        | ( Some episode_summary
          , Some (`List operation_items)
          , Some open_items
          , Some constraints
          , Some preserved_tool_refs ) ->
          (match
             traverse_result
               (operation_of_json ~trace_id:inp.trace_id ~now)
               operation_items
           with
           | Error _ as error -> error
           | Ok operations ->
             if Recognition.operations_have_overlapping_targets operations
             then
               Error
                 (Operation_schema_mismatch
                    "operations must not target the same fact index")
             else
               Ok
                 { episode_summary
                 ; operations
                 ; open_items
                 ; constraints
                 ; preserved_tool_refs
                 })
        | _ -> Error Missing_required_fields))
  | `Bool _ | `Float _ | `Int _ | `Intlit _ | `List _ | `Null | `String _ ->
    Error Top_level_not_object
;;

let recognition_output_of_output_result ?now (inp : input) (raw : string) :
  (recognition_output, parse_error) result
  =
  match json_of_output raw with
  | Error _ as error -> error
  | Ok json -> recognition_output_of_json_result ?now inp json
;;

(* The persisted episode for one applied recognition pass: the narrative from
   the librarian, the recognized (created/rewritten) rows as its claims. *)
let episode_of_recognition
      ~now
      ~generation
      (inp : input)
      (out : recognition_output)
      ~recognized_facts
  : episode
  =
  { trace_id = inp.trace_id
  ; generation
  ; episode_summary = out.episode_summary
  ; claims = recognized_facts
  ; open_items = out.open_items
  ; constraints = out.constraints
  ; preserved_tool_refs = out.preserved_tool_refs
  ; source_turn_range = source_turn_range recognized_facts
  ; created_at = now
  ; valid_until = None
  ; terminal_marker = None
  ; schema_version
  }
;;
