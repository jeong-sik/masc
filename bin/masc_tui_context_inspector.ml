type exact_input_kind =
  | System_prompt
  | Message of { role : string }
  | Tool_schema of { name : string }

type exact_input_item =
  { index : int
  ; kind : exact_input_kind
  ; bytes : int
  ; sha256 : string
  }

type provider_input =
  { trace_id : string
  ; absolute_turn : int
  ; turn_ref : Ids.Turn_ref.t
  ; runtime_profile : string
  ; captured_at : float
  ; wire : Llm_provider.Request_wire_observer.observation
  ; items : exact_input_item list
  }

(* The interface constrains these; the implementation must still declare
   them — without this the record literals below have no fields in scope. *)
type attributed_turn =
  { record : Turn_record.t
  ; components : Turn_record.input_component list
  ; turns_behind_latest : int
  }

type recent_turn =
  { turn : int
  ; ts : float
  ; input_tokens : int option
  ; provider_context_window : int option
  ; cache_read : int option
  ; output_tokens : int option
  ; turn_output_tokens : int option
  ; scope : Runtime_usage_scope.t
  }

type selection =
  { latest : Turn_record.t
  ; attributed : attributed_turn option
  ; recent : recent_turn list
  ; rows : Turn_record.t list
  }

type response_part =
  | Reply_text of string
  | Tool_steps of string list
  | Reasoning_lines of string list
  | Request_failure of string

type response_source = Newest_history_page | Exact_turn_transcript

type response_turn =
  { parts : response_part list
  ; source : response_source
  }

(* ── Next request forecast ───────────────────────────── *)

type forecast_lane =
  | Lane_agent_core
  | Lane_not_applicable of string

type forecast_parts =
  { reserved_measured_on_turn : int
  ; reserved_bytes : int
  ; pinned_measured_on_turn : int
  ; pinned_measured_on_runtime : string
  ; pinned_bytes : int
  }

type forecast_carried_origin =
  | Carried_from_ledger
  | Carried_from_turn_record of { turn : int }
  | Carried_turn_start_after_seed_refusal
  | Carried_turn_start_after_librarian_refusal
  | Carried_turn_start of { end_atom : int }
  | Carried_turn_start_unknown of { reason : string }
  | Carried_librarian_snapshot of { end_atom : int; boundary_line : int }
  | Carried_librarian_progress of { end_atom : int }
  | Carried_past_librarian_point of
      { librarian_end_atom : int
      ; front : forecast_carried_origin
      }

type forecast_carried =
  { first_atom : int
  ; kept_atoms : int
  ; transmitted_bytes : int
  ; origin : forecast_carried_origin
  ; counted_tokens : int option
  }

type forecast_slot =
  | Slot_system_prompt of { bytes : int }
  | Slot_tools of { bytes : int }
  | Slot_preamble of { bytes : int }
  | Slot_history of { atoms : int; of_atoms : int; bytes : int }
  | Slot_wake_line of { bytes : int }
  | Slot_system_context of { bytes : int; blocks : (string * int) list }

type forecast_rest =
  | Rest_serving
  | Rest_resting of { release_at : float; walk_promotes_at_release : bool }

type forecast_place =
  { walks_at : int
  ; declared_at : int option
  ; rest : forecast_rest
  }

type forecast_walk =
  { lane_id : string
  ; declared : string list
  }

type forecast_candidate =
  { runtime_id : string
  ; lane : forecast_lane
  ; parts : (forecast_parts, string) result
  ; history_atoms : int
  ; carried : forecast_carried option
  ; assembly : forecast_slot list option
  ; place : forecast_place
  }

type forecast =
  { checkpoint_messages : int
  ; wake_line_bytes : int
  ; walk : (forecast_walk, string) result
  ; candidates : forecast_candidate list
  }

type target = Recent of int | Pinned of Ids.Turn_ref.t

type exact_turn_record =
  { record : Turn_record.t
  ; skipped_rows : int
  }

type 'a observation = Pending | Observed of ('a, string) result

type exact_reading =
  { turn_ref : Ids.Turn_ref.t
  ; record : exact_turn_record observation
  ; provider_input : provider_input observation
  ; response : response_turn observation
  }

type reading =
  | Request_failed of string
  | Turn_read_failed of
      { detail : string
      ; forecast : (forecast, string) result
      }
  | Turn_read of
      { selection : selection
      ; provider_input : (provider_input, string) result
      ; response : (response_turn, string) result
      ; forecast : (forecast, string) result
      }
  | Exact_read of exact_reading

let is_loading = function
  | Request_failed _ | Turn_read_failed _ | Turn_read _ -> false
  | Exact_read { record; provider_input; response; _ } ->
      let pending = function Pending -> true | Observed _ -> false in
      pending record || pending provider_input || pending response

let merge_progress ~previous incoming =
  match incoming with
  | Request_failed _ | Turn_read_failed _ | Turn_read _ -> incoming
  | Exact_read next ->
      (match previous with
       | Some (Exact_read held) when Ids.Turn_ref.equal held.turn_ref next.turn_ref ->
           let merge held = function Pending -> held | Observed result -> Observed result in
           Exact_read
             { next with
               record = merge held.record next.record
             ; provider_input = merge held.provider_input next.provider_input
             ; response = merge held.response next.response }
       | Some (Exact_read _ | Request_failed _ | Turn_read_failed _ | Turn_read _) | None -> incoming)

let observed_input = function
  | Turn_read { provider_input = Ok input; _ }
  | Exact_read { provider_input = Observed (Ok input); _ } -> Some input
  | Request_failed _ | Turn_read_failed _
  | Turn_read { provider_input = Error _; _ }
  | Exact_read { provider_input = (Pending | Observed (Error _)); _ } -> None

