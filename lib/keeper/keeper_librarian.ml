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
  | Agent_sdk.Types.ToolResult { content; _ } -> Some (Printf.sprintf "[tool result: %s]" content)
  | Agent_sdk.Types.Thinking { content; _ } -> Some (Printf.sprintf "[thinking: %s]" content)
  | Agent_sdk.Types.RedactedThinking s -> Some (Printf.sprintf "[redacted thinking: %s]" s)
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

let prompt_of_input (inp : input) : string =
  Keeper_librarian_prompts.episode_extraction
  ^ format_messages_for_prompt inp.messages

let scrub_messages_for_librarian messages =
  List.map Keeper_summarizer.scrub_text_blocks messages

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
       let turn = Option.value (find_int "source_turn") ~default:0 in
       let tool_call_id = find_string "source_tool_call_id" in
       let source = claim_source ~trace_id turn tool_call_id in
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
           | cs ->
             let turns = List.map (fun c -> c.source.turn) cs in
             Some (List.fold_left min (List.hd turns) (List.tl turns), List.fold_left max (List.hd turns) (List.tl turns))
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
           ; created_at = Unix.gettimeofday ()
           ; schema_version
           }
       | _ -> None)
    | _ -> None
  with
  | _ -> None
