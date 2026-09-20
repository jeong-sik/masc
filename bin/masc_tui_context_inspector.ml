type exact_input_kind =
  | System_prompt
  | Message of { role : string }
  | Tool_schema of { name : string }

type exact_input_item =
  { kind : exact_input_kind
  ; bytes : int
  ; sha256 : string
  ; text : string
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
  ; cache_read : int option
  ; output_tokens : int option
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

type response_turn =
  { parts : response_part list
  ; outside_newest_page : bool
  }

(* ── Next request forecast ───────────────────────────── *)

type forecast_lane =
  | Lane_agent_core
  | Lane_not_applicable of string

type forecast_marks =
  { high_water_tokens : int
  ; low_water_tokens : int
  }

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
  | Carried_halved_after_refusal of { retry : int }
  | Carried_evicted_after_refusal of { retry : int }
  | Carried_whole_history

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
  ; marks : forecast_marks option
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

type reading =
  { turn : (selection, string) result
  ; provider_input : (provider_input, string) result
  ; response : (response_turn, string) result
  ; forecast : (forecast, string) result
  }

type tab =
  | Composition
  | Exact_input
  | Input_map

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
  ; exact_text : string option
  }

let ( let* ) = Result.bind

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
                      ; cache_read = record.usage.cache_read_input_tokens
                      ; output_tokens = record.usage.output_tokens
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