let step_recent target ~older ~count =
  match target with
  | Pinned _ -> None
  | Recent turn_back ->
      let next = if older then min (count - 1) (turn_back + 1) else max 0 (turn_back - 1) in
      if count <= 0 || next = turn_back then None else Some (Recent next)

let retained_forecast = function
  | Turn_read { forecast; _ } | Turn_read_failed { forecast; _ } -> Some forecast
  | Request_failed _ | Exact_read _ -> None

type tab =
  | Composition
  | Exact_input
  | Input_map
  | Response

type input_source =
  | Turn_prompt_assembly
  | Effective_tool_surface
  | Provider_message_list

type input_evidence =
  | Verified_exact_text
  | Serialized_turn_snapshot
  | Producer_digest_only
  | Byte_count_only

type input_map_row =
  { component : Turn_record.input_component_id
  ; bytes : int
  ; source : input_source
  ; evidence : input_evidence
  ; digest : string option
  ; verified_item : exact_input_item option
  }

type part_key =
  { part_keeper : string
  ; part_turn_ref : Ids.Turn_ref.t
  ; part_item : exact_input_item
  }

open Result.Syntax

let decode_entry = function
  | `Assoc fields ->
      (match List.assoc_opt "record" fields with
       | Some json -> Turn_record.of_json json
       | None -> Error "turn-records entry is missing record")
  | _ -> Error "turn-records entry is not an object"

let decode_turn_records = function
  | `Assoc fields ->
      (match List.assoc_opt "entries" fields with
       | Some (`List rows) ->
           let rec decode reversed = function
             | [] -> Ok (List.rev reversed)
             | row :: rest ->
                 let* record = decode_entry row in
                 decode (record :: reversed) rest
           in
           let* records = decode [] rows in
           (match List.rev records with
            | [] -> Error "turn-records returned no rows"
            | (latest : Turn_record.t) :: _ as newest_first ->
                let rec newest_attributed = function
                  | [] -> None
                  | (record : Turn_record.t) :: rest ->
                      (match record.input_components with
                       | Some components ->
                           Some
                             { record
                             ; components
                             ; turns_behind_latest =
                                 latest.absolute_turn - record.absolute_turn
                             }
                       | None -> newest_attributed rest)
                in
                (* Only a per-request figure describes one request's input. *)
                let per_request_tokens (record : Turn_record.t) =
                  match record.usage.scope with
                  | Runtime_usage_scope.Turn_total
                  | Runtime_usage_scope.Conversation_cumulative
                  | Runtime_usage_scope.Usage_scope_unavailable -> None
                  | Runtime_usage_scope.Per_request ->
                      record.usage.input_tokens
                in
                let recent =
                  List.map
                    (fun (record : Turn_record.t) ->
                      { turn = record.absolute_turn
                      ; ts = record.ts
                      ; input_tokens = per_request_tokens record
                      ; provider_context_window = record.provider_context_window
                      ; cache_read = record.usage.cache_read_input_tokens
                      ; output_tokens = record.usage.output_tokens
                      ; turn_output_tokens = record.turn_output_tokens
                      ; scope = record.usage.scope
                      })
                    newest_first
                in
                Ok
                  { latest
                  ; attributed = newest_attributed newest_first
                  ; recent
                  ; rows = newest_first
                  })
       | Some _ -> Error "turn-records entries is not a list"
       | None -> Error "turn-records response is missing entries")
  | _ -> Error "turn-records response is not an object"

let viewing_record selection ~turn_back =
  if turn_back <= 0 then
    Option.map (fun (attributed : attributed_turn) -> attributed.record) selection.attributed
  else List.nth_opt selection.rows turn_back

let inspected_record ~target = function
  | Request_failed _ | Turn_read_failed _ -> None
  | Turn_read { selection; _ } ->
      (match target with
       | Recent turn_back -> viewing_record selection ~turn_back
       | Pinned _ -> None)
  | Exact_read reading ->
      (match target with
       | Recent _ -> None
       | Pinned expected ->
         match reading.record with
         | Pending | Observed (Error _) -> None
         | Observed (Ok exact) ->
           if Ids.Turn_ref.equal expected reading.turn_ref
              && Ids.Turn_ref.equal expected exact.record.turn_ref
           then Some exact.record
           else None)

let exact_fields expected fields =
  List.length expected = List.length fields
  && List.for_all
       (fun name ->
          match List.filter (fun (key, _) -> String.equal key name) fields with
          | [ _ ] -> true
          | [] | _ :: _ :: _ -> false)
       expected

let field name fields =
  match List.assoc_opt name fields with
  | Some value -> Ok value
  | None -> Error ("provider-input response is missing " ^ name)

let nonempty_string name = function
  | `String value when not (String.equal value "") -> Ok value
  | _ -> Error (name ^ " is not a non-empty string")

let nonnegative_int name = function
  | `Int value when value >= 0 -> Ok value
  | _ -> Error (name ^ " is not a non-negative integer")

let sha256 name = function
  | `String value when String_util.is_lowercase_sha256_hex value -> Ok value
  | _ -> Error (name ^ " is not a lowercase SHA-256")

let decode_exact_turn_record ~expected_keeper ~expected_turn_ref json =
  let fail detail = Error ("exact turn-records: " ^ detail) in
  match json with
  | `Assoc fields when
      exact_fields [ "keeper"; "turn_ref"; "count"; "skipped_rows"; "source"; "entries" ] fields ->
      let get name =
        match List.assoc_opt name fields with
        | Some value -> Ok value
        | None -> fail ("missing " ^ name)
      in
      let* keeper_json = get "keeper" in
      let* () = match keeper_json with
        | `String keeper when String.equal keeper expected_keeper -> Ok ()
        | _ -> fail "Keeper does not match request" in
      let* ref_json = get "turn_ref" in
      let* turn_ref = Ids.Turn_ref.of_yojson ref_json in
      let* () =
        if Ids.Turn_ref.equal turn_ref expected_turn_ref then Ok ()
        else fail "Turn_ref does not match request" in
      let* count = get "count" in
      let* () = match count with
        | `Int 1 -> Ok ()
        | _ -> fail "count must be one" in
      let* source = get "source" in
      let* () = match source with
        | `String "turn_record" -> Ok ()
        | _ -> fail "source is not turn_record" in
      let* skipped_json = get "skipped_rows" in
      let* skipped_rows = nonnegative_int "skipped_rows" skipped_json in
      let* entries = get "entries" in
      let* record = match entries with
        | `List [ `Assoc entry ] when exact_fields [ "record"; "diff_vs_prev" ] entry ->
            (match List.assoc_opt "record" entry, List.assoc_opt "diff_vs_prev" entry with
             | Some record, Some `Null -> Turn_record.of_json record
             | _ -> fail "entry does not contain one record with no relative diff")
        | _ -> fail "entries must contain exactly one record" in
      if String.equal record.keeper expected_keeper
         && Ids.Turn_ref.equal record.turn_ref expected_turn_ref
      then Ok { record; skipped_rows }
      else fail "record identity does not match request"
  | _ -> fail "response fields are not exact"

let manifest_schema = "masc.provider-input-manifest.v1"
let part_schema = "masc.provider-input-part.v1"

let decode_part_entry json =
  match json with
  | `Assoc fields ->
    let kind_fields, label =
      match List.assoc_opt "kind" fields with
      | Some (`String "system_prompt") -> [ "index"; "kind"; "bytes"; "sha256" ], None
      | Some (`String "message") ->
        [ "index"; "kind"; "role"; "bytes"; "sha256" ], Some "role"
      | Some (`String "tool_schema") ->
        [ "index"; "kind"; "name"; "bytes"; "sha256" ], Some "name"
      | Some _ | None -> [], None
    in
    if kind_fields = [] || not (exact_fields kind_fields fields)
    then Error "provider-input part fields are not exact"
    else
      let* index_json = field "index" fields in
      let* index = nonnegative_int "part.index" index_json in
      let* bytes_json = field "bytes" fields in
      let* bytes = nonnegative_int "part.bytes" bytes_json in
      let* sha_json = field "sha256" fields in
      let* sha256 = sha256 "part.sha256" sha_json in
      let* kind =
        match label with
        | None -> Ok System_prompt
        | Some key ->
          let* label_json = field key fields in
          let* label = nonempty_string ("part." ^ key) label_json in
          Ok
            (if String.equal key "role"
             then Message { role = label }
             else Tool_schema { name = label })
      in
      Ok { index; kind; bytes; sha256 }
  | _ -> Error "provider-input part is not an object"

let decode_parts = function
  | `List values ->
    let rec loop expected reversed = function
      | [] -> Ok (List.rev reversed)
      | value :: rest ->
        let* item = decode_part_entry value in
        if item.index <> expected
        then
          Error
            (Printf.sprintf "provider-input part index %d is not contiguous"
               item.index)
        else loop (expected + 1) (item :: reversed) rest
    in
    loop 0 [] values
  | _ -> Error "provider-input parts is not an array"

let check_keeper ~expected_keeper fields =
  let* keeper_json = field "keeper" fields in
  let* keeper = nonempty_string "keeper" keeper_json in
  if String.equal keeper expected_keeper
  then Ok ()
  else
    Error
      (Printf.sprintf
         "provider-input belongs to %S, expected %S"
         keeper
         expected_keeper)

let decode_turn_ref_field fields =
  let* turn_ref_json = field "turn_ref" fields in
  match Ids.Turn_ref.of_yojson turn_ref_json with
  | Ok value -> Ok value
  | Error detail -> Error detail

let decode_provider_input ~expected_keeper ~expected_turn_ref = function
  | `Assoc fields
    when exact_fields
           [ "dashboard_surface"
           ; "schema"
           ; "keeper"
           ; "trace_id"
           ; "absolute_turn"
           ; "turn_ref"
           ; "runtime_profile"
           ; "captured_at"
           ; "wire"
           ; "parts"
           ]
           fields ->
    let* schema_json = field "schema" fields in
    let* schema = nonempty_string "schema" schema_json in
    let* () =
      if String.equal schema manifest_schema
      then Ok ()
      else Error ("unknown provider-input schema " ^ schema)
    in
    let* () = check_keeper ~expected_keeper fields in
    let* trace_json = field "trace_id" fields in
    let* trace_id = nonempty_string "trace_id" trace_json in
    let* turn_json = field "absolute_turn" fields in
    let* absolute_turn = nonnegative_int "absolute_turn" turn_json in
    let turn_ref = Ids.Turn_ref.make ~trace_id ~absolute_turn in
    let* observed_turn_ref = decode_turn_ref_field fields in
    let* () =
      if Ids.Turn_ref.equal turn_ref observed_turn_ref
         && Ids.Turn_ref.equal turn_ref expected_turn_ref
      then Ok ()
      else Error "provider-input turn_ref does not match the selected turn"
    in
    let* runtime_json = field "runtime_profile" fields in
    let* runtime_profile = nonempty_string "runtime_profile" runtime_json in
    let* captured_json = field "captured_at" fields in
    let* captured_at =
      match captured_json with
      | `Float value when Float.is_finite value && value >= 0. -> Ok value
      | `Int value when value >= 0 -> Ok (Float.of_int value)
      | _ -> Error "captured_at is not a non-negative finite number"
    in
    let* wire_json = field "wire" fields in
    let* wire =
      match Llm_provider.Request_wire_observer.observation_of_yojson wire_json with
      | Ok value -> Ok value
      | Error detail -> Error detail
    in
    let* parts_json = field "parts" fields in
    let* items = decode_parts parts_json in
    Ok
      { trace_id
      ; absolute_turn
      ; turn_ref
      ; runtime_profile
      ; captured_at
      ; wire
      ; items
      }
  | `Assoc _ -> Error "provider-input response fields are not exact"
  | _ -> Error "provider-input response is not an object"

(* The answer must be the part the list named, and its bytes must be the
   ones the list counted and hashed; anything else is another part. A message
   or a tool schema is stored as compact JSON and read here indented. *)
let decode_part (key : part_key) = function
  | `Assoc fields
    when exact_fields
           [ "dashboard_surface"; "schema"; "keeper"; "turn_ref"; "part"; "text" ]
           fields ->
    let* schema_json = field "schema" fields in
    let* () =
      match schema_json with
      | `String schema when String.equal schema part_schema -> Ok ()
      | _ -> Error "unknown provider-input part schema"
    in
    let* () = check_keeper ~expected_keeper:key.part_keeper fields in
    let* turn_ref = decode_turn_ref_field fields in
    let* () =
      if Ids.Turn_ref.equal turn_ref key.part_turn_ref
      then Ok ()
      else Error "provider-input part belongs to another turn"
    in
    let* part_json = field "part" fields in
    let* part = decode_part_entry part_json in
    let* () =
      if part = key.part_item
      then Ok ()
      else Error "provider-input part is not the part the list named"
    in
    let* text =
      match List.assoc_opt "text" fields with
      | Some (`String text) -> Ok text
      | Some _ | None -> Error "provider-input part text is not a string"
    in
    if String.length text <> part.bytes
    then Error "provider-input part length does not match its byte count"
    else if
      not
        (String.equal
           Agent_core_sha256.(digest_string text |> to_hex)
           part.sha256)
    then Error "provider-input part does not hash to its SHA-256"
    else (
      match part.kind with
      | System_prompt -> Ok text
      | Message _ | Tool_schema _ ->
        (match Yojson.Safe.from_string text with
         | json -> Ok (Yojson.Safe.pretty_to_string json)
         | exception Yojson.Json_error detail ->
           Error ("provider-input part is not JSON: " ^ detail)))
  | `Assoc _ -> Error "provider-input part fields are not exact"
  | _ -> Error "provider-input part response is not an object"

let same_part_key left right =
  String.equal left.part_keeper right.part_keeper
  && Ids.Turn_ref.equal left.part_turn_ref right.part_turn_ref
  && left.part_item = right.part_item

let prompt_block_label = function
  | Prompt_block_id.Keeper_instructions -> "Keeper instructions"
  | Prompt_block_id.Dynamic_context -> "Dynamic context"
  | Prompt_block_id.Active_goals -> "Active Goals"
  | Prompt_block_id.Completion_authority -> "Task completion decisions"
  | Prompt_block_id.Admitted_scheduled_input -> "Scheduled input at turn entry"
  | Prompt_block_id.Temporal_summary -> "Temporal summary"
  | Prompt_block_id.Memory_os_recall -> "Recall block"
  | Prompt_block_id.Librarian_working_context -> "Librarian working context"
  | Prompt_block_id.Recalled_memory -> "Recalled memory"
  | Prompt_block_id.Recalled_memory_status -> "Recall status line"
  | Prompt_block_id.Operator_note -> "Operator note"
  | Prompt_block_id.Skill_compositions -> "Skill compositions"

let input_component_label = function
  | Turn_record.Prompt_block block -> prompt_block_label block
  | Turn_record.Tool_schemas -> "Tool schemas"
  | Turn_record.Message_user -> "User messages"
  | Turn_record.Message_system -> "System messages"
  | Turn_record.Message_assistant_text -> "Assistant text"
  | Turn_record.Message_thinking -> "Thinking"
  | Turn_record.Message_redacted_thinking -> "Redacted thinking"
  | Turn_record.Message_tool_use -> "Tool calls"
  | Turn_record.Message_tool_result -> "Tool results"
  | Turn_record.Message_image -> "Images"
  | Turn_record.Message_document -> "Documents"
  | Turn_record.Message_audio -> "Audio"

(* The kind an item is grouped under. Not [exact_input_label]: that names a
   tool schema after its tool, which would put every schema in a group of one
   and hide that the schemas together are the second-largest thing in the
   request. *)
let exact_input_category = function
  | System_prompt -> "System prompt"
  | Message { role } -> "Message · " ^ role
  | Tool_schema _ -> "Tool schemas"

let exact_input_label = function
  | System_prompt -> "System prompt"
  | Message { role } -> "Message · " ^ role
  | Tool_schema { name } -> "Tool schema · " ^ name

let exact_input_items input = input.items

let format_bytes bytes =
  if bytes >= 1024 * 1024 then Printf.sprintf "%.1f MB" (float bytes /. 1048576.)
  else if bytes >= 1024 then Printf.sprintf "%.1f KB" (float bytes /. 1024.)
  else Printf.sprintf "%d B" bytes

let input_source = function
  | Turn_record.Prompt_block _ -> Turn_prompt_assembly
  | Turn_record.Tool_schemas -> Effective_tool_surface
  | Turn_record.Message_thinking ->
      Provider_message_list
  | Turn_record.Message_redacted_thinking ->
      Provider_message_list
  | Turn_record.Message_user
  | Turn_record.Message_system
  | Turn_record.Message_assistant_text
  | Turn_record.Message_tool_use
  | Turn_record.Message_tool_result ->
      Provider_message_list
  | Turn_record.Message_image
  | Turn_record.Message_document
  | Turn_record.Message_audio ->
      Provider_message_list

(* The tabs name the same three producers: the prompt the turn assembles, the
   tool surface it was given, and the conversation handed to the provider. A
   kind belongs to exactly one, so the screen can colour by producer instead of
   by row order. *)
let exact_input_source = function
  | System_prompt -> Turn_prompt_assembly
  | Message _ -> Provider_message_list
  | Tool_schema _ -> Effective_tool_surface

(* Flow order: what the turn assembles, then what it was given, then what it
   carries forward. The composition reads top to bottom in this order. *)
let input_sources =
  [ Turn_prompt_assembly; Effective_tool_surface; Provider_message_list ]

let input_source_label = function
  | Turn_prompt_assembly -> "turn prompt assembly"
  | Effective_tool_surface -> "effective tool surface"
  | Provider_message_list -> "provider message list"

let input_evidence_label = function
  | Verified_exact_text -> "VERIFIED"
  | Serialized_turn_snapshot -> "SERIALIZED"
  | Producer_digest_only -> "DIGEST ONLY"
  | Byte_count_only -> "BYTES ONLY"

let input_evidence_badge_cells evidence =
  String.length (input_evidence_label evidence) + 4

let verified_system_prompt
    (record : Turn_record.t)
    (provider_input : provider_input option)
    component_bytes =
  match provider_input with
  | Some input when Ids.Turn_ref.equal input.turn_ref record.turn_ref ->
    (match List.find_opt (fun item -> item.kind = System_prompt) input.items with
     | Some item ->
       (match
          List.find_opt
            (fun (block : Turn_record.prompt_block) ->
               block.block = Prompt_block_id.Keeper_instructions)
            record.blocks
        with
        | Some block
          when block.bytes = component_bytes
               && item.bytes = component_bytes
               && String.equal block.digest item.sha256 ->
          Some item
        | Some _ | None -> None)
     | None -> None)
  | Some _ | None -> None

let input_map_rows (record : Turn_record.t) (provider_input : provider_input option) =
  match record.input_components with
  | None -> []
  | Some components ->
      List.map
        (fun (item : Turn_record.input_component) ->
           let source = input_source item.component in
           let verified_item =
             match item.component with
             | Turn_record.Prompt_block Prompt_block_id.Keeper_instructions ->
               verified_system_prompt record provider_input item.bytes
             | Turn_record.Prompt_block
                 ( Prompt_block_id.Dynamic_context
                 | Prompt_block_id.Active_goals
                 | Prompt_block_id.Completion_authority
                 | Prompt_block_id.Admitted_scheduled_input
                 | Prompt_block_id.Temporal_summary
                 | Prompt_block_id.Memory_os_recall
                 | Prompt_block_id.Librarian_working_context
                 | Prompt_block_id.Recalled_memory
                 | Prompt_block_id.Recalled_memory_status
                 | Prompt_block_id.Operator_note
                 | Prompt_block_id.Skill_compositions )
             | Turn_record.Tool_schemas
             | Turn_record.Message_user
             | Turn_record.Message_system
             | Turn_record.Message_assistant_text
             | Turn_record.Message_thinking
             | Turn_record.Message_redacted_thinking
             | Turn_record.Message_tool_use
             | Turn_record.Message_tool_result
             | Turn_record.Message_image
             | Turn_record.Message_document
             | Turn_record.Message_audio -> None
           in
           let digest =
             match item.component with
             | Turn_record.Prompt_block block_id ->
                 record.blocks
                 |> List.find_opt
                      (fun (block : Turn_record.prompt_block) ->
                         block.block = block_id && block.bytes = item.bytes)
                 |> Option.map (fun (block : Turn_record.prompt_block) ->
                        block.digest)
             | Turn_record.Tool_schemas
             | Turn_record.Message_user
             | Turn_record.Message_system
             | Turn_record.Message_assistant_text
             | Turn_record.Message_thinking
             | Turn_record.Message_redacted_thinking
             | Turn_record.Message_tool_use
             | Turn_record.Message_tool_result
             | Turn_record.Message_image
             | Turn_record.Message_document
             | Turn_record.Message_audio -> None
           in
           let evidence =
             match verified_item, provider_input, digest with
             | Some _, _, _ -> Verified_exact_text
             | None, Some input, _
               when Ids.Turn_ref.equal input.turn_ref record.turn_ref ->
                 Serialized_turn_snapshot
             | None, (Some _ | None), Some _ -> Producer_digest_only
             | None, (Some _ | None), None -> Byte_count_only
           in
           { component = item.component
           ; bytes = item.bytes
           ; source
           ; evidence
           ; digest
           ; verified_item
           })
        components

(* Keep the inspector's token readings on the shared column precision. *)
let format_tokens = Masc_tui_message_layout.compact_count

let forecast_schema = "masc.keeper.next-request-forecast.v6"

let nonnegative_float name = function
  | `Float value when Float.is_finite value && value >= 0. -> Ok value
  | `Int value when value >= 0 -> Ok (Float.of_int value)
  | _ -> Error (name ^ " is not a non-negative finite number")

let decode_exact_turn_transcript ~expected_keeper ~expected_turn_ref json
    : (response_turn, string) result =
  let fail detail = Error ("exact turn transcript: " ^ detail) in
  let decode_line side = function
    | `Assoc fields when exact_fields [ "role"; "content"; "ts" ] fields ->
        let get name = match List.assoc_opt name fields with
          | Some value -> Ok value | None -> fail ("missing line " ^ name) in
        let* content = match List.assoc_opt "content" fields with
          | Some (`String content) -> Ok content | _ -> fail "line content is not text" in
        let* ts = get "ts" in
        let* () = match ts with
          | `Float ts when Float.is_finite ts -> Ok ()
          | `Int _ -> Ok () | _ -> fail "line timestamp is not finite" in
        let* role = get "role" in
        (match side, role with
         | `User, `String "user" -> Ok None
         | `Assistant, `String "assistant" -> Ok (Some (Reply_text content))
         | `Assistant, `String "request_failure" -> Ok (Some (Request_failure content))
         | (`User | `Assistant), _ -> fail "line role does not match its transcript side")
    | _ -> fail "line fields are not exact" in
  let decode_lines side = function
    | `List rows ->
        let rec loop parts = function
          | [] -> Ok (List.rev parts)
          | row :: rest ->
              let* part = decode_line side row in
              loop (Option.fold ~none:parts ~some:(fun part -> part :: parts) part) rest in
        let* parts = loop [] rows in
        Ok (rows <> [], parts)
    | _ -> fail "transcript side is not an array" in
  match json with
  | `Assoc fields when exact_fields
      [ "schema"; "keeper"; "turn_ref"; "source"; "found"; "user"; "assistant" ] fields ->
      let get name = match List.assoc_opt name fields with
        | Some value -> Ok value | None -> fail ("missing " ^ name) in
      let* schema = get "schema" in
      let* () = match schema with
        | `String "masc.keeper.turn-transcript.v2" -> Ok ()
        | _ -> fail "unsupported transcript schema" in
      let* keeper = get "keeper" in
      let* () = match keeper with
        | `String keeper when String.equal keeper expected_keeper -> Ok ()
        | _ -> fail "Keeper does not match request" in
      let* ref_json = get "turn_ref" in
      let* turn_ref = Ids.Turn_ref.of_yojson ref_json in
      let* () = if Ids.Turn_ref.equal turn_ref expected_turn_ref then Ok ()
        else fail "Turn_ref does not match request" in
      let* source = get "source" in
      let* () = match source with
        | `String "keeper_chat_store" -> Ok () | _ -> fail "unknown source" in
      let* users_json = get "user" in
      let* has_user, _ = decode_lines `User users_json in
      let* assistant_json = get "assistant" in
      let* has_assistant, parts = decode_lines `Assistant assistant_json in
      let* found = get "found" in
      (match found with
       | `Bool found when Bool.equal found (has_user || has_assistant) ->
           Ok { parts; source = Exact_turn_transcript }
       | _ -> fail "found disagrees with the retained transcript rows")
  | _ -> fail "response fields are not exact"

let decode_forecast_rest = function
  | `Assoc fields ->
    let* kind_json = field "kind" fields in
    let* kind = nonempty_string "rest.kind" kind_json in
    (match kind with
     | "serving" -> Ok Rest_serving
     | "resting" ->
       let* release_json = field "release_at" fields in
       let* release_at = nonnegative_float "rest.release_at" release_json in
       let* promotes_json = field "walk_promotes_at_release" fields in
       (match promotes_json with
        | `Bool walk_promotes_at_release ->
          Ok (Rest_resting { release_at; walk_promotes_at_release })
        | _ -> Error "rest.walk_promotes_at_release is not a boolean")
     | other -> Error ("rest.kind is neither serving nor resting: " ^ other))
  | _ -> Error "rest is not an object"

let decode_forecast_place = function
  | `Assoc fields ->
    let* walks_json = field "walks_at" fields in
    let* walks_at = nonnegative_int "place.walks_at" walks_json in
    let* declared_json = field "declared_at" fields in
    let* declared_at =
      match declared_json with
      | `Null -> Ok None
      | json ->
        let* index = nonnegative_int "place.declared_at" json in
        Ok (Some index)
    in
    let* rest_json = field "rest" fields in
    let* rest = decode_forecast_rest rest_json in
    Ok { walks_at; declared_at; rest }
  | _ -> Error "place is not an object"

let decode_forecast_walk = function
  | `Assoc fields when List.mem_assoc "refusal" fields ->
    let* refusal_json = field "refusal" fields in
    let* refusal = nonempty_string "walk.refusal" refusal_json in
    Ok (Error refusal)
  | `Assoc fields ->
    let* lane_json = field "lane_id" fields in
    let* lane_id = nonempty_string "walk.lane_id" lane_json in
    let* declared_json = field "declared" fields in
    let* declared =
      match declared_json with
      | `List items ->
        let rec loop reversed = function
          | [] -> Ok (List.rev reversed)
          | item :: rest ->
            let* id = nonempty_string "walk.declared" item in
            loop (id :: reversed) rest
        in
        loop [] items
      | _ -> Error "walk.declared is not a list"
    in
    Ok (Ok { lane_id; declared })
  | _ -> Error "walk is not an object"

let decode_forecast_lane = function
  | `Assoc fields when List.mem_assoc "not_applicable" fields ->
    let* reason_json = field "not_applicable" fields in
    let* reason = nonempty_string "lane.not_applicable" reason_json in
    Ok (Lane_not_applicable reason)
  | `Assoc fields ->
    (match List.assoc_opt "agent_core" fields with
     | Some (`Bool true) -> Ok Lane_agent_core
     | Some _ | None -> Error "lane is neither agent_core nor not_applicable")
  | _ -> Error "lane is not an object"

