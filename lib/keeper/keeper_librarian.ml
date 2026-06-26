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

type parse_error =
  | Empty_output
  | Invalid_json of string
  | Json_string_invalid_json of string
  | Top_level_not_object
  | Missing_required_fields
  | Claim_schema_mismatch

let parse_error_to_string = function
  | Empty_output -> "empty_output"
  | Invalid_json msg -> "invalid_json: " ^ msg
  | Json_string_invalid_json msg -> "json_string_invalid_json: " ^ msg
  | Top_level_not_object -> "top_level_not_object"
  | Missing_required_fields -> "missing_required_fields"
  | Claim_schema_mismatch -> "claim_schema_mismatch"
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

let fact_of_json ~trace_id ~now (json : Yojson.Safe.t) : fact option =
  match json with
  | `Assoc fields ->
    (match
       string_field "claim" fields
       , string_field "category" fields
       , int_field "source_turn" fields
     with
     | Some claim, Some category_str, Some turn when turn >= 0 ->
       let tool_call_id = optional_string_field "source_tool_call_id" fields in
      (* RFC-0259 §3.7 (P6): a stable conclusion slug the model emits so a reworded
         re-extraction of the same conclusion reuses the id and UPSERTs the existing
         row (defect E/F). Pass-through only — absent => [None] (conservative
         fallback to [normalize_claim] keying); we never derive/hash an id in code,
         which would be the string-classifier workaround the RFC rejects. *)
      let claim_id = optional_string_field "claim_id" fields in
      (* RFC-0285 §3.1/§3.2(a): the producer-emitted origin tag. Pass-through only —
         the librarian LLM classifies at the live-context boundary; deriving
         claim_kind in code would be the read-time string-classifier workaround the
         RFC rejects. Absent/unrecognized => [None], routing to the durable path. *)
      let claim_kind =
        Option.bind (optional_string_field "claim_kind" fields) claim_kind_of_string
      in
      (* Parse-once at the producer boundary: the LLM's free-text category becomes
         a typed [category] here, so no surface string reaches the store or the
         consolidator (RFC-0244 §2.3 / #21241; RFC-0247 §2.5). The category drives
         retention (RFC-0247 §2.3) — an [Ephemeral] coordination claim is born
         with a short TTL, durable knowledge with none. RFC-0247 also stopped
         parsing the LLM's [confidence] number: the score it fed is gone. *)
      let category = category_of_string category_str in
      (* No code-side external-ref inference from claim prose. The claim text is
         context for the model; it may mention a PR/issue/task as history or a
         durable lesson, so retention must not be changed by a string matcher. *)
      let external_ref = None in
      Some
        { claim
        ; category
        ; external_ref
        ; claim_kind
         ; source = claim_source ~trace_id turn tool_call_id
         (* Tier-1 (per-keeper) facts carry no distinct-keeper corroboration set;
            the consolidator populates observed_by only on promotion (RFC-0244). *)
         ; observed_by = []
         ; first_seen = now
         ; valid_until = fact_valid_until ~now ~external_ref ~claim_kind category
         ; last_verified_at = Some now
         ; schema_version
         ; claim_id
         }
     | (Some _, Some _, Some _)
     | (Some _, Some _, None)
     | (Some _, None, _)
     | (None, _, _) -> None)
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

let episode_of_output_result ?now ~generation (inp : input) (raw : string) :
  (episode, parse_error) result
  =
  let now =
    match now with
    | Some now -> now
    | None ->
      (* NDT-OK: extraction timestamps are provenance/retention metadata only. *)
      Unix.gettimeofday ()
  in
  match json_of_output raw with
  | Error _ as error -> error
  | Ok json ->
    (match json with
    | `Assoc fields ->
      (match
         string_field "episode_summary" fields
         , List.assoc_opt "claims" fields
         , string_list_field_or_empty "open_items" fields
         , string_list_field_or_empty "constraints" fields
         , string_list_field_or_empty "preserved_tool_refs" fields
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
              ; generation
              ; episode_summary
              ; claims
              ; open_items
              ; constraints
              ; preserved_tool_refs
              ; source_turn_range = source_turn_range claims
              ; created_at = now
              ; valid_until = None
              ; terminal_marker = None
              ; schema_version
              }
          | None -> Error Claim_schema_mismatch)
       | _ -> Error Missing_required_fields)
    | `Bool _ | `Float _ | `Int _ | `Intlit _ | `List _ | `Null | `String _ ->
      Error Top_level_not_object)
;;

let episode_of_output ?now ~generation inp raw : episode option =
  match episode_of_output_result ?now ~generation inp raw with
  | Ok episode -> Some episode
  | Error error ->
    Log.Keeper.debug
      "librarian episode parse failed: %s (raw: %s)"
      (parse_error_to_string error)
      (truncate_for_log 800 raw);
    None
;;