let decode_system_prompt = function
  | `Null -> Ok []
  | `Assoc fields when exact_fields [ "bytes"; "sha256"; "text" ] fields ->
    let* bytes_json = field "bytes" fields in
    let* bytes = nonnegative_int "system_prompt.bytes" bytes_json in
    let* sha_json = field "sha256" fields in
    let* sha256 = sha256 "system_prompt.sha256" sha_json in
    let* text_json = field "text" fields in
    let* text = nonempty_string "system_prompt.text" text_json in
    if String.length text <> bytes
    then Error "system_prompt text length does not match bytes"
    else Ok [ { kind = System_prompt; bytes; sha256; text } ]
  | `Assoc _ -> Error "system_prompt fields are not exact"
  | _ -> Error "system_prompt is not an object or null"

let decode_indexed_items ~kind_of_label ~label_key = function
  | `List values ->
    let rec loop index reversed = function
      | [] -> Ok (List.rev reversed)
      | `Assoc fields :: rest
        when exact_fields
               [ "index"; label_key; "bytes"; "sha256"; "content" ]
               fields ->
        let* actual_index_json = field "index" fields in
        let* actual_index =
          nonnegative_int (label_key ^ ".index") actual_index_json
        in
        if actual_index <> index
        then
          Error
            (Printf.sprintf
               "%s index %d is not contiguous"
               label_key
               actual_index)
        else
          let* label_json = field label_key fields in
          let* label = nonempty_string label_key label_json in
          let* bytes_json = field "bytes" fields in
          let* bytes = nonnegative_int (label_key ^ ".bytes") bytes_json in
          let* sha_json = field "sha256" fields in
          let* sha256 = sha256 (label_key ^ ".sha256") sha_json in
          let* content = field "content" fields in
          let text = Yojson.Safe.pretty_to_string content in
          loop
            (index + 1)
            ({ kind = kind_of_label label; bytes; sha256; text } :: reversed)
            rest
      | `Assoc _ :: _ -> Error (label_key ^ " fields are not exact")
      | _ -> Error (label_key ^ " item is not an object")
    in
    loop 0 [] values
  | _ -> Error (label_key ^ " list is not an array")

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
           ; "system_prompt"
           ; "messages"
           ; "tool_schemas"
           ]
           fields ->
    let* schema_json = field "schema" fields in
    let* schema = nonempty_string "schema" schema_json in
    let* () =
      if String.equal schema "masc.resolved-provider-input.v1"
      then Ok ()
      else Error ("unknown provider-input schema " ^ schema)
    in
    let* keeper_json = field "keeper" fields in
    let* keeper = nonempty_string "keeper" keeper_json in
    let* () =
      if String.equal keeper expected_keeper
      then Ok ()
      else
        Error
          (Printf.sprintf
             "provider-input belongs to %S, expected %S"
             keeper
             expected_keeper)
    in
    let* trace_json = field "trace_id" fields in
    let* trace_id = nonempty_string "trace_id" trace_json in
    let* turn_json = field "absolute_turn" fields in
    let* absolute_turn = nonnegative_int "absolute_turn" turn_json in
    let turn_ref = Ids.Turn_ref.make ~trace_id ~absolute_turn in
    let* turn_ref_json = field "turn_ref" fields in
    let* observed_turn_ref =
      match Ids.Turn_ref.of_yojson turn_ref_json with
      | Ok value -> Ok value
      | Error detail -> Error detail
    in
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
    let* system_json = field "system_prompt" fields in
    let* system_items = decode_system_prompt system_json in
    let* messages_json = field "messages" fields in
    let* message_items =
      decode_indexed_items
        ~kind_of_label:(fun role -> Message { role })
        ~label_key:"role"
        messages_json
    in
    let* tools_json = field "tool_schemas" fields in
    let* tool_items =
      decode_indexed_items
        ~kind_of_label:(fun name -> Tool_schema { name })
        ~label_key:"name"
        tools_json
    in
    Ok
      { trace_id
      ; absolute_turn
      ; turn_ref
      ; runtime_profile
      ; captured_at
      ; wire
      ; items = system_items @ message_items @ tool_items
      }
  | `Assoc _ -> Error "provider-input response fields are not exact"
  | _ -> Error "provider-input response is not an object"

let prompt_block_label = function
  | Prompt_block_id.Keeper_instructions -> "Keeper instructions"
  | Prompt_block_id.Dynamic_context -> "Dynamic context"
  | Prompt_block_id.Temporal_summary -> "Temporal summary"
  | Prompt_block_id.Memory_os_recall -> "Memory recall"
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

let verified_system_prompt (record : Turn_record.t) provider_input component_bytes =
  match provider_input with
  | Some input when Ids.Turn_ref.equal input.turn_ref record.turn_ref ->
    (match List.find_opt (fun item -> item.kind = System_prompt) input.items with
     | Some item ->
       let digest = Digestif.SHA256.(digest_string item.text |> to_hex) in
       (match
          List.find_opt
            (fun (block : Turn_record.prompt_block) ->
               block.block = Prompt_block_id.Keeper_instructions)
            record.blocks
        with
        | Some block
          when block.bytes = component_bytes
               && item.bytes = component_bytes
               && String.equal block.digest digest ->
          Some item.text
        | Some _ | None -> None)
     | None -> None)
  | Some _ | None -> None

let input_map_rows (record : Turn_record.t) provider_input =
  match record.input_components with
  | None -> []
  | Some components ->
      List.map
        (fun (item : Turn_record.input_component) ->
           let source = input_source item.component in
           let exact_text =
             match item.component with
             | Turn_record.Prompt_block Prompt_block_id.Keeper_instructions ->
               verified_system_prompt record provider_input item.bytes
             | Turn_record.Prompt_block _
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
             match exact_text, provider_input, digest with
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
           ; exact_text
           })
        components

(* At most six characters, which is the cell every "≈%6s tok" column
   reserves. A figure changes rung as soon as the previous format would
   round it to a seventh character: 999,950 reads "1.00M" rather than
   "1000.0k", 99,995,000 reads "100.0M" rather than "100.00M", and
   999,950,000 reads "1.00B" rather than "1000.0M". *)
let format_tokens tokens =
  if tokens >= 999_950_000 then Printf.sprintf "%.2fB" (float tokens /. 1_000_000_000.)
  else if tokens >= 99_995_000 then Printf.sprintf "%.1fM" (float tokens /. 1_000_000.)
  else if tokens >= 999_950 then Printf.sprintf "%.2fM" (float tokens /. 1_000_000.)
  else if tokens >= 1_000 then Printf.sprintf "%.1fk" (float tokens /. 1_000.)
  else string_of_int tokens

let forecast_schema = "masc.keeper.next-request-forecast.v5"

let nonnegative_float name = function
  | `Float value when Float.is_finite value && value >= 0. -> Ok value
  | `Int value when value >= 0 -> Ok (Float.of_int value)
  | _ -> Error (name ^ " is not a non-negative finite number")

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

let decode_forecast_marks = function
  | `Null -> Ok None
  | `Assoc fields ->
    let* high_json = field "high_water_tokens" fields in
    let* high_water_tokens = nonnegative_int "marks.high_water_tokens" high_json in
    let* low_json = field "low_water_tokens" fields in
    let* low_water_tokens = nonnegative_int "marks.low_water_tokens" low_json in
    Ok (Some { high_water_tokens; low_water_tokens })
  | _ -> Error "marks is not an object or null"

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

let decode_forecast_origin = function
  | `Assoc fields ->
    let* kind_json = field "kind" fields in
    let* kind = nonempty_string "origin.kind" kind_json in
    if String.equal kind "ledger" then Ok Carried_from_ledger
    else if String.equal kind "turn_record" then
      let* turn_json = field "turn" fields in
      let* turn = nonnegative_int "origin.turn" turn_json in
      Ok (Carried_from_turn_record { turn })
    else if String.equal kind "halved_after_refusal" then
      let* retry_json = field "retry" fields in
      let* retry = nonnegative_int "origin.retry" retry_json in
      Ok (Carried_halved_after_refusal { retry })
    else if String.equal kind "evicted_after_refusal" then
      let* retry_json = field "retry" fields in
      let* retry = nonnegative_int "origin.retry" retry_json in
      Ok (Carried_evicted_after_refusal { retry })
    else if String.equal kind "whole_history" then Ok Carried_whole_history
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
    let* marks_json = field "marks" fields in
    let* marks = decode_forecast_marks marks_json in
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
    Ok { runtime_id; lane; marks; parts; history_atoms; carried; assembly; place }
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