let decode_forecast_parts = function
  | `Assoc fields when List.mem_assoc "error" fields ->
    let* error_json = field "error" fields in
    let* error = nonempty_string "parts.error" error_json in
    Ok (Error error)
  | `Assoc fields ->
    let* reserved_turn_json = field "reserved_measured_on_turn" fields in
    let* reserved_measured_on_turn =
      nonnegative_int "parts.reserved_measured_on_turn" reserved_turn_json
    in
    let* reserved_json = field "reserved_bytes" fields in
    let* reserved_bytes = nonnegative_int "parts.reserved_bytes" reserved_json in
    let* pinned_turn_json = field "pinned_measured_on_turn" fields in
    let* pinned_measured_on_turn =
      nonnegative_int "parts.pinned_measured_on_turn" pinned_turn_json
    in
    let* pinned_runtime_json = field "pinned_measured_on_runtime" fields in
    let* pinned_measured_on_runtime =
      nonempty_string "parts.pinned_measured_on_runtime" pinned_runtime_json
    in
    let* pinned_json = field "pinned_bytes" fields in
    let* pinned_bytes = nonnegative_int "parts.pinned_bytes" pinned_json in
    Ok
      (Ok
         { reserved_measured_on_turn
         ; reserved_bytes
         ; pinned_measured_on_turn
         ; pinned_measured_on_runtime
         ; pinned_bytes
         })
  | _ -> Error "parts is not an object"

