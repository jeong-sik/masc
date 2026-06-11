(** Keeper_librarian — structured claim extraction for the Memory OS. *)

open Keeper_memory_os_types

type input =
  { trace_id : string
  ; generation : int
  ; messages : Agent_sdk.Types.message list
  }

let role_to_string = function
  | Agent_sdk.Types.User -> "user"
  | Agent_sdk.Types.Assistant -> "assistant"
  | Agent_sdk.Types.System -> "system"
  | Agent_sdk.Types.Tool -> "tool"

let text_of_content = function
  | Agent_sdk.Types.Text s -> Some s
  | Agent_sdk.Types.ToolUse { name; _ } -> Some (Printf.sprintf "[tool use: %s]" name)
  | Agent_sdk.Types.ToolResult { tool_use_id; is_error; _ } ->
    Some
      (Printf.sprintf
         "[tool result omitted: id=%s is_error=%b]"
         tool_use_id
         is_error)
  | Agent_sdk.Types.Thinking _ | Agent_sdk.Types.RedactedThinking _ -> None
  | _ -> None

let message_to_text (m : Agent_sdk.Types.message) : string =
  let parts = List.filter_map text_of_content m.content in
  let body = String.concat "\n" parts |> String.trim in
  if body = "" then
    Printf.sprintf "[%s] (empty)" (role_to_string m.role)
  else
    Printf.sprintf "[%s] %s" (role_to_string m.role) body

let truncate_text max_len s =
  if String.length s <= max_len then
    s
  else
    String.sub s 0 max_len ^ "\n...[truncated]"

let format_messages_for_prompt messages =
  messages
  |> List.map message_to_text
  |> List.map (truncate_text 4000)
  |> String.concat "\n\n---\n\n"

let scrub_messages_for_librarian messages =
  List.map Keeper_summarizer.scrub_text_blocks messages

let replace_first_placeholder ~placeholder ~replacement template =
  let placeholder_len = String.length placeholder in
  let template_len = String.length template in
  let rec find i =
    if i + placeholder_len > template_len
    then None
    else if String.sub template i placeholder_len = placeholder
    then Some i
    else find (i + 1)
  in
  match find 0 with
  | None -> template ^ replacement
  | Some i ->
    String.sub template 0 i
    ^ replacement
    ^ String.sub template (i + placeholder_len) (template_len - i - placeholder_len)

let prompt_of_input (inp : input) : string =
  replace_first_placeholder
    ~placeholder:"%s"
    ~replacement:
      (inp.messages
       |> scrub_messages_for_librarian
       |> format_messages_for_prompt)
    Keeper_librarian_prompts.episode_extraction

let claim_source ~trace_id turn tool_call_id =
  { trace_id; turn; tool_call_id }

let fact_of_json ~trace_id (j : Yojson.Safe.t) : fact option =
  match j with
  | `Assoc fields ->
    let find_string key =
      match List.assoc_opt key fields with
      | Some (`String s) -> Some s
      | _ -> None
    in
    let find_float key =
      match List.assoc_opt key fields with
      | Some (`Float f) -> Some f
      | _ -> None
    in
    let find_int key =
      match List.assoc_opt key fields with
      | Some (`Int i) -> Some i
      | _ -> None
    in
    (match find_string "claim", find_float "confidence", find_string "category" with
     | Some claim, Some confidence, Some category ->
       (* DET-OK: source_turn is advisory provenance; absent means turn 0. *)
       let turn = Option.value (find_int "source_turn") ~default:0 in
       let tool_call_id = find_string "source_tool_call_id" in
       let source = claim_source ~trace_id turn tool_call_id in
       (* NDT-OK: extraction timestamp used for retention scoring/provenance only. *)
       let now = Unix.gettimeofday () in
       Some
         { claim
         ; confidence = Float.max 0.0 (Float.min 1.0 confidence)
         ; category
         ; source
         ; access_count = 0
         ; first_seen = now
         ; last_accessed = now
         ; valid_until = None
         ; schema_version
         }
     | _ -> None)
  | _ -> None

let string_list_of_json = function
  | `List items ->
    let strings = List.filter_map (function `String s -> Some s | _ -> None) items in
    if List.length strings = List.length items then Some strings else None
  | _ -> None

let string_list_of_field field fields =
  match List.assoc_opt field fields with
  | Some json -> string_list_of_json json
  | None -> Some []

let episode_of_output (inp : input) (raw : string) : episode option =
  try
    match Yojson.Safe.from_string raw with
    | `Assoc fields ->
      let find_string key =
        match List.assoc_opt key fields with
        | Some (`String s) -> Some s
        | _ -> None
      in
      (match
         ( find_string "episode_summary"
         , List.assoc_opt "claims" fields
         , string_list_of_field "open_items" fields
         , string_list_of_field "constraints" fields
         , string_list_of_field "preserved_tool_refs" fields )
       with
       | Some episode_summary, Some (`List claim_items), Some open_items, Some constraints, Some preserved_tool_refs ->
         let claims = List.filter_map (fact_of_json ~trace_id:inp.trace_id) claim_items in
         let source_turn_range =
           match claims with
           | [] -> None
           | first :: rest ->
             let init = first.source.turn in
             let lo =
               List.fold_left
                 (fun acc claim -> min acc claim.source.turn)
                 init
                 rest
             in
             let hi =
               List.fold_left
                 (fun acc claim -> max acc claim.source.turn)
                 init
                 rest
             in
             Some (lo, hi)
         in
         Some
           { trace_id = inp.trace_id
           ; generation = inp.generation
           ; episode_summary
           ; claims
           ; open_items
           ; constraints
           ; preserved_tool_refs
           ; source_turn_range
           (* NDT-OK: episode creation timestamp used for retention/eviction only. *)
           ; created_at = Unix.gettimeofday ()
           ; schema_version
           }
       | _ -> None)
    | _ -> None
  with
  | _ -> None
