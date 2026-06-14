(** Keeper_librarian — structured claim extraction for the Memory OS. *)

open Keeper_memory_os_types

type input =
  { trace_id : string
  ; generation : int
  ; messages : Agent_sdk.Types.message list
  }

let trim_nonempty s =
  let s = String.trim s in
  if String.equal s "" then None else Some s
;;

let role_to_string = function
  | Agent_sdk.Types.User -> "user"
  | Agent_sdk.Types.Assistant -> "assistant"
  | Agent_sdk.Types.System -> "system"
  | Agent_sdk.Types.Tool -> "tool"
;;

let text_of_content = function
  | Agent_sdk.Types.Text s -> trim_nonempty s
  | Agent_sdk.Types.ToolUse { id; name; _ } ->
    Some (Printf.sprintf "[tool use omitted: id=%s name=%s]" id name)
  | Agent_sdk.Types.ToolResult { tool_use_id; is_error; _ } ->
    Some
      (Printf.sprintf
         "[tool result omitted: id=%s is_error=%b]"
         tool_use_id
         is_error)
  | Agent_sdk.Types.Thinking _ | Agent_sdk.Types.RedactedThinking _ -> None
  | Agent_sdk.Types.Image _ -> Some "[image omitted]"
  | Agent_sdk.Types.Document _ -> Some "[document omitted]"
  | Agent_sdk.Types.Audio _ -> Some "[audio omitted]"
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

let format_messages_for_prompt messages =
  match messages with
  | [] -> "[no messages]"
  | _ ->
    messages
    |> List.mapi (fun turn message -> message_to_text ~turn message)
    |> List.map (truncate_text 4000)
    |> String.concat "\n\n---\n\n"
;;

let scrub_messages_for_librarian messages =
  List.map Keeper_summarizer.scrub_text_blocks messages
;;

let prompt_variables (inp : input) : (string * string) list =
  [ ( "conversation_history"
    , inp.messages |> scrub_messages_for_librarian |> format_messages_for_prompt )
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

let number_field key fields =
  match List.assoc_opt key fields with
  | Some (`Float f) -> Some f
  | Some (`Int i) -> Some (float_of_int i)
  | Some (`Assoc _ | `Bool _ | `Intlit _ | `List _ | `Null | `String _) | None -> None
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

let confidence_field fields =
  match number_field "confidence" fields with
  | Some confidence when confidence >= 0.0 && confidence <= 1.0 -> Some confidence
  | Some _ | None -> None
;;

let claim_source ~trace_id turn tool_call_id =
  { trace_id; turn; tool_call_id }
;;

let fact_of_json ~trace_id ~now (json : Yojson.Safe.t) : fact option =
  match json with
  | `Assoc fields ->
    (match
       string_field "claim" fields
       , confidence_field fields
       , string_field "category" fields
       , int_field "source_turn" fields
     with
     | Some claim, Some confidence, Some category, Some turn when turn >= 0 ->
       let tool_call_id = optional_string_field "source_tool_call_id" fields in
       Some
         { claim
         ; confidence
         ; category
         ; source = claim_source ~trace_id turn tool_call_id
         ; access_count = 0
         ; first_seen = now
         ; last_accessed = now
         ; valid_until = None
         ; schema_version
         }
     | (Some _, Some _, Some _, Some _)
     | (Some _, Some _, Some _, None)
     | (Some _, Some _, None, _)
     | (Some _, None, _, _)
     | (None, _, _, _) -> None)
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

let episode_of_output ?now (inp : input) (raw : string) : episode option =
  let now =
    match now with
    | Some now -> now
    | None ->
      (* NDT-OK: extraction timestamps are provenance/retention metadata only. *)
      Unix.gettimeofday ()
  in
  try
    match Yojson.Safe.from_string raw with
    | `Assoc fields ->
      (match
         string_field "episode_summary" fields
         , List.assoc_opt "claims" fields
         , string_list_field "open_items" fields
         , string_list_field "constraints" fields
         , string_list_field "preserved_tool_refs" fields
       with
       | ( Some episode_summary
         , Some (`List claim_items)
         , Some open_items
         , Some constraints
         , Some preserved_tool_refs ) ->
         (match traverse (fact_of_json ~trace_id:inp.trace_id ~now) claim_items with
          | Some claims ->
            Some
              { trace_id = inp.trace_id
              ; generation = inp.generation
              ; episode_summary
              ; claims
              ; open_items
              ; constraints
              ; preserved_tool_refs
              ; source_turn_range = source_turn_range claims
              ; created_at = now
              ; schema_version
              }
          | None -> None)
       | _ -> None)
    | `Bool _ | `Float _ | `Int _ | `Intlit _ | `List _ | `Null | `String _ -> None
  with
  | Yojson.Json_error _ -> None
;;