let rec decode_forecast_origin = function
  | `Assoc fields ->
    let* kind_json = field "kind" fields in
    let* kind = nonempty_string "origin.kind" kind_json in
    if String.equal kind "ledger" then Ok Carried_from_ledger
    else if String.equal kind "turn_record" then
      let* turn_json = field "turn" fields in
      let* turn = nonnegative_int "origin.turn" turn_json in
      Ok (Carried_from_turn_record { turn })
    else if String.equal kind "turn_start_after_seed_refusal" then
      Ok Carried_turn_start_after_seed_refusal
    else if String.equal kind "turn_start_after_librarian_refusal" then
      Ok Carried_turn_start_after_librarian_refusal
    else if String.equal kind "past_librarian_point" then
      let* end_atom_json = field "librarian_end_atom" fields in
      let* librarian_end_atom = nonnegative_int "origin.librarian_end_atom" end_atom_json in
      let* front_json = field "front" fields in
      let* front = decode_forecast_origin front_json in
      (match front with
       | Carried_from_ledger | Carried_from_turn_record _ | Carried_turn_start_after_seed_refusal
       | Carried_turn_start_after_librarian_refusal ->
         Ok (Carried_past_librarian_point { librarian_end_atom; front })
       | Carried_turn_start _ | Carried_turn_start_unknown _ | Carried_librarian_snapshot _
       | Carried_librarian_progress _ | Carried_past_librarian_point _ ->
         Error "origin.front is not a carried front")
    else if String.equal kind "turn_start" then
      let* end_atom_json = field "end_atom" fields in
      let* end_atom = nonnegative_int "origin.end_atom" end_atom_json in
      Ok (Carried_turn_start { end_atom })
    else if String.equal kind "turn_start_unknown" then
      let* reason_json = field "reason" fields in
      let* reason = nonempty_string "origin.reason" reason_json in
      Ok (Carried_turn_start_unknown { reason })
    else if String.equal kind "librarian_snapshot" then
      let* end_atom_json = field "end_atom" fields in
      let* end_atom = nonnegative_int "origin.end_atom" end_atom_json in
      let* boundary_line_json = field "boundary_line" fields in
      let* boundary_line = nonnegative_int "origin.boundary_line" boundary_line_json in
      Ok (Carried_librarian_snapshot { end_atom; boundary_line })
    else if String.equal kind "librarian_progress" then
      let* end_atom_json = field "end_atom" fields in
      let* end_atom = nonnegative_int "origin.end_atom" end_atom_json in
      Ok (Carried_librarian_progress { end_atom })
    else Error ("origin.kind is not a known kind: " ^ kind)
  | _ -> Error "origin is not an object"

let decode_forecast_carried = function
  | `Null -> Ok None
  | `Assoc fields ->
    let* first_json = field "first_atom" fields in
    let* first_atom = nonnegative_int "carried.first_atom" first_json in
    let* kept_json = field "kept_atoms" fields in
    let* kept_atoms = nonnegative_int "carried.kept_atoms" kept_json in
    let* transmitted_json = field "transmitted_bytes" fields in
    let* transmitted_bytes = nonnegative_int "carried.transmitted_bytes" transmitted_json in
    let* origin_json = field "origin" fields in
    let* origin = decode_forecast_origin origin_json in
    let* counted_json = field "counted_tokens" fields in
    let* counted_tokens =
      match counted_json with
      | `Null -> Ok None
      | json ->
        let* counted = nonnegative_int "carried.counted_tokens" json in
        Ok (Some counted)
    in
    Ok (Some { first_atom; kept_atoms; transmitted_bytes; origin; counted_tokens })
  | _ -> Error "carried is not an object or null"

let decode_forecast_block = function
  | `Assoc fields ->
    let* name_json = field "block" fields in
    let* name = nonempty_string "block.block" name_json in
    let* bytes_json = field "bytes" fields in
    let* bytes = nonnegative_int "block.bytes" bytes_json in
    Ok (name, bytes)
  | _ -> Error "block is not an object"

let decode_forecast_slot = function
  | `Assoc fields ->
    let* kind_json = field "slot" fields in
    let* kind = nonempty_string "slot.slot" kind_json in
    let* bytes_json = field "bytes" fields in
    let* bytes = nonnegative_int "slot.bytes" bytes_json in
    if String.equal kind "system_prompt" then Ok (Slot_system_prompt { bytes })
    else if String.equal kind "tools" then Ok (Slot_tools { bytes })
    else if String.equal kind "preamble" then Ok (Slot_preamble { bytes })
    else if String.equal kind "wake_line" then Ok (Slot_wake_line { bytes })
    else if String.equal kind "history" then
      let* atoms_json = field "atoms" fields in
      let* atoms = nonnegative_int "slot.atoms" atoms_json in
      let* of_json = field "of_atoms" fields in
      let* of_atoms = nonnegative_int "slot.of_atoms" of_json in
      Ok (Slot_history { atoms; of_atoms; bytes })
    else if String.equal kind "system_context" then
      let* blocks_json = field "blocks" fields in
      (match blocks_json with
       | `List items ->
         let rec decode reversed = function
           | [] -> Ok (List.rev reversed)
           | item :: rest ->
             let* block = decode_forecast_block item in
             decode (block :: reversed) rest
         in
         let* blocks = decode [] items in
         Ok (Slot_system_context { bytes; blocks })
       | _ -> Error "slot.blocks is not a list")
    else Error ("slot.slot is not a known slot: " ^ kind)
  | _ -> Error "slot is not an object"

let decode_forecast_assembly = function
  | `Null -> Ok None
  | `List items ->
    let rec decode reversed = function
      | [] -> Ok (Some (List.rev reversed))
      | item :: rest ->
        let* slot = decode_forecast_slot item in
        decode (slot :: reversed) rest
    in
    decode [] items
  | _ -> Error "assembly is not a list or null"

let decode_forecast_candidate = function
  | `Assoc fields ->
    let* id_json = field "runtime_id" fields in
    let* runtime_id = nonempty_string "candidate.runtime_id" id_json in
    let* lane_json = field "lane" fields in
    let* lane = decode_forecast_lane lane_json in
    let* parts_json = field "parts" fields in
    let* parts = decode_forecast_parts parts_json in
    let* atoms_json = field "history_atoms" fields in
    let* history_atoms = nonnegative_int "candidate.history_atoms" atoms_json in
    let* carried_json = field "carried" fields in
    let* carried = decode_forecast_carried carried_json in
    let* assembly_json = field "assembly" fields in
    let* assembly = decode_forecast_assembly assembly_json in
    let* place_json = field "place" fields in
    let* place = decode_forecast_place place_json in
    Ok { runtime_id; lane; parts; history_atoms; carried; assembly; place }
  | _ -> Error "candidate is not an object"

let decode_forecast = function
  | `Assoc fields ->
    let* schema_json = field "schema" fields in
    let* schema = nonempty_string "schema" schema_json in
    if not (String.equal schema forecast_schema) then
      Error (Printf.sprintf "next-request schema %s is not %s" schema forecast_schema)
    else
      let* messages_json = field "checkpoint_messages" fields in
      let* checkpoint_messages = nonnegative_int "checkpoint_messages" messages_json in
      let* wake_json = field "wake_line_bytes" fields in
      let* wake_line_bytes = nonnegative_int "wake_line_bytes" wake_json in
      let* walk_json = field "walk" fields in
      let* walk = decode_forecast_walk walk_json in
      let* candidates_json = field "candidates" fields in
      (match candidates_json with
       | `List items ->
         let rec loop reversed = function
           | [] -> Ok (List.rev reversed)
           | item :: rest ->
             let* candidate = decode_forecast_candidate item in
             loop (candidate :: reversed) rest
         in
         let* candidates = loop [] items in
         Ok { checkpoint_messages; wake_line_bytes; walk; candidates }
       | _ -> Error "candidates is not a list")
  | _ -> Error "next-request response is not an object"

let client_context_tokens ~scope ~input_tokens ~output_tokens =
  match (scope : Runtime_usage_scope.t), input_tokens with
  | Per_request, Some input -> Some (input + Option.value output_tokens ~default:0)
  | Per_request, None
  | (Turn_total | Conversation_cumulative | Usage_scope_unavailable), _ -> None
;;

(* The part a pane shows. On the request tab: the opened item, or with none
   opened the item under the cursor, which the wide layout draws beside the
   list. On the proof tab: the opened or selected row's verified part. A part
   is read only for these, so moving through a list costs one part per stop. *)
let shown_part ~keeper ~tab ~target ~opened ~cursor reading =
  match observed_input reading with
  | Some input when
      (match target with
       | Recent _ -> (match reading with Turn_read _ -> true | Exact_read _ | Turn_read_failed _ | Request_failed _ -> false)
       | Pinned reference -> Ids.Turn_ref.equal reference input.turn_ref) ->
    let at_cursor rows =
      List.nth_opt rows (min (max 0 (List.length rows - 1)) (max 0 cursor))
    in
    let at rows =
      match opened with
      | Some index -> List.nth_opt rows index
      | None -> at_cursor rows
    in
    let item =
      match tab with
      | Composition | Response -> None
      | Exact_input -> at input.items
      | Input_map ->
        (match inspected_record ~target reading with
         | None -> None
         | Some record ->
           Option.bind
             (at (input_map_rows record (Some input)))
             (fun row -> row.verified_item))
    in
    Option.map
      (fun part_item ->
         { part_keeper = keeper; part_turn_ref = input.turn_ref; part_item })
      item
  | Some _ | None -> None
